public import CoreGraphics
public import Foundation

/// Generated files, outside the repository:
///
/// ```
/// ~/Library/Caches/ProductPageKit/
///   locks/macos.lock                    the screen, shared by every app
///   locks/xcodebuild.lock               one build or archive at a time, for every app
///   <bundle id>/
///     derived/                          one DerivedData for every platform
///     raw/<platform>/<locale>/<shot>.png
///     raw/<platform>/<locale>/<shot>.json  its highlights, when it has any
///     review/<platform>/<kind>.png
///     components/<platform>/<locale>/<component>.png
///     files/                            what the project's CaptureFiles prepare
///     framed/<key>.png                  named after everything drawn into it
///     framed/index.json                 (platform, locale, shot) -> file
///     videos/<key>.mp4
///     videos/index.json                 (kind, locale) -> file
///     logs/                             xcodebuild's output, latest run
///     locks/<platform>.lock
/// ```
public struct Cache: Sendable {
    /// `~/Library/Caches/ProductPageKit`.
    public let root: URL
    public let bundleID: String

    public init(bundleID: String, root: URL = Cache.standardRoot) {
        self.root = root
        self.bundleID = bundleID
    }

    public static var standardRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ProductPageKit")
    }

    public var directory: URL { root.appending(path: bundleID) }
    public var derivedData: URL { directory.appending(path: "derived") }
    public var logs: URL { directory.appending(path: "logs") }

    public func raw(_ platform: Platform, _ locale: StoreLocale) -> URL {
        directory.appending(path: "raw/\(platform.id)/\(locale.code)")
    }

    /// The latest capture of `shot`: `raw/ios/en/01_inbox.png`.
    public func capture(_ platform: Platform, _ locale: StoreLocale, _ shot: Shot) -> URL {
        raw(platform, locale).appending(path: "\(platform.fileName(for: shot)).png")
    }

    public func components(_ platform: Platform, _ locale: StoreLocale) -> URL {
        directory.appending(path: "components/\(platform.id)/\(locale.code)")
    }

    /// The latest export of `component`: `components/ios/en/sources-pro.png`.
    public func component(_ platform: Platform, _ locale: StoreLocale, _ component: Component) -> URL {
        components(platform, locale).appending(path: "\(component.fileName).png")
    }

    /// Where `render` is taken: its capture's, its component's, or its
    /// test's file, which is filed as the test's scene.
    public func file(_ render: Render, on platform: Platform, in locale: StoreLocale) -> URL {
        switch render.source {
        case .capture(let shot, _): capture(platform, locale, shot)
        case .component(let component, _): self.component(platform, locale, component)
        case .test(let test, _): capture(platform, locale, test.scene)
        }
    }

    public var files: URL { directory.appending(path: "files") }

    public var framed: URL { directory.appending(path: "framed") }
    public var videos: URL { directory.appending(path: "videos") }

    public func review(_ platform: Platform, _ kind: ReviewScreenshot.Kind) -> URL {
        directory.appending(path: "review/\(platform.id)/\(kind.rawValue).png")
    }

    /// Held while `xcodebuild` builds or archives, for every app: two
    /// compiles at once, an archive's above all, run a Mac out of memory.
    public var buildLock: URL { root.appending(path: "locks/xcodebuild.lock") }

    /// Simulators are cloned per run, so two apps capture side by side. The
    /// Mac captures the front window, which there is one of.
    public func lock(_ platform: Platform) -> URL {
        switch platform.capture {
        case .simulator: directory.appending(path: "locks/\(platform.id).lock")
        case .window: root.appending(path: "locks/\(platform.id).lock")
        }
    }
}

/// The views a capture's app marked with `.captureHighlight()`, in the
/// capture's pixels from its top left, top to bottom. Kept beside the
/// capture, and only while it has any.
public struct Highlights: Codable, Equatable, Sendable {
    public var rects: [CGRect]

    public init(_ rects: [CGRect]) {
        self.rects = rects
    }

    public static func url(for capture: URL) -> URL {
        capture.deletingPathExtension().appendingPathExtension("json")
    }

    /// The file's bytes, or nil for a capture with no highlights.
    public static func data(for capture: URL) -> Data? {
        try? Data(contentsOf: url(for: capture))
    }

    public func write(for capture: URL) throws {
        let url = Self.url(for: capture)
        guard !rects.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What a rendered file in the cache is for. Rendered files are named after
/// a hash of everything that went into them, so an unchanged one is found
/// rather than drawn again, and the index says which file is current.
public struct CacheIndex<Item: Codable & Hashable & Sendable>: Codable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public let item: Item
        public let file: String
    }

    public private(set) var entries: [Entry]

    public init() {
        entries = []
    }

    /// The index in `directory`, or an empty one.
    public static func read(in directory: URL) -> CacheIndex {
        (try? JSONDecoder().decode(CacheIndex.self, from: Data(contentsOf: directory.appending(path: fileName)))) ?? CacheIndex()
    }

    public func file(for item: Item) -> String? {
        entries.first { $0.item == item }?.file
    }

    /// Names `files` for their items, after dropping every entry `isStale`
    /// says a run replaced or left behind, then writes the index in
    /// `directory` and deletes the files it no longer names.
    public static func update(in directory: URL, with files: [(item: Item, file: String)], dropping isStale: (Item) -> Bool) throws {
        var index = read(in: directory)
        let items = Set(files.map(\.item))
        index.entries.removeAll { isStale($0.item) || items.contains($0.item) }
        index.entries += files.map { Entry(item: $0.item, file: $0.file) }
        try index.write(in: directory)
    }

    /// Deletes the files in `directory` its index does not name.
    public static func prune(in directory: URL) throws {
        try read(in: directory).write(in: directory)
    }

    /// Writes the index, then deletes every file in `directory` it does not
    /// name.
    private func write(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
        let current = Set(entries.map(\.file) + [Self.fileName])
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where !current.contains(name) {
            try FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    static var fileName: String { "index.json" }
}

/// A framed screenshot.
public struct FramedItem: Codable, Hashable, Sendable {
    public let platform: String
    public let locale: String
    public let shot: String
    public let list: ShotList

    public init(_ subject: FrameSubject, locale: StoreLocale) {
        platform = subject.platform.rawValue
        self.locale = locale.code
        shot = subject.shot.name
        list = subject.list
    }
}

/// A rendered video.
public struct VideoItem: Codable, Hashable, Sendable {
    public let kind: String
    public let locale: String

    public init(kind: CreativeAsset.Kind, locale: StoreLocale) {
        self.kind = kind.rawValue
        self.locale = locale.code
    }
}
