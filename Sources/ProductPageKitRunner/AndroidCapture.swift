import Foundation
import ProductPageKitCore

/// How the runner and an Android app agree on a scene: the runner starts the
/// app's activity afresh with the scene in an extra, and the app logs that
/// it is ready.
enum AndroidScene {
    /// Bumped when the agreement changes, which takes every capture again.
    static let contract = "android scene 1"
    static let sceneExtra = "productPageScene"
    static let variantExtra = "productPageVariant"
    static let logTag = "ProductPage"

    /// `am start`'s arguments for `shot`: waiting for the launch, the app
    /// stopped first.
    static func start(_ shot: Shot, component: String) -> [String] {
        ["am", "start", "-W", "-S", "-n", component, "--es", sceneExtra, shot.scene]
            + (shot.variant.map { ["--es", variantExtra, $0] } ?? [])
    }

    /// What the app logs under `logTag` once `scene` is on screen.
    static func ready(_ scene: String) -> String { "ready \(scene)" }

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
    /// or device, each scene in a launch of its own.
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
                for shot in stale(in: target, locale: locale, ledger: ledger).shots {
                    let what = "\(shot) in \(locale.code)"
                    try await show(shot, app: app, on: connection, describedAs: what)
                    let frame = try await FrameStability(evidence: cache.logs).settle(what) { try await connection.screencap() }
                    try frame.check(what, on: target.platform)
                    try checkDistinct(frame, of: shot, in: target, locale: locale, ledger: ledger)
                    let file = cache.capture(target.platform, locale, shot)
                    try frame.png.write(to: file, options: .atomic)
                    try Highlights([]).write(for: file)
                    try ledger.record(CaptureLedger.shotKey(file.lastPathComponent))
                    report.shots.append(file)
                    log("  \(target.platform.id) \(locale.code)  \(file.lastPathComponent)")
                }
            }
        } catch {
            await stage.restore(applicationID: app.applicationID, filesPort: port)
            throw error
        }
        await stage.restore(applicationID: app.applicationID, filesPort: port)
        return report
    }

    /// Starts the app on `shot` and returns once it logs that the scene is
    /// ready.
    private func show(_ shot: Shot, app: AndroidApp, on connection: AndroidConnection, describedAs what: String) async throws {
        _ = try await connection.adb(["logcat", "-c"])
        _ = try await connection.adb(["shell"] + AndroidScene.start(shot, component: app.component))
        let ready = AndroidScene.ready(shot.scene)
        let deadline = ContinuousClock.now + AndroidScene.readyTimeout
        while ContinuousClock.now < deadline {
            let logged = try await connection.adb(["logcat", "-d", "-v", "raw", "-s", "\(AndroidScene.logTag):I"])
            if logged.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ready }) { return }
            if (try? await connection.shell("pidof \(app.applicationID)"))?.isEmpty ?? true {
                throw RunnerError.appExited(app.applicationID, before: "it said \(what) was ready")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RunnerError.timedOut("\(app.applicationID) to log `\(ready)` under \(AndroidScene.logTag) for \(what)")
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
