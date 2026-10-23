#if !DEBUG
#error("ProductPageKit's tools build in the debug configuration: the control protocol they share with apps is DEBUG only, so that no release build of an app carries it.")
#endif
public import Foundation
public import ProductPageKitCore
import ProductPageKitControl

/// What a run wrote.
public struct CaptureReport: Sendable {
    public var shots: [URL] = []
    public var components: [URL] = []
    public var reviewScreenshots: [URL] = []

    mutating func merge(_ other: CaptureReport) {
        shots += other.shots
        components += other.components
        reviewScreenshots += other.reviewScreenshots
    }
}

/// Builds the app and captures its scenes into the cache.
///
/// 1. Take each platform's lock and keep the display awake.
/// 2. Run the project's `before` commands, then build each platform in turn
///    into one DerivedData. A platform starts capturing as soon as its build
///    is done, while the next one builds.
/// 3. Simulators: clone the runner's base device once per worker, and once
///    more for the screens tests put up, boot the clones, set the status bar,
///    appearance and text size, and install. Each worker takes a share of the
///    locales.
/// 4. Run the tests that put up screens, App Review screenshots among them,
///    on their own clone in the primary locale, beside the workers. They
///    report ready the same way scenes do.
/// 5. Each locale restarts a simulator in it, when the simulators follow the
///    captured locale and it is not in it already, then is
///    one launch for the scenes drawn in process, or one per variant for an
///    app that decides its data at launch, plus one per scene that needs a
///    cold launch. For each scene: `apply`, wait for `ready`, take frames
///    until two match, write the last. Then each component of the launch's
///    variant is exported.
/// 6. Delete the clones, and raw files and components nothing draws any more.
///
/// The project's capture files are served on loopback for the whole run.
public struct ScreenshotRunner: Sendable {
    public let project: Project
    public let root: URL
    public let cache: Cache
    private let log: @Sendable (String) -> Void

    public init(project: Project, root: URL, cache: Cache, log: @escaping @Sendable (String) -> Void) {
        self.project = project
        self.root = root
        self.cache = cache
        self.log = log
    }

    public func run(_ plan: CapturePlan) async throws -> CaptureReport {
        guard let xcode = project.xcode else { throw RunnerError.noXcodeProject }
        let started = ContinuousClock.now
        let clock = Self.statusBarTime(project.statusBarTime, startedAt: Date())
        if plan.targets.contains(where: { $0.platform.kind == .mac }) { try await MacCapture.prepare() }
        let locks = try plan.targets.map { try Lock(cache.lock($0.platform), purpose: "capture of \($0.platform.name) screenshots") }
        defer { locks.forEach { $0.release() } }
        defer {
            if project.build == .deleteAfterRun { try? FileManager.default.removeItem(at: cache.derivedData) }
        }
        let power = try PowerAssertion(reason: "Capturing \(project.name) screenshots")
        defer { power.release() }
        let files = try await serveFiles()
        defer { files?.stop() }
        let simulators = Simulators()
        if plan.targets.contains(where: { $0.platform.isSimulated }) { try await simulators.deleteAbandonedWorkers() }
        for command in xcode.before {
            log("Running \(command)")
            _ = try await Shell.run(command, in: root)
        }
        let build = XcodeBuild(xcode: xcode, root: root, cache: cache, bundleID: project.bundleID)
        // A platform's workers are what the machine can run at once, so
        // simulator platforms take turns: two at once ran CoreSimulator out
        // of memory. The next platform builds, and the Mac captures, meanwhile.
        let simulatorTurns = Turns()
        // iPhone and iPad build into one products folder, so they share one
        // build: a second would rewrite the app while the first platform's
        // simulators install and launch it.
        var builds: [String: URL] = [:]
        var report = try await withThrowingTaskGroup(of: CaptureReport.self) { group in
            for target in plan.targets {
                let host = try await Host(target.platform, simulators: simulators)
                let folder = XcodeBuild.productsFolder(target.platform.kind)
                let app: URL
                if let built = builds[folder] {
                    app = built
                } else {
                    let sharing = plan.targets.filter { XcodeBuild.productsFolder($0.platform.kind) == folder }
                    let names = sharing.map(\.platform.name).joined(separator: " and ")
                    let building = ContinuousClock.now
                    log("Building for \(names)")
                    app = try await build.build(target.platform, destination: host.destination,
                                                forTesting: sharing.contains { !$0.tests.isEmpty })
                    log("Built for \(names) in \(Self.format(.now - building))")
                    builds[folder] = app
                }
                group.addTask {
                    guard case .simulator = host else {
                        return try await capture(target, app: app, host: host, build: build, simulators: simulators, clock: clock)
                    }
                    return try await simulatorTurns.taking {
                        try await capture(target, app: app, host: host, build: build, simulators: simulators, clock: clock)
                    }
                }
            }
            var report = CaptureReport()
            for try await part in group { report.merge(part) }
            return report
        }
        try prune(plan)
        report.shots.sort { $0.path < $1.path }
        let parts = [counted(report.shots.count, "screenshot")]
            + (report.components.isEmpty ? [] : [counted(report.components.count, "component")])
            + (report.reviewScreenshots.isEmpty ? [] : [counted(report.reviewScreenshots.count, "App Review screenshot")])
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        log("Captured \(list) in \(Self.format(.now - started)), into \(cache.directory.path)")
        return report
    }

    /// The project's capture files, prepared and served at
    /// `http://127.0.0.1:<port>/<name>` until stopped.
    private func serveFiles() async throws -> HTTPServer? {
        guard let files = project.files else { return nil }
        let directory = cache.files
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await files.prepare(in: directory, log: log)
        let names = Set(files.names)
        let server = try HTTPServer(port: files.port) { request in
            let name = String(request.path.dropFirst().prefix { $0 != "?" }).removingPercentEncoding ?? ""
            guard request.method == "GET" || request.method == "HEAD", names.contains(name) else { return .error(404, "no such file") }
            let type = name.hasSuffix(".mp4") || name.hasSuffix(".m4v") ? "video/mp4" : "application/octet-stream"
            return (try? .file(directory.appending(path: name), contentType: type, range: request.headers["range"]))
                ?? .error(404, "no such file")
        }
        _ = try await server.start()
        log("Serving \(counted(names.count, "capture file")) on port \(files.port)")
        return server
    }

    /// Where a platform builds and runs.
    enum Host: Sendable {
        case simulator(base: String, name: String, os: String)
        case mac

        init(_ platform: Platform, simulators: Simulators) async throws {
            switch platform.capture {
            case .simulator(let device):
                let (type, runtime) = try await simulators.resolve(device, for: platform.kind)
                self = .simulator(base: try await simulators.base(type, runtime: runtime), name: "\(type.name), \(runtime.name)",
                                  os: runtime.platform)
            case .window:
                self = .mac
            }
        }

        var destination: String {
            switch self {
            case .simulator(let base, _, let os): "platform=\(os) Simulator,id=\(base)"
            case .mac: Self.macDestination
            }
        }

        static var macDestination: String {
            #if arch(arm64)
            "platform=macOS,arch=arm64"
            #else
            "platform=macOS,arch=x86_64"
            #endif
        }
    }

    /// - Parameter clock: what the simulators' status bars show.
    private func capture(_ target: CapturePlan.Target, app: URL, host: Host, build: XcodeBuild,
                         simulators: Simulators, clock: String) async throws -> CaptureReport {
        switch host {
        case .simulator(let base, let name, let os):
            log("\(target.platform.name): \(counted(target.workers.count, "worker")) on \(name)")
            var clones: [String] = []
            do {
                // Screens a test puts up get a simulator of their own: a test
                // that drives other apps leaves them, and the way back to
                // them in the status bar, behind for whatever launches next.
                let count = target.workers.count + (target.tests.isEmpty ? 0 : 1)
                for worker in 0..<count { clones.append(try await simulators.clone(base, worker: worker)) }
                let drawsSensorBar = try await simulators.drawsSensorBar(base)
                let devices = clones.map { udid in
                    SimulatorWorker(simulators: simulators, udid: udid, os: os, bundleID: project.bundleID,
                                    appearance: project.appearance, contentSize: project.contentSize,
                                    statusBar: target.platform.kind.statusBar,
                                    systemLocale: project.simulatorLocale == .primary ? project.primaryLocale : nil,
                                    time: clock, drawsSensorBar: drawsSensorBar)
                }
                let report = try await withThrowingTaskGroup(of: CaptureReport.self) { group in
                    for (device, locales) in zip(devices, target.workers) {
                        group.addTask {
                            try await device.prepare(app: app, locale: locales[0])
                            return try await self.locales(locales, of: target, device: device)
                        }
                    }
                    if let device = devices.dropFirst(target.workers.count).first {
                        group.addTask {
                            try await device.prepare(app: app, locale: project.primaryLocale)
                            return try await tests(target, device: device, build: build)
                        }
                    }
                    var report = CaptureReport()
                    for try await part in group { report.merge(part) }
                    return report
                }
                await Self.delete(clones, simulators)
                return report
            } catch {
                await Self.delete(clones, simulators)
                throw error
            }
        case .mac:
            let window = if case .window(let size) = target.platform.capture { size } else { CGSize?.none }
            log("\(target.platform.name): \(window.map { "\(Int($0.width)) × \(Int($0.height)) window" } ?? "window at its own size")")
            let device = MacDevice(app: app, appearance: project.appearance, windowSize: window)
            var report = try await tests(target, device: device, build: build)
            report.merge(try await locales(target.workers[0], of: target, device: device))
            return report
        }
    }

    /// The platform's test-drawn screens, in the primary locale, one run of
    /// each test with its scenes in the order listed.
    private func tests(_ target: CapturePlan.Target, device: some CaptureDevice, build: XcodeBuild) async throws -> CaptureReport {
        var report = CaptureReport()
        guard !target.tests.isEmpty else { return report }
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        try await device.use(project.primaryLocale)
        var runs: [(test: String, captures: [TestCapture])] = []
        for capture in target.tests {
            if let index = runs.firstIndex(where: { $0.test == capture.test }) {
                runs[index].captures.append(capture)
            } else {
                runs.append((capture.test, [capture]))
            }
        }
        for run in runs {
            for (capture, file) in try await retrying(run.captures, of: run.test, platform: target.platform, device: device,
                                                      listener: listener, build: build) {
                if target.reviewScreenshots.contains(where: { $0.capture == capture }) {
                    report.reviewScreenshots.append(file)
                } else {
                    report.shots.append(file)
                }
            }
        }
        return report
    }

    /// One worker's locales, over one listener.
    private func locales(_ locales: [StoreLocale], of target: CapturePlan.Target, device: some CaptureDevice) async throws -> CaptureReport {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        var report = CaptureReport()
        for locale in locales {
            try await device.use(locale)
            report.merge(try await capture(target, locale: locale, device: device, listener: listener))
        }
        return report
    }

    private func capture(_ target: CapturePlan.Target, locale: StoreLocale, device: some CaptureDevice,
                         listener: ControlListener) async throws -> CaptureReport {
        try FileManager.default.createDirectory(at: cache.raw(target.platform, locale), withIntermediateDirectories: true)
        let shots = target.shots(in: locale), components = target.components(in: locale)
        let firstScene = shots.first
        let firstVariant = firstScene.map(\.variant) ?? components.first?.variant
        let first = try await launch(target, locale: locale, scene: firstScene?.scene, variant: firstVariant, device: device,
                                     listener: listener)
        let relaunching = Set(first.session.hello.scenes.filter(\.relaunch).map(\.name))
        let launches = CapturePlan.launches(shots, components: components, relaunching: relaunching,
                                            variantsRelaunch: first.session.hello.variantsRelaunch)
        var report = CaptureReport()
        for (index, planned) in launches.enumerated() {
            let (session, pid) = index == 0 ? first : try await launch(target, locale: locale, scene: planned.shots.first?.scene,
                                                                        variant: planned.variant ?? planned.shots.first?.variant,
                                                                        device: device, listener: listener)
            do {
                for shot in planned.shots {
                    let (frame, highlights) = try await session.photograph(SceneRequest(scene: shot.scene, variant: shot.variant)) { ready in
                        try await FrameStability(evidence: cache.logs).settle("\(shot) in \(locale.code)", moving: ready.moving,
                                                                          remeasuring: { try await session.moving(ready.request) },
                                                                          capture: try await device.frames(for: ready))
                    }
                    let file = cache.capture(target.platform, locale, shot)
                    try frame.png.write(to: file, options: .atomic)
                    try highlights.write(for: file)
                    report.shots.append(file)
                    log("  \(target.platform.id) \(locale.code)  \(file.lastPathComponent)")
                }
                for component in planned.components {
                    report.components.append(try await export(component, on: target.platform, in: locale, session: session,
                                                              device: device))
                }
            } catch {
                await device.end(pid)
                throw device.diagnose(error)
            }
            if await !session.quit() { await device.end(pid) }
        }
        return report
    }

    /// Exports `component` and writes it, trimmed to what it draws.
    private func export(_ component: Component, on platform: Platform, in locale: StoreLocale, session: AppSession,
                        device: some CaptureDevice) async throws -> URL {
        let request = ComponentRequest(name: component.name, state: component.state, variant: component.variant)
        let image = try await session.export(request) { window in
            try await FrameStability(evidence: cache.logs).settle("the component \(component) in \(locale.code)",
                                              capture: try device.frames(ofWindow: window, showing: request))
        }
        let file = cache.component(platform, locale, component)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Frame(image: image.trimmingTransparentEdges()).png.write(to: file, options: .atomic)
        log("  \(platform.id) \(locale.code)  \(component.fileName) (component)")
        return file
    }

    /// Starts the app in `locale`, drawing `scene` in `variant` from its
    /// first frame, and checks its hello against the shots.
    private func launch(_ target: CapturePlan.Target, locale: StoreLocale, scene: String?, variant: String?,
                        device: some CaptureDevice, listener: ControlListener) async throws -> (session: AppSession, pid: Int32) {
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let settings = device.settings(port: listener.port, scene: scene, variant: variant)
        let pid = try await device.launch(LocalePreferences(locale).launchArguments + settings.arguments)
        do {
            let session = try await AppSession(mailbox: mailbox, pid: pid, describedAs: "\(project.name) on \(device.name)",
                                               bringToFront: device.bringToFront)
            try session.check(bundleID: project.bundleID, platform: target.platform.controlPlatform,
                              scenes: target.shots(in: locale).map(\.scene))
            return (session, pid)
        } catch {
            await device.end(pid)
            throw device.diagnose(error)
        }
    }

    /// Runs `test` for `captures`, and again for those still missing when it
    /// ended early because the simulator dropped a launch of the test's own,
    /// as it drops the runner's.
    private func retrying(_ captures: [TestCapture], of test: String, platform: Platform, device: some CaptureDevice,
                          listener: ControlListener, build: XcodeBuild) async throws -> [(TestCapture, URL)] {
        var taken: [(TestCapture, URL)] = []
        var attempt = 1
        while true {
            let remaining = captures.filter { capture in !taken.contains { $0.0 == capture } }
            do {
                try await capture(remaining, of: test, platform: platform, device: device, listener: listener, build: build,
                                  into: &taken)
                return taken
            } catch RunnerError.appExited where attempt < Self.testAttempts
                && Self.droppedLaunch(in: cache.logs.appending(path: "\(platform.id)-\(Self.logName(test)).log")) {
                attempt += 1
                log("  \(test): the simulator dropped a launch; running it again")
            }
        }
    }

    static let testAttempts = 3

    /// Whether a test's log shows the simulator dropping a launch.
    static func droppedLaunch(in log: URL) -> Bool {
        (try? String(contentsOf: log, encoding: .utf8)).map(Simulators.isDroppedLaunch) ?? false
    }

    /// Runs `test` once and takes each of `captures`, the scenes it puts up
    /// itself and reports ready through a `CaptureDirector(host: .test)`,
    /// adding each to `taken` as it is written. A UI test's runner is not the
    /// app, so its hello is checked for the platform and the scenes alone.
    private func capture(_ captures: [TestCapture], of test: String, platform: Platform, device: some CaptureDevice,
                         listener: ControlListener, build: XcodeBuild, into taken: inout [(TestCapture, URL)]) async throws {
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let settings = device.testSettings(port: listener.port)
        let output = cache.logs.appending(path: "\(platform.id)-\(Self.logName(test)).log")
        let run = Task {
            defer { mailbox.post(.exited) }
            try await build.test(test, platform: platform, destination: device.testDestination,
                                 environment: settings.environment, log: output)
        }
        let session: AppSession
        do {
            session = try await AppSession(mailbox: mailbox, pid: nil, describedAs: "the test \(test)",
                                           bringToFront: device.bringToFront)
        } catch RunnerError.appExited {
            // `xcodebuild` ended first: its own failure says why, or the test
            // ran without connecting.
            try await run.value
            throw RunnerError.testDidNotConnect(test, log: output)
        } catch {
            run.cancel()
            throw error
        }
        do {
            try session.check(bundleID: nil, platform: platform.controlPlatform, scenes: captures.map(\.scene.scene))
            for capture in captures {
                let (frame, highlights) = try await session.photograph(
                    SceneRequest(scene: capture.scene.scene, variant: capture.scene.variant), within: AppSession.testReadyTimeout
                ) { ready in
                    try await FrameStability(evidence: cache.logs).settle("\(capture.scene) from \(test)", moving: ready.moving,
                                                                      remeasuring: { try await session.moving(ready.request) },
                                                                      capture: try await device.frames(for: ready))
                }
                let file = file(for: capture, on: platform)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try frame.png.write(to: file, options: .atomic)
                try highlights.write(for: file)
                log("  \(platform.id) \(project.primaryLocale.code)  \(file.lastPathComponent) (from \(test))")
                taken.append((capture, file))
            }
            await session.quit()
            try await run.value
        } catch {
            run.cancel()
            throw device.diagnose(error)
        }
    }

    /// An App Review screenshot's file, or a render's, filed as its scene.
    private func file(for capture: TestCapture, on platform: Platform) -> URL {
        if let review = project.reviewScreenshots.first(where: { $0.capture == capture }) {
            return cache.review(platform, review.kind)
        }
        return cache.capture(platform, project.primaryLocale, capture.scene)
    }

    /// `AppUITests/Suite/testName` as a file name.
    static func logName(_ test: String) -> String {
        test.replacingOccurrences(of: "/", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Raw files and components nothing draws and this run did not take: a
    /// renamed scene's, or one captured to look at in an earlier run.
    private func prune(_ plan: CapturePlan) throws {
        for target in plan.targets {
            let kind = target.platform.kind
            for locale in target.workers.flatMap({ $0 }) {
                let primary = locale == project.primaryLocale
                let shots = (project.captures(on: kind) + target.shots(in: locale)
                    + (primary ? project.renderCaptures(on: kind) + project.renderTests(on: kind).map(\.scene) : []))
                    .map { target.platform.fileName(for: $0) }
                let keep = Set(shots.map { $0 + ".png" } + shots.map { $0 + ".json" })
                let components = Set((project.components(on: kind) + target.components(in: locale)
                    + (primary ? project.renderComponents(on: kind) : [])).map { $0.fileName + ".png" })
                try Self.remove(in: cache.raw(target.platform, locale), keeping: keep)
                try Self.remove(in: cache.components(target.platform, locale), keeping: components)
            }
        }
    }

    private static func remove(in directory: URL, keeping keep: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where !keep.contains(file) {
            try FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }

    /// Outside the run's task, so a cancelled run still cleans up.
    private static func delete(_ clones: [String], _ simulators: Simulators) async {
        await Task.detached {
            for clone in clones { try? await simulators.delete(clone) }
        }.value
    }

    /// `9:41`, or the minute `start` falls in as `simctl` takes a date: in
    /// UTC, for the simulator to show in its own region. A date also sets
    /// the date beside the time on an iPad.
    static func statusBarTime(_ time: StatusBarTime, startedAt start: Date) -> String {
        switch time {
        case .nineFortyOne:
            return "9:41"
        case .captureStart:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:00.000'Z'"
            return formatter.string(from: start)
        }
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

extension Platform.Kind {
    /// An iPad's status bar shows the date beside the time; an iPhone's the
    /// time alone, and an Apple TV has none.
    var statusBar: StatusBar {
        switch self {
        case .iPhone: .time
        case .iPad: .dateAndTime
        case .appleTV, .mac: .none
        }
    }
}

extension Platform {
    var isSimulated: Bool {
        if case .simulator = capture { true } else { false }
    }

    var controlPlatform: ControlPlatform {
        switch kind {
        case .iPhone, .iPad: .iOS
        case .appleTV: .tvOS
        case .mac: .macOS
        }
    }
}

/// Work that runs one piece at a time, in the order it asked.
actor Turns {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func taking<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}
