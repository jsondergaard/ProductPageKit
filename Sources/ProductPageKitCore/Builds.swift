public import Foundation

/// Archiving the app and uploading it to TestFlight, from the project's
/// `xcode`. Builds sign automatically, with the App Store Connect API key.
public struct Builds: Sendable {
    /// The App Store platforms archived. Nil: those the product page has.
    public var platforms: [StorePlatform]?
    public var numbering: BuildNumbering
    public var audience: TestFlightAudience
    /// Shell commands run at the repository root after each archive, with
    /// its path in `PRODUCTPAGE_ARCHIVE`, such as one that sends its symbols
    /// to a crash reporter. They run while the next platform archives, and
    /// every archive and its commands finish before anything uploads, so one
    /// that fails uploads nothing.
    public var afterArchive: [String]

    public init(
        platforms: [StorePlatform]? = nil,
        numbering: BuildNumbering = .next,
        audience: TestFlightAudience = .internalOnly,
        afterArchive: [String] = []
    ) {
        self.platforms = platforms
        self.numbering = numbering
        self.audience = audience
        self.afterArchive = afterArchive
    }

    /// The variable an `afterArchive` command finds the archive in.
    public static let archiveVariable = "PRODUCTPAGE_ARCHIVE"
}

/// How an upload's build number follows the highest App Store Connect has,
/// across every platform and version.
public enum BuildNumbering: Sendable, Equatable {
    /// One more: 88 becomes 89, and 88.2 becomes 89.
    case next
    /// The next minor number: 88 becomes 88.1, and 88.1 becomes 88.2. For an
    /// app CI also uploads with whole numbers, such as Xcode Cloud's build
    /// number, whose next build still sorts above these.
    case minor

    public func number(after uploaded: [BuildNumber]) -> BuildNumber {
        let highest = uploaded.max() ?? BuildNumber(major: 0)
        switch self {
        case .next: return BuildNumber(major: highest.major + 1)
        case .minor: return BuildNumber(major: highest.major, minor: highest.minor + 1)
        }
    }
}

/// Who can test an upload.
public enum TestFlightAudience: Sendable, Equatable, CustomStringConvertible {
    /// Internal testers only. App Store Connect never offers the build for
    /// App Store review.
    case internalOnly
    /// Internal and external testers, and App Store review.
    case everyone

    public var description: String {
        switch self {
        case .internalOnly: "internal testers only"
        case .everyone: "every tester and App Store review"
        }
    }
}

/// A `CFBundleVersion`: one to three whole numbers joined by periods,
/// compared number by number with missing ones as zero, as App Store
/// Connect orders builds.
public struct BuildNumber: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        self.components = components
    }

    public init(major: Int, minor: Int? = nil) {
        components = [major] + (minor.map { [$0] } ?? [])
    }

    public var major: Int { components[0] }
    public var minor: Int { components.count > 1 ? components[1] : 0 }

    public var description: String { components.map(String.init).joined(separator: ".") }

    private var padded: [Int] { components + Array(repeating: 0, count: 3 - components.count) }

    public static func == (lhs: BuildNumber, rhs: BuildNumber) -> Bool { lhs.padded == rhs.padded }

    public func hash(into hasher: inout Hasher) { hasher.combine(padded) }

    public static func < (lhs: BuildNumber, rhs: BuildNumber) -> Bool { lhs.padded.lexicographicallyPrecedes(rhs.padded) }
}

extension StorePlatform {
    /// What `xcodebuild archive` builds for the platform.
    public var archiveDestination: String {
        switch self {
        case .iOS: "generic/platform=iOS"
        case .macOS: "generic/platform=macOS"
        case .tvOS: "generic/platform=tvOS"
        case .visionOS: "generic/platform=visionOS"
        }
    }
}
