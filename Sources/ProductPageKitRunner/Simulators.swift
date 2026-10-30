import Foundation
import ProductPageKitCore

/// `simctl`, through its JSON.
struct Simulators: Sendable {
    struct Runtime: Decodable, Sendable {
        let identifier: String
        let name: String
        let version: String
        let platform: String
        let isAvailable: Bool
        let supportedDeviceTypes: [DeviceType]
    }

    struct DeviceType: Decodable, Sendable {
        let identifier: String
        let name: String
        let productFamily: String
        let bundlePath: String
    }

    struct Device: Decodable, Sendable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String?
        let dataPath: String

        var isBooted: Bool { state == "Booted" }

        /// Where the device keeps its system-wide preferences, language and
        /// region among them.
        var globalPreferences: URL {
            URL(filePath: dataPath).appending(path: "Library/Preferences/.GlobalPreferences.plist")
        }

        /// Where SpringBoard keeps its settings, an iPad's multitasking mode
        /// among them.
        var springBoardPreferences: URL {
            URL(filePath: dataPath).appending(path: "Library/Preferences/com.apple.springboard.plist")
        }
    }

    /// Devices the runner made are named with this, so they are never
    /// mistaken for someone's own.
    static let prefix = "ProductPageKit"

    func runtimes() async throws -> [Runtime] {
        struct List: Decodable { let runtimes: [Runtime] }
        return try JSONDecoder().decode(List.self, from: try await simctl(["list", "runtimes", "-j"])).runtimes
    }

    /// Every device, with the identifier of the runtime it runs.
    func devices() async throws -> [(runtime: String, device: Device)] {
        struct List: Decodable { let devices: [String: [Device]] }
        let list = try JSONDecoder().decode(List.self, from: try await simctl(["list", "devices", "-j"]))
        return list.devices.flatMap { runtime, devices in devices.map { (runtime, $0) } }
    }

    /// Whether the device's type draws a sensor bar, the Dynamic Island.
    func drawsSensorBar(_ udid: String) async throws -> Bool {
        guard let bundle = try await typeBundle(udid),
              let profile = NSDictionary(contentsOf: bundle.appending(path: "Contents/Resources/profile.plist"))
        else { return false }
        return profile["sensorBarImage"] != nil
    }

    /// A foldable's inner display, the larger of its two. Nil for a device
    /// that does not fold.
    func innerDisplay(_ udid: String) async throws -> InnerDisplay? {
        guard let bundle = try await typeBundle(udid) else { return nil }
        return Self.innerDisplay(Self.capabilities(at: bundle))
    }

    static func innerDisplay(_ capabilities: [String: Any]?) -> InnerDisplay? {
        let displays = (capabilities?["displays"] as? [[String: Any]] ?? []).filter { $0["displayType"] as? String == "integrated" }
        guard displays.count > 1, let inner = displays.max(by: { area($0) < area($1) }),
              let screenID = number(inner["screenID"]), let width = number(inner["width"]), let height = number(inner["height"])
        else { return nil }
        // Opened flat, the display turns to its native rotation.
        let turned = (number(inner["nativeRotation"]) ?? 0) % 180 == 90
        return InnerDisplay(screenID: screenID, openSize: turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height))
    }

    private static func area(_ display: [String: Any]) -> Int {
        (number(display["width"]) ?? 0) * (number(display["height"]) ?? 0)
    }

    /// The bundle of the device's type, which describes its screens.
    private func typeBundle(_ udid: String) async throws -> URL? {
        struct List: Decodable {
            struct DeviceType: Decodable { let identifier: String; let bundlePath: String }
            let devicetypes: [DeviceType]
        }
        let identifier = try await device(udid).deviceTypeIdentifier
        let types = try JSONDecoder().decode(List.self, from: try await simctl(["list", "devicetypes", "-j"])).devicetypes
        return types.first { $0.identifier == identifier }.map { URL(filePath: $0.bundlePath) }
    }

    func device(_ udid: String) async throws -> Device {
        guard let device = try await devices().map(\.device).first(where: { $0.udid == udid }) else {
            throw RunnerError.noDevice(udid)
        }
        return device
    }

    /// The device type and runtime a platform is captured on.
    func resolve(_ device: SimulatorDevice, for kind: Platform.Kind) async throws -> (type: DeviceType, runtime: Runtime) {
        try Self.pick(device, for: kind, in: try await runtimes())
    }

    /// The newest available runtime for the platform's OS that has the
    /// device, and in it the named device or the one with the most pixels. A
    /// point release can ship for one new device alone, as iOS 27.1 did for
    /// iPhone Duo, so the newest runtime may have no other.
    static func pick(_ device: SimulatorDevice, for kind: Platform.Kind, in runtimes: [Runtime]) throws
        -> (type: DeviceType, runtime: Runtime) {
        let os = family(kind).os
        let newestFirst = runtimes
            .filter { $0.platform == os && $0.isAvailable }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        guard let newest = newestFirst.first else { throw RunnerError.noRuntime(os) }
        for runtime in newestFirst {
            let candidates = types(runtime.supportedDeviceTypes, for: kind)
            switch device {
            case .named(let name):
                if let type = candidates.first(where: { $0.name == name }) { return (type, runtime) }
            case .largest:
                let sized = candidates.compactMap { type in pixels(type).map { (type, $0) } }
                if let largest = sized.max(by: { ($0.1, $0.0.name) < ($1.1, $1.0.name) }) { return (largest.0, runtime) }
            }
        }
        switch device {
        case .named(let name):
            throw RunnerError.noDeviceType(name, runtime: newest.name,
                                           available: types(newest.supportedDeviceTypes, for: kind).map(\.name))
        case .largest:
            throw RunnerError.noDeviceType("any \(describe(kind))", runtime: newest.name, available: [])
        }
    }

    /// The runner's own device of this type and runtime, made and booted once
    /// so the clones made from it start past first-boot setup. An iPad's
    /// apps are full screen in it and its clones.
    func base(_ type: DeviceType, runtime: Runtime) async throws -> String {
        let name = "\(Self.prefix) \(type.name) \(runtime.name)"
        let udid: String
        if let existing = try await devices().first(where: { $0.runtime == runtime.identifier && $0.device.name == name }) {
            udid = existing.device.udid
            if existing.device.state != "Shutdown" { try await shutdown(udid) }
        } else {
            udid = String(decoding: try await simctl(["create", name, type.identifier, runtime.identifier]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await boot(udid)
            try await shutdown(udid)
        }
        if type.productFamily == "iPad" { try setFullScreenApps(of: try await device(udid)) }
        return udid
    }

    /// A worker's device, cloned from `base` and named for this process so a
    /// later run can tell an abandoned one from another run's.
    func clone(_ base: String, worker: Int) async throws -> String {
        let name = "\(Self.prefix) worker \(getpid())-\(worker)"
        return String(decoding: try await simctl(["clone", base, name]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Worker clones whose run ended without deleting them.
    func abandonedWorkers() async throws -> [Device] {
        let workerPrefix = "\(Self.prefix) worker "
        return try await devices().map(\.device).filter { device in
            guard device.name.hasPrefix(workerPrefix) else { return false }
            let pid = device.name.dropFirst(workerPrefix.count).split(separator: "-").first.flatMap { Int32($0) }
            return pid.map { kill($0, 0) != 0 } ?? true
        }
    }

    func deleteAbandonedWorkers() async throws {
        for device in try await abandonedWorkers() { try await delete(device.udid) }
    }

    /// Returns once the device has finished booting.
    func boot(_ udid: String) async throws {
        _ = try await simctl(["bootstatus", udid, "-b"])
    }

    func shutdown(_ udid: String) async throws {
        do {
            _ = try await simctl(["shutdown", udid])
        } catch let error as ShellError where error.stderr.contains("current state: Shutdown") {
            return
        }
    }

    func delete(_ udid: String) async throws {
        try await shutdown(udid)
        _ = try await simctl(["delete", udid])
    }

    /// The status bar's `time`, full bars and battery, the appearance and the
    /// text size.
    func prepare(_ udid: String, time: String, appearance: Appearance, contentSize: ContentSize) async throws {
        _ = try await simctl([
            "status_bar", udid, "override", "--time", time,
            "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
            "--cellularMode", "active", "--cellularBars", "4",
            "--batteryState", "charged", "--batteryLevel", "100",
        ])
        _ = try await simctl(["ui", udid, "appearance", appearance.rawValue])
        _ = try await simctl(["ui", udid, "content_size", contentSize.rawValue])
    }

    /// Moves a booted device's status bar time to `locale` in place: the
    /// language and region through the device's own preferences daemon, then
    /// the bridge that formats the override's time restarted to read them,
    /// so `prepare` sets it again. A reboot did the same in about 40 seconds,
    /// most of it the system settling afterwards; this takes three. The date
    /// beside the time on an iPad is SpringBoard's, which restarted in place
    /// stops drawing the bar, so that takes a reboot.
    func switchLocale(_ locale: LocalePreferences, on udid: String) async throws {
        _ = try await simctl(["spawn", udid, "defaults", "write", "-g", LocalePreferences.languagesKey, "-array"] + locale.languages)
        _ = try await simctl(["spawn", udid, "defaults", "write", "-g", LocalePreferences.localeKey, locale.locale])
        _ = try await simctl(["spawn", udid, "launchctl", "kickstart", "-k", "user/\(getuid())/com.apple.CoreSimulator.bridge"])
    }

    /// The language and region the device booted in, or boots in next.
    func locale(of device: Device) throws -> LocalePreferences? {
        LocalePreferences(try Self.preferences(device.globalPreferences))
    }

    /// Sets the language and region the device boots in. Only while it is
    /// shut down: on a booted device `cfprefsd` owns the file, and the
    /// system reads both only at boot.
    func setLocale(_ locale: LocalePreferences, of device: Device) throws {
        let file = device.globalPreferences
        try Self.write(locale.applied(to: try Self.preferences(file)), to: file)
    }

    /// SpringBoard's setting for iPadOS's Windowed Apps, the default since
    /// iPadOS 26, which draws the app's name beside the status bar clock and
    /// a resize handle in the window's corner. Off, apps are full screen.
    static let windowedAppsKey = "SBMedusaMultitaskingEnabled"

    /// Puts an iPad's apps full screen. Only while it is shut down, as with
    /// `setLocale`: SpringBoard reads the mode at boot.
    func setFullScreenApps(of device: Device) throws {
        let file = device.springBoardPreferences
        try Self.write(try Self.preferences(file).merging([Self.windowedAppsKey: false]) { _, new in new }, to: file)
    }

    private static func write(_ preferences: [String: Any], to file: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
            .write(to: file, options: .atomic)
    }

    /// A preferences file's contents. Every device the runner uses has
    /// booted, and so has the file.
    private static func preferences(_ file: URL) throws -> [String: Any] {
        guard let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
            as? [String: Any]
        else { throw RunnerError.unreadablePreferences(file.path) }
        return preferences
    }

    func install(_ app: URL, on udid: String) async throws {
        _ = try await simctl(["install", udid, app.path])
    }

    /// Launches the app, ending a copy that is still running, and returns its
    /// pid on the host.
    func launch(_ bundleID: String, on udid: String, arguments: [String]) async throws -> Int32 {
        let command = ["launch", "--terminate-running-process", udid, bundleID] + arguments
        let output = String(decoding: try await launching(command), as: UTF8.self)
        // "com.example.app: 12345"
        guard let pid = output.split(separator: ":").last.flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            throw RunnerError.unexpectedOutput("simctl launch", output)
        }
        return pid
    }

    /// Runs `command`, asking again a moment later while the simulator drops
    /// the launch.
    private func launching(_ command: [String]) async throws -> Data {
        for _ in 1..<Self.launchAttempts {
            do {
                return try await simctl(command)
            } catch where Self.isDroppedLaunch(error) {
                try await Task.sleep(for: .seconds(2))
            }
        }
        return try await simctl(command)
    }

    /// Straight after an App Review test the simulator drops a launch more
    /// than once in a row.
    static let launchAttempts = 4

    /// A launch the simulator dropped: it answered with no process and no
    /// reason, or said only that the process failed to start, as it does
    /// straight after a boot. Asked again, it starts. A launch refused for a
    /// reason, such as an app not installed, is not one.
    static func isDroppedLaunch(_ error: Error) -> Bool {
        (error as? ShellError).map { isDroppedLaunch($0.stderr) } ?? false
    }

    /// Whether `output`, from `simctl` or from XCTest launching an app,
    /// reports a dropped launch.
    static func isDroppedLaunch(_ output: String) -> Bool {
        ["did not return a process handle nor launch error", "Process failed to launch", "Launchd job spawn failed"]
            .contains { output.contains($0) }
    }

    /// Brings the running app to the front, as it was. Launching an app that
    /// is running starts no other instance.
    func activate(_ bundleID: String, on udid: String) async {
        _ = try? await simctl(["launch", udid, bundleID])
    }

    func terminate(_ bundleID: String, on udid: String) async {
        _ = try? await simctl(["terminate", udid, bundleID])
    }

    /// A device that draws a sensor bar has its screenshots composed with the
    /// display's mask, which blacks the corners. Now and then, and for a
    /// while after the bridge restarts, one comes without the mask and with
    /// the sensor bar drawn black over the status bar; with `masked`, that
    /// one is taken again.
    func screenshot(_ udid: String, display: Int?, masked: Bool) async throws -> Frame {
        for _ in 0..<Self.compositionAttempts {
            let frame = try await screenshot(udid, display: display)
            if !masked || frame.isMasked { return frame }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RunnerError.timedOut("simulator \(udid) to compose a screenshot with its display's mask")
    }

    /// A quarter of a second apart: a busy machine has taken several seconds.
    static let compositionAttempts = 80

    /// `simctl io` writes to a file and nowhere else. Without `display`, the
    /// main display, a foldable's outer one, which is composed with its mask;
    /// another display is only when asked.
    private func screenshot(_ udid: String, display: Int?) async throws -> Frame {
        let file = FileManager.default.temporaryDirectory.appending(path: "ProductPageKit-\(udid).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let other = display.map { ["--display=\($0)", "--mask=black"] } ?? []
        _ = try await simctl(["io", udid, "screenshot", "--type=png"] + other + [file.path])
        return try Frame(png: try Data(contentsOf: file))
    }

    /// Opens a foldable flat, then returns once its inner display draws
    /// opened and has come to rest, so an app launched next starts there. The system
    /// ignores the hinge for some seconds after `boot` returns, so the angle
    /// is sent again each second until it takes.
    func unfold(_ udid: String, _ unfolding: Unfolding) async throws {
        for _ in 0..<Self.unfoldAttempts {
            if unfolding.display.showsOpen(try await screenshot(udid, display: unfolding.display.screenID)) {
                _ = try await FrameStability().settle("simulator \(udid) opening flat") {
                    try await screenshot(udid, display: unfolding.display.screenID)
                }
                return
            }
            _ = try await simctl(["spawn", udid, unfolding.hinge.tool.path, "\(Hinge.open)"])
            try await Task.sleep(for: .seconds(1))
        }
        throw RunnerError.timedOut("simulator \(udid) to unfold")
    }

    /// A second apart: an idle Mac takes about ten.
    static let unfoldAttempts = 90

    private func simctl(_ arguments: [String]) async throws -> Data {
        try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments)
    }

    /// The runtime platform and device family a platform runs in, and
    /// whether its devices fold.
    static func family(_ kind: Platform.Kind) -> (os: String, family: String, folds: Bool) {
        switch kind {
        case .iPhone: ("iOS", "iPhone", false)
        case .iPad: ("iOS", "iPad", false)
        case .iPhoneDuo: ("iOS", "iPhone", true)
        case .appleTV: ("tvOS", "Apple TV", false)
        case .mac: ("macOS", "Mac", false)
        }
    }

    /// The device types a platform is captured on: its family's, and of an
    /// iPhone's only the foldables for iPhone Duo and never them for
    /// iPhone 6.9".
    static func types(_ types: [DeviceType], for kind: Platform.Kind) -> [DeviceType] {
        let (_, family, folds) = family(kind)
        return types.filter { $0.productFamily == family && Self.folds($0) == folds }
    }

    /// `iPhone`, or `foldable iPhone`.
    static func describe(_ kind: Platform.Kind) -> String {
        let (_, family, folds) = family(kind)
        return folds ? "foldable \(family)" : family
    }

    /// Whether the device type has two built-in displays, the outer and the
    /// inner of a foldable.
    static func folds(_ type: DeviceType) -> Bool {
        innerDisplay(capabilities(at: URL(filePath: type.bundlePath))) != nil
    }

    /// The main screen's size in pixels, from the device type's bundle. A
    /// foldable's main screen is its outer display.
    static func pixels(_ type: DeviceType) -> Int? {
        guard let screen = capabilities(at: URL(filePath: type.bundlePath))?["ScreenDimensionsCapability"] as? [String: Any],
              let width = number(screen["main-screen-width"]), let height = number(screen["main-screen-height"])
        else { return nil }
        return width * height
    }

    private static func capabilities(at bundle: URL) -> [String: Any]? {
        let url = bundle.appending(path: "Contents/Resources/capabilities.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["capabilities"] as? [String: Any]
    }

    /// Apple writes these as numbers for phones and strings for Apple TV.
    private static func number(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? String).flatMap(Int.init)
    }
}
