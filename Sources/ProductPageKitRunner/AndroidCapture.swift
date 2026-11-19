import CoreGraphics
import Foundation
import ProductPageKitCore

/// How the runner and an Android app agree on a scene or a component: the
/// runner starts the app's activity afresh with what to show in extras, and
/// the app logs that it is ready, with the rects of what it marked.
enum AndroidScene {
    /// Bumped when the agreement changes, which takes every capture again.
    static let contract = "android scene 2"
    static let sceneExtra = "productPageScene"
    static let variantExtra = "productPageVariant"
    static let componentExtra = "productPageComponent"
    static let stateExtra = "productPageComponentState"
    static let logTag = "ProductPage"

    /// `am start`'s arguments for `shot`: waiting for the launch, the app
    /// stopped first.
    static func start(_ shot: Shot, activity: String) -> [String] {
        start(activity, [sceneExtra: shot.scene, variantExtra: shot.variant])
    }

    /// `am start`'s arguments for `component`, in its state and variant.
    static func start(_ component: Component, activity: String) -> [String] {
        start(activity, [componentExtra: component.name, stateExtra: component.state, variantExtra: component.variant])
    }

    private static func start(_ activity: String, _ extras: KeyValuePairs<String, String?>) -> [String] {
        ["am", "start", "-W", "-S", "-n", activity] + extras.flatMap { key, value in value.map { ["--es", key, $0] } ?? [] }
    }

    /// What the app's ready line names a scene by: the scene.
    static func subject(_ shot: Shot) -> String { shot.scene }

    /// What the app's ready line names a component by: its name, and its
    /// state after `@`.
    static func subject(_ component: Component) -> String { component.name + (component.state.map { "@\($0)" } ?? "") }

    /// The rects `line` reports when it says `subject` is ready, or nil for
    /// any other line. The app logs `ready <subject>`, then a rect as
    /// `left,top,right,bottom` in the screen's pixels for each view it
    /// marked: a scene's highlights, or a component's own bounds.
    static func readiness(_ line: some StringProtocol, of subject: String) throws -> [CGRect]? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == "ready", words[1] == subject else { return nil }
        return try words.dropFirst(2).map { word in
            let sides = word.split(separator: ",").compactMap { Int($0) }
            guard sides.count == 4, sides[2] > sides[0], sides[3] > sides[1] else {
                throw RunnerError.malformedReady(String(line).trimmingCharacters(in: .whitespaces))
            }
            return CGRect(x: sides[0], y: sides[1], width: sides[2] - sides[0], height: sides[3] - sides[1])
        }
    }

    static let readyTimeout: Duration = .seconds(60)
}

extension ScreenshotRunner {
    /// Builds the APK with the project's commands, one build on the Mac at a
    /// time, and returns it.
    func buildAndroid(_ app: AndroidApp) async throws -> URL {
        if !app.build.isEmpty {
            let lock = try await Lock.waiting(for: cache.buildLock) { [log] holder in
                log("Waiting for another build on this Mac" + (holder.map { " (pid \($0))" } ?? "") + " to finish")
            }
            defer { lock.release() }
            let started = ContinuousClock.now
            log("Building for Android")
            for command in app.build {
                _ = try await Shell.run("/bin/zsh", ["-c", command], in: root, log: cache.logs.appending(path: "android-build.log"),
                                        describedAs: command)
            }
            log("Built for Android in \(Self.format(.now - started))")
        }
        let apk = root.appending(path: app.apk)
        guard FileManager.default.fileExists(atPath: apk.path) else { throw RunnerError.noAPK(apk.path) }
        return apk
    }

    /// One Android platform's captures, every locale in turn on one emulator
    /// or device, each scene and component in a launch of its own.
    func captureAndroid(_ target: CapturePlan.Target, on device: AndroidDevice, app: AndroidApp, apk: URL, sdk: AndroidSDK,
                        clock: String, files: [URL], force: Bool) async throws -> CaptureReport {
        let connection = try await AndroidConnection.open(device, sdk: sdk,
                                                          log: cache.logs.appending(path: "\(target.platform.id)-emulator.log"))
        do {
            let report = try await captureAndroid(target, on: connection, app: app, apk: apk, clock: clock, files: files,
                                                  force: force)
            await connection.close()
            return report
        } catch {
            await connection.close()
            throw error
        }
    }

    private func captureAndroid(_ target: CapturePlan.Target, on connection: AndroidConnection, app: AndroidApp, apk: URL,
                                clock: String, files: [URL], force: Bool) async throws -> CaptureReport {
        let device = try await connection.stamp()
        let inputs = CaptureFingerprints.inputs(for: target.platform, contract: AndroidScene.contract,
                                                build: try CaptureFingerprints.digest(of: apk), device: device,
                                                project: project, files: files, force: force)
        let pending = pending(in: target, inputs: inputs)
        guard !pending.locales.isEmpty else {
            log("\(target.platform.name): \(counted(pending.unchanged, "capture")) up to date")
            return CaptureReport(unchanged: pending.unchanged)
        }
        log("\(target.platform.name): \(connection.device) (\(connection.serial))")
        let port = project.files?.port
        let stage = try await AndroidStage.prepare(connection, apk: apk, project: project, clock: clock, filesPort: port)
        var report = CaptureReport(unchanged: pending.unchanged)
        do {
            for locale in pending.locales {
                _ = try await connection.shell("cmd locale set-app-locales \(app.applicationID) --locales \(locale.app)")
                var ledger = inputs.ledger(in: cache, platform: target.platform, scope: locale.code)
                try FileManager.default.createDirectory(at: cache.raw(target.platform, locale), withIntermediateDirectories: true)
                let (shots, components) = stale(in: target, locale: locale, ledger: ledger)
                for shot in shots {
                    let what = "\(shot) in \(locale.code)"
                    let highlights = try await show(AndroidScene.start(shot, activity: app.component), subject: AndroidScene.subject(shot),
                                                    app: app, on: connection, describedAs: what)
                    let frame = try await FrameStability(evidence: cache.logs).settle(what) { try await connection.screencap() }
                    try frame.check(what, on: target.platform)
                    try checkDistinct(frame, of: shot, in: target, locale: locale, ledger: ledger)
                    let file = cache.capture(target.platform, locale, shot)
                    try frame.png.write(to: file, options: .atomic)
                    try Highlights(highlights.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }).write(for: file)
                    try ledger.record(CaptureLedger.shotKey(file.lastPathComponent))
                    report.shots.append(file)
                    log("  \(target.platform.id) \(locale.code)  \(file.lastPathComponent)")
                }
                for component in components {
                    let what = "the component \(component) in \(locale.code)"
                    let rects = try await show(AndroidScene.start(component, activity: app.component),
                                               subject: AndroidScene.subject(component), app: app, on: connection, describedAs: what)
                    guard rects.count == 1 else { throw RunnerError.componentBounds(component.description, count: rects.count) }
                    let frame = try await FrameStability(evidence: cache.logs).settle(what) { try await connection.screencap() }
                    try frame.check(what, on: target.platform)
                    guard let crop = try frame.cropped(to: rects[0]) else { throw RunnerError.componentOffScreen(component.description) }
                    let file = cache.component(target.platform, locale, component)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try crop.png.write(to: file, options: .atomic)
                    try ledger.record(CaptureLedger.componentKey(file.lastPathComponent))
                    report.components.append(file)
                    log("  \(target.platform.id) \(locale.code)  \(component.fileName) (component)")
                }
            }
        } catch {
            await stage.restore(applicationID: app.applicationID, filesPort: port)
            throw error
        }
        await stage.restore(applicationID: app.applicationID, filesPort: port)
        return report
    }

    /// Starts the app with `start` and returns the rects it reports once it
    /// logs that `subject` is ready.
    private func show(_ start: [String], subject: String, app: AndroidApp, on connection: AndroidConnection,
                      describedAs what: String) async throws -> [CGRect] {
        _ = try await connection.adb(["logcat", "-c"])
        _ = try await connection.adb(["shell"] + start)
        let deadline = ContinuousClock.now + AndroidScene.readyTimeout
        while ContinuousClock.now < deadline {
            let logged = try await connection.adb(["logcat", "-d", "-v", "raw", "-s", "\(AndroidScene.logTag):I"])
            for line in logged.split(separator: "\n") {
                if let rects = try AndroidScene.readiness(line, of: subject) { return rects }
            }
            if (try? await connection.shell("pidof \(app.applicationID)"))?.isEmpty ?? true {
                throw RunnerError.appExited(app.applicationID, before: "it said \(what) was ready")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RunnerError.timedOut("\(app.applicationID) to log `ready \(subject)` under \(AndroidScene.logTag) for \(what)")
    }

    /// `0941`, or the minute `start` falls in on this Mac's clock, as
    /// Android's demo mode takes it.
    static func androidClock(_ time: StatusBarTime, startedAt start: Date) -> String {
        switch time {
        case .nineFortyOne:
            return "0941"
        case .captureStart:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HHmm"
            return formatter.string(from: start)
        }
    }
}
