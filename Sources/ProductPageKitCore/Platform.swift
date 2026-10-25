public import CoreGraphics
public import ProductPageKitFrames

/// An App Store Connect platform: the one an `appStoreVersion` belongs to.
public enum StorePlatform: String, CaseIterable, Sendable {
    case iOS = "IOS"
    case macOS = "MAC_OS"
    case tvOS = "TV_OS"
    case visionOS = "VISION_OS"

    public var name: String {
        switch self {
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .tvOS: "tvOS"
        case .visionOS: "visionOS"
        }
    }
}

/// A device the product page shows screenshots for, the scenes captured on it
/// in store order, and where they are captured.
public struct Platform: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case iPhone = "ios"
        case iPad = "ipad"
        case mac = "macos"
        case appleTV = "tvos"

        public var name: String {
            switch self {
            case .iPhone: "iPhone 6.9\""
            case .iPad: "iPad 13\""
            case .mac: "Mac"
            case .appleTV: "Apple TV"
            }
        }

        public var storePlatform: StorePlatform {
            switch self {
            case .iPhone, .iPad: .iOS
            case .mac: .macOS
            case .appleTV: .tvOS
            }
        }

        /// The screenshot set App Store Connect files the screenshots under.
        /// iPhone is 6.9": the API tops out at `APP_IPHONE_67`, which is the
        /// slot App Store Connect labels "6.9-inch Display" and which takes
        /// 1320 × 2868.
        public var displayType: String {
            switch self {
            case .iPhone: "APP_IPHONE_67"
            case .iPad: "APP_IPAD_PRO_3GEN_129"
            case .mac: "APP_DESKTOP"
            case .appleTV: "APP_APPLE_TV"
            }
        }

        /// The canvas a theme frames on: the largest size the display type
        /// takes, which App Store Connect scales the smaller devices from.
        public var screenshotSize: CGSize { acceptedSizes[0] }

        /// Every size the display type takes, portrait and landscape.
        public var acceptedSizes: [CGSize] {
            let sizes: [CGSize] = switch self {
            case .iPhone: [CGSize(width: 1320, height: 2868), CGSize(width: 1290, height: 2796), CGSize(width: 1260, height: 2736)]
            case .iPad: [CGSize(width: 2064, height: 2752), CGSize(width: 2048, height: 2732)]
            case .mac: [CGSize(width: 2880, height: 1800), CGSize(width: 2560, height: 1600), CGSize(width: 1440, height: 900),
                        CGSize(width: 1280, height: 800)]
            case .appleTV: [CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080)]
            }
            return switch self {
            case .iPhone, .iPad: sizes + sizes.map { CGSize(width: $0.height, height: $0.width) }
            case .mac, .appleTV: sizes
            }
        }

        public var bezel: DeviceBezel.Model {
            switch self {
            case .iPhone: .iPhone
            case .iPad: .iPad
            case .mac: .mac
            case .appleTV: .appleTV
            }
        }
    }

    public enum Capture: Sendable {
        case simulator(SimulatorDevice)
        /// The Mac app's window, at this content size in points.
        case window(CGSize?)
    }

    public let kind: Kind
    public var shots: [Shot]
    public let capture: Capture

    public static func iPhone(device: SimulatorDevice = .largest, shots: [Shot] = []) -> Platform {
        Platform(kind: .iPhone, shots: shots, capture: .simulator(device))
    }

    public static func iPad(device: SimulatorDevice = .largest, shots: [Shot] = []) -> Platform {
        Platform(kind: .iPad, shots: shots, capture: .simulator(device))
    }

    public static func appleTV(device: SimulatorDevice = .largest, shots: [Shot] = []) -> Platform {
        Platform(kind: .appleTV, shots: shots, capture: .simulator(device))
    }

    /// - Parameter window: the window's content size, in points. A Mac
    ///   captures at twice that in pixels.
    public static func mac(window: CGSize? = nil, shots: [Shot] = []) -> Platform {
        Platform(kind: .mac, shots: shots, capture: .window(window))
    }

    /// The folder its screenshots live in, and its name on the command line.
    public var id: String { kind.rawValue }
    public var name: String { kind.name }
    public var storePlatform: StorePlatform { kind.storePlatform }
    public var displayType: String { kind.displayType }

    func problems() -> [String] {
        var problems = shotProblems(owner: name)
        if case .window(let size) = capture, !shots.isEmpty {
            if let size {
                if size.width <= 0 || size.height <= 0 { problems.append("\(name) has an empty window size") }
            } else {
                problems.append("\(name) has shots and no window size")
            }
        }
        return problems
    }

    /// Screenshots per set.
    public static let maximumShots = 10
}

/// The simulator a platform is captured on.
public enum SimulatorDevice: Hashable, Sendable {
    /// The largest screen in the newest runtime: the size App Store Connect
    /// shows, which every smaller one is scaled from.
    case largest
    /// A device type by name, such as "iPhone 18 Pro Max".
    case named(String)
}

/// A scene to capture, and the variant it is shown with. A string literal is a
/// scene without a variant.
public struct Shot: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let scene: String
    public let variant: String?

    public init(_ scene: String, variant: String? = nil) {
        self.scene = scene
        self.variant = variant
    }

    public init(stringLiteral scene: String) {
        self.init(scene)
    }

    /// `library-pro` for a variant, the scene alone otherwise.
    public var name: String { variant.map { "\(scene)-\($0)" } ?? scene }

    public var description: String { variant.map { "\(scene) (\($0))" } ?? scene }
}
