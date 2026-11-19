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

    /// The platform's name on the command line and in file names: `ios`,
    /// `macos`.
    public var key: String { rawValue.lowercased().replacingOccurrences(of: "_", with: "") }
}

/// A device the product page shows screenshots for, or a graphic a store
/// lists beside them, the scenes captured on it in store order, and where
/// they are captured.
public struct Platform: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case iPhone = "ios"
        case iPad = "ipad"
        /// The foldable iPhone, opened flat and captured on its inner
        /// display, which is landscape.
        case iPhoneDuo = "duo"
        case mac = "macos"
        case appleTV = "tvos"
        case androidPhone = "android"
        case androidTablet7 = "android7"
        case androidTablet10 = "android10"
        case androidTV = "androidtv"
        case wear = "wear"
        /// Google Play's 1024 × 500 banner across the top of the listing.
        case featureGraphic = "feature"
        /// The 1280 × 720 tile Android TV's home screen shows.
        case tvBanner = "tvbanner"

        public var name: String {
            switch self {
            case .iPhone: "iPhone 6.9\""
            case .iPad: "iPad 13\""
            case .iPhoneDuo: "iPhone Duo"
            case .mac: "Mac"
            case .appleTV: "Apple TV"
            case .androidPhone: "Android phone"
            case .androidTablet7: "Android 7\" tablet"
            case .androidTablet10: "Android 10\" tablet"
            case .androidTV: "Android TV"
            case .wear: "Wear OS"
            case .featureGraphic: "feature graphic"
            case .tvBanner: "TV banner"
            }
        }

        public var store: Store {
            switch self {
            case .iPhone, .iPad, .iPhoneDuo, .mac, .appleTV: .appStore
            default: .googlePlay
            }
        }

        /// The App Store version its screenshots go on, or nil for Google Play.
        public var storePlatform: StorePlatform? {
            switch self {
            case .iPhone, .iPad, .iPhoneDuo: .iOS
            case .mac: .macOS
            case .appleTV: .tvOS
            default: nil
            }
        }

        /// The screenshot set App Store Connect files the screenshots under,
        /// or nil for Google Play.
        /// iPhone is 6.9": the API tops out at `APP_IPHONE_67`, which is the
        /// slot App Store Connect labels "6.9-inch Display" and which takes
        /// 1320 × 2868. iPhone Duo's is missing from Apple's OpenAPI
        /// document; the API takes `APP_IPHONE_DUO`, for both displays.
        public var displayType: String? {
            switch self {
            case .iPhone: "APP_IPHONE_67"
            case .iPad: "APP_IPAD_PRO_3GEN_129"
            case .iPhoneDuo: "APP_IPHONE_DUO"
            case .mac: "APP_DESKTOP"
            case .appleTV: "APP_APPLE_TV"
            default: nil
            }
        }

        /// The Google Play listing's image slot, or nil for the App Store.
        public var playImageType: PlayImageType? {
            switch self {
            case .androidPhone: .phoneScreenshots
            case .androidTablet7: .sevenInchScreenshots
            case .androidTablet10: .tenInchScreenshots
            case .androidTV: .tvScreenshots
            case .wear: .wearScreenshots
            case .featureGraphic: .featureGraphic
            case .tvBanner: .tvBanner
            default: nil
            }
        }

        /// The canvas a theme frames on: for the App Store the largest size
        /// the display type takes, which App Store Connect scales the
        /// smaller devices from; for Google Play its slot's `canvas`.
        public var screenshotSize: CGSize { playImageType?.canvas ?? appStoreSizes[0] }

        /// Whether the store takes a screenshot of `size` for this platform.
        public func accepts(_ size: CGSize) -> Bool {
            playImageType?.accepts(size) ?? appStoreSizes.contains(size)
        }

        /// Every size an App Store display type takes, portrait and
        /// landscape.
        var appStoreSizes: [CGSize] {
            let sizes: [CGSize] = switch self {
            case .iPhone: [CGSize(width: 1320, height: 2868), CGSize(width: 1290, height: 2796), CGSize(width: 1260, height: 2736)]
            case .iPad: [CGSize(width: 2064, height: 2752), CGSize(width: 2048, height: 2732)]
            // The inner display, then the outer.
            case .iPhoneDuo: [CGSize(width: 2853, height: 2007), CGSize(width: 2034, height: 1398)]
            case .mac: [CGSize(width: 2880, height: 1800), CGSize(width: 2560, height: 1600), CGSize(width: 1440, height: 900),
                        CGSize(width: 1280, height: 800)]
            case .appleTV: [CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080)]
            default: []
            }
            return switch self {
            case .iPhone, .iPad, .iPhoneDuo: sizes + sizes.map { CGSize(width: $0.height, height: $0.width) }
            default: sizes
            }
        }

        /// Screenshots its store takes per set.
        public var maximumShots: Int { playImageType?.maximumImages ?? Self.appStoreShots }

        /// Screenshots an App Store set takes, a custom page's and a
        /// treatment's too.
        public static let appStoreShots = 10

        /// The device drawn around its captures, or nil for a graphic, which
        /// shows no device of its own.
        public var bezel: DeviceBezel.Model? {
            switch self {
            case .iPhone: .iPhone
            case .iPad: .iPad
            case .iPhoneDuo: .iPhoneDuo
            case .mac: .mac
            case .appleTV: .appleTV
            case .androidPhone: .androidPhone
            case .androidTablet7, .androidTablet10: .androidTablet
            case .androidTV: .androidTV
            case .wear: .wear
            case .featureGraphic, .tvBanner: nil
            }
        }
    }

    public enum Capture: Sendable {
        case simulator(SimulatorDevice)
        /// The Mac app's window, at this content size in points.
        case window(CGSize?)
        /// An Android emulator or device, driven over adb, running `app`, or
        /// `Project.android` when it is nil.
        case android(AndroidDevice, app: AndroidApp?)
        /// Nothing: a graphic a theme draws from other platforms' captures.
        case drawn
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

    public static func iPhoneDuo(device: SimulatorDevice = .largest, shots: [Shot] = []) -> Platform {
        Platform(kind: .iPhoneDuo, shots: shots, capture: .simulator(device))
    }

    public static func appleTV(device: SimulatorDevice = .largest, shots: [Shot] = []) -> Platform {
        Platform(kind: .appleTV, shots: shots, capture: .simulator(device))
    }

    /// - Parameter window: the window's content size, in points. A Mac
    ///   captures at twice that in pixels.
    public static func mac(window: CGSize? = nil, shots: [Shot] = []) -> Platform {
        Platform(kind: .mac, shots: shots, capture: .window(window))
    }

    public static func androidPhone(_ device: AndroidDevice, shots: [Shot] = [], app: AndroidApp? = nil) -> Platform {
        Platform(kind: .androidPhone, shots: shots, capture: .android(device, app: app))
    }

    public static func androidTablet7(_ device: AndroidDevice, shots: [Shot] = [], app: AndroidApp? = nil) -> Platform {
        Platform(kind: .androidTablet7, shots: shots, capture: .android(device, app: app))
    }

    public static func androidTablet10(_ device: AndroidDevice, shots: [Shot] = [], app: AndroidApp? = nil) -> Platform {
        Platform(kind: .androidTablet10, shots: shots, capture: .android(device, app: app))
    }

    public static func androidTV(_ device: AndroidDevice, shots: [Shot] = [], app: AndroidApp? = nil) -> Platform {
        Platform(kind: .androidTV, shots: shots, capture: .android(device, app: app))
    }

    public static func wear(_ device: AndroidDevice, shots: [Shot] = [], app: AndroidApp? = nil) -> Platform {
        Platform(kind: .wear, shots: shots, capture: .android(device, app: app))
    }

    /// Google Play's feature graphic, which the theme draws as `shot` from
    /// what its `sources(for:)` lists.
    public static func featureGraphic(_ shot: Shot = "featureGraphic") -> Platform {
        Platform(kind: .featureGraphic, shots: [shot], capture: .drawn)
    }

    /// Android TV's banner, which the theme draws as `shot` from what its
    /// `sources(for:)` lists.
    public static func tvBanner(_ shot: Shot = "tvBanner") -> Platform {
        Platform(kind: .tvBanner, shots: [shot], capture: .drawn)
    }

    /// The folder its screenshots live in, and its name on the command line.
    public var id: String { kind.rawValue }
    public var name: String { kind.name }
    public var storePlatform: StorePlatform? { kind.storePlatform }
    public var store: Store { kind.store }

    func problems() -> [String] {
        var problems = shotProblems(owner: name, limit: kind.maximumShots, store: kind.store)
        if case .window(let size) = capture, !shots.isEmpty {
            if let size {
                if size.width <= 0 || size.height <= 0 { problems.append("\(name) has an empty window size") }
            } else {
                problems.append("\(name) has shots and no window size")
            }
        }
        if case .android(let device, _) = capture, device.name.isEmpty {
            problems.append("\(name) names no Android emulator or device")
        }
        return problems
    }
}

/// The Android emulator or device a platform is captured on.
public enum AndroidDevice: Hashable, Sendable, CustomStringConvertible {
    /// An Android Virtual Device by name, booted for the run when it is not
    /// running already.
    case emulator(String)
    /// A device or running emulator by its adb serial.
    case device(String)

    public var name: String {
        switch self {
        case .emulator(let name), .device(let name): name
        }
    }

    public var description: String {
        switch self {
        case .emulator(let name): "the emulator \(name)"
        case .device(let serial): "the device \(serial)"
        }
    }
}

extension Platform.Capture: CustomStringConvertible {
    public var description: String {
        switch self {
        case .simulator: "on a simulator"
        case .window: "in a Mac window"
        case .android(let device, _): "on \(device)"
        case .drawn: "by a theme alone"
        }
    }
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
