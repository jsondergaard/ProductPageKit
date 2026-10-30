#if DEBUG
import Foundation
public import Observation
import ProductPageKitControl
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Who started the process the director runs in.
public enum CaptureHost: Sendable {
    /// The app, launched by the runner with its settings as launch arguments.
    case app
    /// A test drawing a scene itself under `xcodebuild test`, which passes the
    /// settings as environment variables. The test returns from `untilQuit()`
    /// instead of the process ending.
    case test

    /// Whether a runner started this process and is listening.
    public var isControlled: Bool { launch?.control != nil }

    /// The scene named at launch, read without the director, for code that
    /// runs before it exists or off the main actor.
    public var scene: String? { launch?.scene }

    /// The variant named at launch, as `scene` is.
    public var variant: String? { launch?.variant }

    var launch: CaptureLaunch? {
        switch self {
        case .app: CaptureLaunch(arguments: ProcessInfo.processInfo.arguments)
        case .test: CaptureLaunch(environment: ProcessInfo.processInfo.environment)
        }
    }
}

/// Moves an app between its capture scenes at the runner's request and tells
/// the runner when each is on screen.
///
/// Make one per process, before the first frame, and attach it to the scene's
/// root view with `.captureDirector(_:apply:)`. Launched with
/// `-ProductPageScene <name>` and no runner, as a UI test might, it only names
/// the launch scene. Launched plainly, it does nothing and `current` stays nil.
@MainActor @Observable
public final class CaptureDirector<Scene: CaptureScene> {
    /// The scene named on the command line, for decisions made at launch.
    public let launchScene: Scene?
    public let launchVariant: String?
    /// The scene on screen: the launch scene, then each one the runner applies.
    public private(set) var current: Scene?
    public private(set) var variant: String?
    /// Bumped for every scene applied in process. The modifier gives the
    /// hierarchy a new identity with it, so a scene starts from fresh view
    /// state as it would after a launch.
    private(set) var generation = 0

    @ObservationIgnored private let host: CaptureHost
    @ObservationIgnored private let launch: CaptureLaunch?
    @ObservationIgnored private var state: DirectorState
    /// Where the views marked with `.captureHighlight()` are.
    @ObservationIgnored let highlights = MarkerRegistry()
    /// Where the views marked with `.captureMoving()` are.
    @ObservationIgnored let moving = MarkerRegistry()
    /// Every `.captureReady` condition on screen, sheets and covers included.
    @ObservationIgnored let conditions = ConditionRegistry()
    /// Draws the components the runner asks for.
    @ObservationIgnored let components: ComponentExporter
    @ObservationIgnored private var apply: (@MainActor (Scene, String?) throws -> Void)?
    /// What a test driving the system said moves, for the scene it showed.
    @ObservationIgnored private var drivenMoving: [CGRect] = []
    @ObservationIgnored private var connection: ControlConnection?
    @ObservationIgnored private var quitWaiters: [CheckedContinuation<Void, Never>] = []
    #if os(macOS)
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowObservers: [any NSObjectProtocol] = []
    #endif

    public init(host: CaptureHost = .app) {
        self.host = host
        let launch = host.launch
        self.launch = launch
        let scene = launch?.scene.flatMap(Scene.init(rawValue:))
        launchScene = scene
        launchVariant = launch?.variant
        current = launchScene
        variant = launchVariant
        components = ComponentExporter(appearance: launch?.appearance)
        // A view a test hosts is outside SwiftUI's scene lifecycle, and its
        // scene phase never turns active.
        let requiresActiveScene = host == .app
        #if os(macOS)
        state = DirectorState(showing: scene == nil ? nil : launch?.sceneRequest, requiresActiveScene: requiresActiveScene,
                              requiresKeyWindow: true)
        if let appearance = launch?.appearance {
            NSApplication.shared.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        #else
        state = DirectorState(showing: scene == nil ? nil : launch?.sceneRequest, requiresActiveScene: requiresActiveScene,
                              requiresKeyWindow: false)
        #endif
        conditions.onChange = { [weak self] in
            guard let self else { return }
            perform(state.update(presentedConditionsMet: conditions.allMet))
        }
    }

    /// Whether a runner is directing the app.
    public var isCapturing: Bool { host.isControlled }

    /// Returns when the runner sends `quit`, for a test that hosts its scene.
    public func untilQuit() async {
        guard !state.hasQuit else { return }
        await withCheckedContinuation { quitWaiters.append($0) }
    }

    /// For a test that drives the app or the system instead of drawing a view,
    /// such as an XCTest UI test pressing the remote: connects to the runner,
    /// runs `show` for each scene the runner asks for, and reports the scene
    /// ready once it returns. Returns when the runner says quit. On a Mac the
    /// frontmost window when `show` returns is what is photographed.
    public func direct(_ show: @escaping @MainActor (Scene, String?) async throws -> CaptureShown) async {
        start { [weak self] scene, variant in
            guard let self else { return }
            let generation = self.generation
            Task { @MainActor in
                do {
                    let shown = try await show(scene, variant)
                    self.drivenMoving = shown.moving
                    #if os(macOS)
                    // Ordered at once, where becoming key waits for the run loop.
                    if let window = NSApplication.shared.orderedWindows.first(where: \.isVisible) { self.attach(window) }
                    #endif
                    self.update(readiness: CaptureReadiness(generation: generation, conditionsMet: true))
                } catch {
                    self.perform(self.state.applyFailed(SceneRequest(scene: scene.rawValue, variant: variant),
                                                        reason: String(describing: error)))
                }
            }
        }
        await untilQuit()
    }

    /// Connects to the runner, once, when the root view first appears.
    func start(apply: @escaping @MainActor (Scene, String?) throws -> Void) {
        self.apply = apply
        guard let control = launch?.control, connection == nil else { return }
        let connection = ControlConnection(host: control.host, port: control.port) { [weak self] message in
            self?.receive(message)
        } onClose: { [weak self] in
            self?.connection = nil
        }
        self.connection = connection
        #if !os(macOS)
        // Each scene is photographed where it comes to rest; an animation
        // only holds the runner's check for two matching frames back.
        UIView.setAnimationsEnabled(false)
        #endif
        components.connect { [weak connection] in connection?.send($0) }
        connection.start()
        connection.send(.hello(Hello(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            platform: .current,
            scenes: Scene.allCases.map { SceneDescription(name: $0.rawValue, relaunch: $0.launchPolicy == .relaunch) },
            variantsRelaunch: Scene.variantPolicy == .relaunch
        )))
    }

    func update(readiness: CaptureReadiness) {
        perform(state.update(readiness: readiness))
    }

    func update(active: Bool) {
        perform(state.update(active: active))
    }

    private func receive(_ message: RunnerMessage) {
        switch message {
        case .export, .taken: components.receive(message)
        default: perform(state.receive(message, knownScenes: Set(Scene.allCases.map(\.rawValue))))
        }
    }

    private func perform(_ effects: [DirectorState.Effect]) {
        for effect in effects {
            switch effect {
            case .apply(let request):
                // `apply` only reaches here for a known scene.
                let scene = Scene(rawValue: request.scene)!
                current = scene
                variant = request.variant
                generation = state.generation
                do {
                    try apply?(scene, request.variant)
                } catch {
                    perform(state.applyFailed(request, reason: String(describing: error)))
                }
            case .ready(let request):
                // Once the scene is on screen, not as soon as its views report:
                // a heavy scene's conditions hold before its first frame is
                // committed, and in between the runner photographed the frame
                // of the scene before it.
                FramePresentation.after { [weak self] in
                    guard let self else { return }
                    connection?.send(.ready(Ready(request, window: windowInfo, moving: movingFractions)))
                }
            case .waiting(let request, let reasons):
                connection?.send(.waiting(Waiting(request, reasons: reasons)))
            case .highlights(let request):
                connection?.send(.highlights(SceneHighlights(request, rects: highlightFractions)))
            case .moving(let request):
                connection?.send(.moving(SceneMoving(request, rects: movingFractions)))
            case .leftFront(let request):
                connection?.send(.leftFront(request))
            case .failed(let request, let reason):
                connection?.send(.failed(Failure(request, reason: reason)))
            case .quit:
                switch host {
                case .app:
                    exit(0)
                case .test:
                    connection?.close()
                    for waiter in quitWaiters { waiter.resume() }
                    quitWaiters = []
                }
            }
        }
    }

    #if os(macOS)
    /// The window the root view is in: held at the launch settings' size,
    /// brought to the front, and watched for losing key status. A sheet
    /// over it is part of it: while one is up, the sheet is the key window.
    func attach(_ window: NSWindow) {
        guard isCapturing, self.window !== window else { return }
        self.window = window
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        // Any window's, since a sheet becoming key is the window's own.
        windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowKeyChanged() }
            }
        }
        // Kept key: another of the app's windows, such as the one SwiftUI
        // opens when the app is reopened to bring it forward, would otherwise
        // take key after the scene was reported ready.
        windowObservers += [NSApplication.didBecomeActiveNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, !self.isKey(window) else { return }
                    (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
                }
            }
        }
        if let size = launch?.windowSize {
            // Not saved: a capture shares the installed app's defaults, and
            // the next ordinary launch would open at the screenshot's size.
            window.setFrameAutosaveName("")
            // Put back after every resize: SwiftUI installs a toolbar after
            // the window exists, and the frame grows around the content.
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hold(size) }
            })
            hold(size)
            window.center()
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        windowKeyChanged()
    }

    private func hold(_ size: CGSize) {
        guard let window, window.contentRect(forFrameRect: window.frame).size != size else { return }
        window.setContentSize(size)
    }

    private func windowKeyChanged() {
        perform(state.update(windowKey: window.map(isKey) == true))
    }

    private func isKey(_ window: NSWindow) -> Bool {
        window.isKeyWindow || window.attachedSheet?.isKeyWindow == true
    }

    private var windowInfo: WindowInfo? {
        window.map { WindowInfo(number: $0.windowNumber, frame: $0.frame) }
    }

    private var highlightFractions: [CGRect] {
        window.map(highlights.fractions) ?? []
    }

    private var movingFractions: [CGRect] {
        (window.map(moving.fractions) ?? []) + drivenMoving
    }
    #else
    /// The window the root view is in, in the launch settings' appearance
    /// where the simulator cannot set one, as an Apple TV's cannot.
    func attach(_ window: UIWindow) {
        guard let appearance = launch?.appearance else { return }
        window.overrideUserInterfaceStyle = appearance == .dark ? .dark : .light
    }

    private var windowInfo: WindowInfo? { nil }

    private var highlightFractions: [CGRect] { highlights.fractions() }

    private var movingFractions: [CGRect] { moving.fractions() + drivenMoving }
    #endif
}
#endif
