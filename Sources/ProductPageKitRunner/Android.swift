import Foundation
import ProductPageKitCore

/// The Android SDK's tools: `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, or Android
/// Studio's `~/Library/Android/sdk`.
struct AndroidSDK: Sendable {
    let adb: String
    let emulator: String

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AndroidSDK {
        let candidates: [String?] = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Android/sdk").path]
        for root in candidates.compactMap({ $0 }) where !root.isEmpty {
            let adb = "\(root)/platform-tools/adb"
            if FileManager.default.isExecutableFile(atPath: adb) {
                return AndroidSDK(adb: adb, emulator: "\(root)/emulator/emulator")
            }
        }
        throw RunnerError.noAndroidSDK
    }

    func adb(_ arguments: [String]) async throws -> String {
        String(decoding: try await Shell.run(adb, arguments, describedAs: "adb \(arguments.joined(separator: " "))"), as: UTF8.self)
    }

    /// The serials of the devices and emulators adb has online.
    func online() async throws -> [String] {
        try await adb(["devices"]).split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
    }

    /// The emulator of AVD `name` that is running, if one is.
    func running(avd name: String) async throws -> String? {
        for serial in try await online() where serial.hasPrefix("emulator-") {
            let answer = try? await adb(["-s", serial, "emu", "avd", "name"])
            if answer?.split(separator: "\n").first.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) == name {
                return serial
            }
        }
        return nil
    }

    /// The AVDs the emulator can boot.
    func avds() async throws -> [String] {
        String(decoding: try await Shell.run(emulator, ["-list-avds"]), as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("INFO") }
    }
}

/// The console ports this process has booted emulators on, so two booted at
/// once never take the same one before adb lists either.
actor EmulatorPorts {
    static let shared = EmulatorPorts()
    private var claimed: Set<Int> = []

    /// An even port from 5554 that neither adb lists in `used` nor this
    /// process has claimed.
    func claim(avoiding used: Set<Int>) -> Int? {
        guard let port = stride(from: 5554, through: 5682, by: 2).first(where: { !used.contains($0) && !claimed.contains($0) })
        else { return nil }
        claimed.insert(port)
        return port
    }

    func release(_ port: Int) {
        claimed.remove(port)
    }
}

/// One Android emulator or device for a run: found running, or booted for
/// the run and shut down after it.
struct AndroidConnection: Sendable {
    let sdk: AndroidSDK
    let serial: String
    let device: AndroidDevice
    /// The emulator the run booted, which it shuts down.
    private let booted: Process?

    static let bootTimeout: Duration = .seconds(300)

    /// Finds `device` online, or boots its AVD with no window, its output in
    /// `log`.
    static func open(_ device: AndroidDevice, sdk: AndroidSDK, log: URL) async throws -> AndroidConnection {
        _ = try await sdk.adb(["start-server"])
        switch device {
        case .device(let serial):
            guard try await sdk.online().contains(serial) else { throw RunnerError.noAndroidDevice(serial) }
            return AndroidConnection(sdk: sdk, serial: serial, device: device, booted: nil)
        case .emulator(let name):
            if let serial = try await sdk.running(avd: name) {
                return AndroidConnection(sdk: sdk, serial: serial, device: device, booted: nil)
            }
            guard try await sdk.avds().contains(name) else { throw RunnerError.noAVD(name, available: try await sdk.avds()) }
            let used = Set(try await sdk.online().compactMap { Int($0.dropFirst("emulator-".count)) })
            guard let port = await EmulatorPorts.shared.claim(avoiding: used) else { throw RunnerError.timedOut("a free emulator port") }
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(filePath: sdk.emulator)
            process.arguments = ["-avd", name, "-port", "\(port)", "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot-save"]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let connection = AndroidConnection(sdk: sdk, serial: "emulator-\(port)", device: device, booted: process)
            do {
                try await connection.awaitBoot(log: log)
            } catch {
                await connection.close()
                throw error
            }
            return connection
        }
    }

    /// Returns once the system says it has finished booting.
    private func awaitBoot(log: URL) async throws {
        let deadline = ContinuousClock.now + Self.bootTimeout
        while ContinuousClock.now < deadline {
            if let booted, !booted.isRunning { throw RunnerError.emulatorExited(device.name, log: log) }
            // The package manager answers a little after the boot is
            // marked complete, and an install before it fails.
            if (try? await shell("getprop sys.boot_completed"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
               (try? await shell("pm path android"))?.hasPrefix("package:") == true {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw RunnerError.timedOut("\(device) to boot")
    }

    /// Shuts down an emulator the run booted; leaves anything else running.
    func close() async {
        guard let booted else { return }
        _ = try? await sdk.adb(["-s", serial, "emu", "kill"])
        for _ in 0..<30 where booted.isRunning { try? await Task.sleep(for: .seconds(1)) }
        if booted.isRunning { booted.terminate() }
        if let port = Int(serial.dropFirst("emulator-".count)) { await EmulatorPorts.shared.release(port) }
    }

    func adb(_ arguments: [String]) async throws -> String {
        try await sdk.adb(["-s", serial] + arguments)
    }

    func shell(_ command: String) async throws -> String {
        try await adb(["shell", command])
    }

    /// The screen as a PNG.
    func screencap() async throws -> Frame {
        try Frame(png: try await Shell.run(sdk.adb, ["-s", serial, "exec-out", "screencap", "-p"],
                                           describedAs: "adb exec-out screencap -p"))
    }

    /// The system build, screen size and density, which a capture is stamped
    /// with.
    func stamp() async throws -> String {
        let parts = try await [shell("getprop ro.build.fingerprint"), shell("wm size"), shell("wm density")]
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
    }
}

/// What a run sets on an Android emulator or device before it captures, and
/// puts back after: the app installed, demo mode's status bar at the clock
/// the run shows with a full battery and signal and no notifications, the
/// appearance and the font scale.
struct AndroidStage: Sendable {
    let connection: AndroidConnection
    private let night: String
    private let fontScale: String

    /// - Parameter clock: `0941`, as demo mode's clock takes it.
    static func prepare(_ connection: AndroidConnection, apk: URL, project: Project, clock: String,
                        filesPort: UInt16?) async throws -> AndroidStage {
        _ = try await connection.adb(["install", "-r", "-t", "-g", apk.path])
        let night = try await connection.shell("cmd uimode night").contains("yes") ? "yes" : "no"
        let fontScale = try await connection.shell("settings get system font_scale").trimmingCharacters(in: .whitespacesAndNewlines)
        let stage = AndroidStage(connection: connection, night: night, fontScale: fontScale)
        _ = try await connection.shell("cmd uimode night \(project.appearance == .dark ? "yes" : "no")")
        _ = try await connection.shell("settings put system font_scale \(project.contentSize.androidFontScale)")
        _ = try await connection.shell("settings put global sysui_demo_allowed 1")
        for command in ["enter", "clock -e hhmm \(clock)", "battery -e level 100 -e plugged false",
                        "network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4",
                        "notifications -e visible false"] {
            _ = try await connection.shell("am broadcast -a com.android.systemui.demo -e command \(command)")
        }
        if let filesPort { _ = try await connection.adb(["reverse", "tcp:\(filesPort)", "tcp:\(filesPort)"]) }
        return stage
    }

    /// Leaves the device as it was found, but for the app installed.
    func restore(applicationID: String, filesPort: UInt16?) async {
        _ = try? await connection.shell("am force-stop \(applicationID)")
        _ = try? await connection.shell("cmd locale set-app-locales \(applicationID) --locales ''")
        _ = try? await connection.shell("am broadcast -a com.android.systemui.demo -e command exit")
        _ = try? await connection.shell("cmd uimode night \(night)")
        _ = try? await connection.shell(fontScale == "null" ? "settings delete system font_scale" : "settings put system font_scale \(fontScale)")
        if let filesPort { _ = try? await connection.adb(["reverse", "--remove", "tcp:\(filesPort)"]) }
    }
}

extension ContentSize {
    /// The step of Android's font scale nearest this Dynamic Type size;
    /// large, the default, is 1.
    var androidFontScale: String {
        switch self {
        case .extraSmall, .small: "0.85"
        case .medium, .large: "1.0"
        case .extraLarge: "1.15"
        case .extraExtraLarge: "1.3"
        case .extraExtraExtraLarge: "1.5"
        case .accessibilityMedium: "1.8"
        case .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge: "2.0"
        }
    }
}
