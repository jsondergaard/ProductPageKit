import Foundation
import ProductPageKitControl
import ProductPageKitCore

/// Where an app is launched and photographed: a simulator worker or this Mac.
protocol CaptureDevice: Sendable {
    var name: String { get }
    /// Where `xcodebuild test-without-building` runs a review screenshot test.
    var testDestination: String { get }
    /// The launch settings for this device, with the listener's port, for a
    /// launch drawing `scene` in `variant`.
    func settings(port: UInt16, scene: String?, variant: String?) -> CaptureLaunch
    /// The settings for a review test, which hosts its own view.
    func testSettings(port: UInt16) -> CaptureLaunch
    /// Puts the device's own system in `locale` where it can, so what the
    /// system draws around the app, such as the status bar clock, matches
    /// it. Each launch puts the app in the locale with its arguments.
    func use(_ locale: StoreLocale) async throws
    /// Starts the app and returns its pid.
    func launch(_ arguments: [String]) async throws -> Int32
    /// Takes frames of the scene `ready` reported.
    func frames(for ready: Ready) async throws -> @Sendable () async throws -> Frame
    /// Takes frames of the window a Mac app shows a component in.
    func frames(ofWindow window: WindowInfo, showing component: ComponentRequest) throws -> @Sendable () async throws -> Frame
    /// Ends an app that would not quit, or one a failure left running.
    func end(_ pid: Int32) async
    /// Asks for the app to come forward, when a scene waits for it to be in
    /// front. The ready signal is what checks it came.
    func bringToFront() async
    /// The cause behind a failure, when the device knows a likelier one.
    func diagnose(_ error: any Error) -> any Error
}

/// A cloned simulator, captured headless with `simctl io`.
struct SimulatorWorker: CaptureDevice {
    let simulators: Simulators
    let udid: String
    let os: String
    let bundleID: String
    let appearance: Appearance
    let contentSize: ContentSize
    let statusBar: StatusBar
    /// The locale the simulator stays in whatever it captures, or nil to
    /// follow each.
    let systemLocale: StoreLocale?
    /// What `simctl status_bar override --time` is given.
    let time: String
    /// How a foldable is opened flat after each boot, and photographed on
    /// its inner display. Nil for a device that does not fold.
    let unfolding: Unfolding?

    var name: String { "simulator \(udid)" }
    var testDestination: String { "platform=\(os) Simulator,id=\(udid)" }

    /// Boots in `locale` and installs.
    func prepare(app: URL, locale: StoreLocale) async throws {
        try await use(locale)
        try await simulators.install(app, on: udid)
    }

    /// Nothing when the simulator is in `locale`, or stays in its
    /// `systemLocale`. A booted one whose status
    /// bar shows only the time moves to it in place. Otherwise it is shut
    /// down, given the locale, and booted, since the system reads its
    /// language and region at boot. Either way the status bar override is
    /// gone, so it is set again.
    ///
    /// An Apple TV draws nothing over the app, which takes its language at
    /// launch, so it boots once, in the first locale it is given: the primary
    /// one on the worker whose tests show the system's own screens.
    func use(_ locale: StoreLocale) async throws {
        let preferences = LocalePreferences(systemLocale ?? locale)
        let device = try await simulators.device(udid)
        if statusBar == .none {
            if !device.isBooted {
                try simulators.setLocale(preferences, of: device)
                try await simulators.boot(udid)
            }
            return
        }
        if device.isBooted, try simulators.locale(of: device) == preferences { return }
        if device.isBooted, statusBar == .time {
            try await simulators.switchLocale(preferences, on: udid)
        } else {
            try await simulators.shutdown(udid)
            try simulators.setLocale(preferences, of: device)
            try await simulators.boot(udid)
        }
        try await simulators.prepare(udid, time: time, appearance: appearance, contentSize: contentSize)
        if let unfolding { try await simulators.unfold(udid, unfolding) }
    }

    /// An iPhone's and an iPad's appearance and text size are the
    /// simulator's, set at each boot in `use`. An Apple TV simulator takes
    /// neither, so the app sets its appearance from the launch settings.
    func settings(port: UInt16, scene: String?, variant: String?) -> CaptureLaunch {
        CaptureLaunch(control: CaptureLaunch.Control(port: port), scene: scene, variant: variant,
                      appearance: statusBar == .none ? CaptureAppearance(appearance) : nil)
    }

    func testSettings(port: UInt16) -> CaptureLaunch {
        settings(port: port, scene: nil, variant: nil)
    }

    func launch(_ arguments: [String]) async throws -> Int32 {
        try await simulators.launch(bundleID, on: udid, arguments: arguments)
    }

    func frames(for ready: Ready) async throws -> @Sendable () async throws -> Frame {
        { [simulators, udid, unfolding] in
            try await simulators.screenshot(udid, display: unfolding?.display.screenID)
        }
    }

    /// A simulator app draws its components itself.
    func frames(ofWindow window: WindowInfo, showing component: ComponentRequest) throws -> @Sendable () async throws -> Frame {
        throw RunnerError.componentWindowOffMac(component.description)
    }

    func end(_ pid: Int32) async {
        await simulators.terminate(bundleID, on: udid)
    }

    /// A launch can land behind the home screen, while the system is still
    /// taking down the instance before it.
    func bringToFront() async {
        await simulators.activate(bundleID, on: udid)
    }

    func diagnose(_ error: any Error) -> any Error { error }
}

/// The Mac app, run natively and photographed by window number.
struct MacDevice: CaptureDevice {
    let app: URL
    let appearance: Appearance
    let windowSize: CGSize?

    var name: String { "this Mac" }
    var testDestination: String { ScreenshotRunner.Host.macDestination }

    func settings(port: UInt16, scene: String?, variant: String?) -> CaptureLaunch {
        CaptureLaunch(control: CaptureLaunch.Control(port: port), scene: scene, variant: variant,
                      appearance: CaptureAppearance(appearance), windowSize: windowSize)
    }

    /// Without the app's window size: the test hosts its own view.
    func testSettings(port: UInt16) -> CaptureLaunch {
        CaptureLaunch(control: CaptureLaunch.Control(port: port), appearance: CaptureAppearance(appearance))
    }

    /// The Mac's language and region stay its user's.
    func use(_ locale: StoreLocale) async throws {}

    /// Without restoring windows from the last run, which would put back
    /// whatever someone last left open.
    func launch(_ arguments: [String]) async throws -> Int32 {
        try await MacCapture.launch(app, arguments: arguments + ["-ApplePersistenceIgnoreState", "YES"])
    }

    func frames(for ready: Ready) async throws -> @Sendable () async throws -> Frame {
        guard let number = ready.window?.number else { throw RunnerError.noWindow(ready.request.description) }
        return { try await MacCapture.frame(ofWindow: number) }
    }

    func frames(ofWindow window: WindowInfo, showing component: ComponentRequest) throws -> @Sendable () async throws -> Frame {
        { try await MacCapture.frame(ofWindow: window.number) }
    }

    func end(_ pid: Int32) async {
        kill(pid, SIGTERM)
    }

    /// An app cannot take the front itself, and a launch from a process
    /// with no window is not brought forward while another app is in front.
    /// A review test's host is started by `xcodebuild` in the background.
    func bringToFront() async {
        try? await MacCapture.activate(app)
    }

    /// A screen that locked during the run looks, from here, like an app that
    /// never got ready.
    func diagnose(_ error: any Error) -> any Error {
        MacCapture.isScreenLocked ? RunnerError.screenLocked : error
    }
}

/// What a simulator draws over the app that follows its locale.
enum StatusBar: Sendable {
    /// The time, which the bridge formats and a restart of it moves to
    /// another locale.
    case time
    /// The date beside the time, which SpringBoard draws, and only a boot
    /// moves to another locale.
    case dateAndTime
    /// Nothing: an Apple TV draws no status bar.
    case none
}

extension CaptureAppearance {
    init(_ appearance: Appearance) {
        self = switch appearance {
        case .light: .light
        case .dark: .dark
        }
    }
}
