import CryptoKit
import Foundation
import ProductPageKitControl
import ProductPageKitCore

/// What a capture was taken from, so a run keeps the captures whose inputs
/// have not changed and takes only the rest.
///
/// A capture's inputs are the app as built (every byte of the bundles beside
/// it, which include the UI tests' runners), the device it is taken on, the
/// project's settings for how it looks, and the files the app is served. Its
/// scene and variant are in its name. None of it is the date: a status bar
/// that shows the capture start keeps the time of the run that took it.
struct CaptureInputs: Sendable {
    let stamp: String
    /// Takes every capture again.
    let force: Bool

    /// The record of what `scope` (a locale's captures, or the test-drawn
    /// ones) in `platform` was taken from.
    func ledger(in cache: Cache, platform: Platform, scope: String) -> CaptureLedger {
        CaptureLedger(file: cache.directory.appending(path: "ledger/\(platform.id)/\(scope).json"), stamp: stamp, force: force)
    }
}

/// The stamp each capture file in one scope was taken under, kept beside the
/// cache's raw files and components, which a run prunes down to what it draws.
struct CaptureLedger {
    private let file: URL
    private let stamp: String
    private var stamps: [String: String]

    init(file: URL, stamp: String, force: Bool) {
        self.file = file
        self.stamp = stamp
        stamps = force ? [:] : (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// Whether `key` was taken under this stamp and its `files` are there.
    func isCurrent(_ key: String, files: [URL]) -> Bool {
        stamps[key] == stamp && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Notes that `key` was taken under this stamp. Written at once: a run
    /// that stops keeps what it had taken.
    mutating func record(_ key: String) throws {
        stamps[key] = stamp
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stamps).write(to: file, options: .atomic)
    }

    static func shotKey(_ fileName: String) -> String { "shot/\(fileName)" }
    static func componentKey(_ fileName: String) -> String { "component/\(fileName)" }
}

/// The stamps of one run. A bundle is hashed once however many platforms
/// share its products folder.
actor CaptureFingerprints {
    private var folders: [URL: String] = [:]

    /// - Parameter device: what the captures are taken on: the simulator
    ///   and its runtime, or the Mac's window and system.
    func inputs(for platform: Platform, app: URL, device: String, project: Project, files: [URL], force: Bool) -> CaptureInputs {
        let folder = app.deletingLastPathComponent()
        let build: String
        if let known = folders[folder] {
            build = known
        } else {
            build = Self.digest(ofBundlesIn: folder)
            folders[folder] = build
        }
        let parts = [
            "protocol \(ControlProtocol.version)", "platform \(platform.id)", "device \(device)", "build \(build)",
            "appearance \(project.appearance)", "text \(project.contentSize)", "status bar \(platform.kind.statusBar)",
            "clock \(project.statusBarTime == .nineFortyOne ? "9:41" : "start")", "locale \(project.simulatorLocale)",
        ] + files.map { file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            return "file \(file.lastPathComponent) \(size)"
        }
        return CaptureInputs(stamp: Self.hex(SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))), force: force)
    }

    /// Every `.app` in `folder` by path and content, symbolic links by where
    /// they point: the app, its extensions and the UI tests' runners.
    nonisolated static func digest(ofBundlesIn folder: URL) -> String {
        var hasher = SHA256()
        let manager = FileManager.default
        let bundles = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        for bundle in bundles {
            let root = folder.appending(path: bundle)
            hasher.update(data: Data(bundle.utf8))
            let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let urls = (enumerator?.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
            for url in urls {
                hasher.update(data: Data(url.path.dropFirst(root.path.count).utf8))
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    hasher.update(data: Data(((try? manager.destinationOfSymbolicLink(atPath: url.path)) ?? "").utf8))
                } else if values?.isRegularFile == true, let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
                }
            }
        }
        return hex(hasher.finalize())
    }

    private nonisolated static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
