import CoreGraphics
public import Foundation
public import ProductPageKitCore

/// One line of `productpage doctor`.
public struct DoctorCheck: Sendable {
    public enum Status: String, Sendable {
        case ok
        case warning
        case failed
    }

    public let status: Status
    public let message: String

    public init(_ status: Status, _ message: String) {
        self.status = status
        self.message = message
    }
}

/// What a capture needs from this machine, checked without building or
/// launching anything.
public struct Doctor: Sendable {
    public let project: Project
    public let root: URL

    public init(project: Project, root: URL) {
        self.project = project
        self.root = root
    }

    public func checks() async -> [DoctorCheck] {
        var checks = [await xcode(), xcodeProject()]
        let simulators = Simulators()
        for platform in project.platforms {
            guard case .simulator(let device) = platform.capture else { continue }
            checks.append(await simulator(platform, device, simulators))
        }
        if project.platforms.contains(where: { $0.isSimulated }) {
            checks.append(await abandonedWorkers(simulators))
        }
        if project.platforms.contains(where: { $0.kind == .mac }) {
            checks.append(CGPreflightScreenCaptureAccess()
                ? DoctorCheck(.ok, "Screen Recording is allowed for this terminal")
                : DoctorCheck(.failed, RunnerError.noScreenRecording.description))
            if MacCapture.isScreenLocked { checks.append(DoctorCheck(.warning, RunnerError.screenLocked.description)) }
        }
        return checks
    }

    private func xcode() async -> DoctorCheck {
        do {
            let path = String(decoding: try await Shell.run("/usr/bin/xcode-select", ["-p"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.contains("CommandLineTools") else {
                return DoctorCheck(.failed, "xcode-select points at the Command Line Tools. Run `sudo xcode-select -s /Applications/Xcode.app`.")
            }
            let version = String(decoding: try await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"]), as: UTF8.self)
                .split(separator: "\n").map { $0.replacingOccurrences(of: "Build version ", with: "") }
            return DoctorCheck(.ok, "\(version.first ?? "Xcode") (\(version.dropFirst().first ?? "")) at \(path)")
        } catch {
            return DoctorCheck(.failed, "Xcode: \(error)")
        }
    }

    private func xcodeProject() -> DoctorCheck {
        guard let xcode = project.xcode else {
            return DoctorCheck(.warning, "No Xcode project (Project.xcode), so screenshots cannot be captured")
        }
        if FileManager.default.fileExists(atPath: root.appending(path: xcode.path).path) {
            return DoctorCheck(.ok, "\(xcode.path), scheme \(xcode.scheme)")
        }
        guard !xcode.before.isEmpty else {
            return DoctorCheck(.failed, "\(xcode.path) does not exist")
        }
        return DoctorCheck(.ok, "\(xcode.path), scheme \(xcode.scheme), made by \(xcode.before.map { "`\($0)`" }.joined(separator: ", "))")
    }

    private func simulator(_ platform: Platform, _ device: SimulatorDevice, _ simulators: Simulators) async -> DoctorCheck {
        do {
            let (type, runtime) = try await simulators.resolve(device, for: platform.kind)
            return DoctorCheck(.ok, "\(platform.name): \(type.name), \(runtime.name)")
        } catch {
            return DoctorCheck(.failed, "\(platform.name): \(error)")
        }
    }

    private func abandonedWorkers(_ simulators: Simulators) async -> DoctorCheck {
        do {
            let abandoned = try await simulators.abandonedWorkers()
            return abandoned.isEmpty
                ? DoctorCheck(.ok, "No simulators left behind by an earlier capture")
                : DoctorCheck(.warning, "\(counted(abandoned.count, "simulator")) left behind by an earlier capture; the next capture deletes them")
        } catch {
            return DoctorCheck(.failed, "Simulators: \(error)")
        }
    }
}
