public import CoreGraphics
public import CoreImage
public import ProductPageKitFrames

/// How an app's screenshots are framed: the ground, the caption and the
/// device around each capture. Each app implements one in its tools package.
///
/// A frame is redrawn when what it is drawn from, its caption or the tools
/// executable changes, so a theme needs no version of its own.
public protocol FrameTheme: Sendable {
    /// What `frame` is drawn from. The shot's own capture unless a theme
    /// composes it from others: captures from any platform, components the
    /// app exports, and files the project prepares. Whatever is listed here
    /// is captured, and nothing else is.
    func sources(for frame: FrameSubject) -> [FrameSource]
    /// The size `platform`'s screenshots are drawn at, one App Store Connect
    /// takes for its display type. The largest unless a brand's layouts were
    /// made for another.
    func canvasSize(for platform: Platform.Kind) -> CGSize
    /// Draws `shot` on `canvas`, which is `canvasSize(for:)` its platform.
    func render(_ shot: FramedShot, on canvas: Canvas) throws
}

extension FrameTheme {
    public func sources(for frame: FrameSubject) -> [FrameSource] {
        [.capture(frame.shot, on: frame.platform)]
    }

    public func canvasSize(for platform: Platform.Kind) -> CGSize {
        platform.screenshotSize
    }
}

/// A screenshot a theme frames: a shot in a platform's list, in a custom
/// page's, or in an experiment treatment's.
public struct FrameSubject: Hashable, Sendable, CustomStringConvertible {
    public let shot: Shot
    public let platform: Platform.Kind
    /// The list the shot is in, which is how a theme lays out a treatment's
    /// shots differently from the store's.
    public let list: ShotList

    public init(_ shot: Shot, on platform: Platform.Kind, list: ShotList = .store) {
        self.shot = shot
        self.platform = platform
        self.list = list
    }

    /// The custom page's key, for a page's screenshot.
    public var page: String? {
        if case .customPage(let key) = list { key } else { nil }
    }

    /// `the iPhone 6.9" free screenshot of the pro page`.
    public var description: String { "the \(platform.name) \(shot) screenshot\(list.qualifier)" }
}

/// Something a frame is drawn from.
public struct FrameSource: Hashable, Sendable, CustomStringConvertible {
    public enum Content: Hashable, Sendable {
        /// A scene captured on a platform.
        case capture(Shot, Platform.Kind)
        /// A view the app exported on a platform.
        case component(Component, Platform.Kind)
        /// A file the project's `CaptureFiles` prepare, by name.
        case file(String)
    }

    public let content: Content
    /// Read in the primary locale, whatever the frame's: what a theme sizes a
    /// translated component against.
    public let isInPrimaryLocale: Bool

    public static func capture(_ shot: Shot, on platform: Platform.Kind) -> FrameSource {
        FrameSource(content: .capture(shot, platform), isInPrimaryLocale: false)
    }

    public static func component(_ component: Component, on platform: Platform.Kind) -> FrameSource {
        FrameSource(content: .component(component, platform), isInPrimaryLocale: false)
    }

    public static func file(_ name: String) -> FrameSource {
        FrameSource(content: .file(name), isInPrimaryLocale: false)
    }

    /// This source as the primary locale has it. A file is the same in every
    /// locale.
    public func inPrimaryLocale() -> FrameSource {
        guard case .file = content else { return FrameSource(content: content, isInPrimaryLocale: true) }
        return self
    }

    public var description: String {
        let place = isInPrimaryLocale ? ", in the primary locale" : ""
        return switch content {
        case .capture(let shot, let platform): "the \(platform.name) capture of \(shot)\(place)"
        case .component(let component, let platform): "the \(platform.name) component \(component)\(place)"
        case .file(let name): "the file \(name)"
        }
    }
}

/// One screenshot to frame, with everything its theme said it is drawn from.
public struct FramedShot: Sendable {
    public let shot: Shot
    public let list: ShotList
    /// Its place in its list, from 0, and how many the list holds.
    public let position: Int
    public let count: Int
    public let platform: Platform.Kind
    public let locale: StoreLocale
    public let caption: Caption
    private let images: [FrameSource: CGImage]
    private let highlightRects: [FrameSource: [CGRect]]
    private let files: [String: URL]

    /// - Parameters:
    ///   - images: each capture and component source, read.
    ///   - highlights: the views each capture's app marked with
    ///     `.captureHighlight()`, in its pixels from its top left.
    ///   - files: where each file source is.
    public init(shot: Shot, list: ShotList = .store, position: Int, count: Int, platform: Platform.Kind, locale: StoreLocale,
                caption: Caption, images: [FrameSource: CGImage], highlights: [FrameSource: [CGRect]] = [:],
                files: [String: URL] = [:]) {
        self.shot = shot
        self.list = list
        self.position = position
        self.count = count
        self.platform = platform
        self.locale = locale
        self.caption = caption
        self.images = images
        highlightRects = highlights
        self.files = files
    }

    public var subject: FrameSubject { FrameSubject(shot, on: platform, list: list) }

    /// A capture or component the theme listed in `sources(for:)`.
    public func image(_ source: FrameSource) throws -> CGImage {
        guard let image = images[source] else { throw UndeclaredSource(source: source, frame: subject) }
        return image
    }

    /// The highlights of a capture the theme listed, top to bottom.
    public func highlights(_ source: FrameSource) throws -> [CGRect] {
        guard images[source] != nil else { throw UndeclaredSource(source: source, frame: subject) }
        return highlightRects[source] ?? []
    }

    /// Where a file the theme listed is.
    public func file(_ name: String) throws -> URL {
        guard let url = files[name] else { throw UndeclaredSource(source: .file(name), frame: subject) }
        return url
    }

    /// The shot's own capture.
    public var capture: CGImage {
        get throws { try image(.capture(shot, on: platform)) }
    }

    /// The views the shot's own capture marked, top to bottom.
    public var highlights: [CGRect] {
        get throws { try highlights(.capture(shot, on: platform)) }
    }
}

/// A theme read something it did not list in `sources(for:)`, which would
/// neither be captured nor redraw the frame when it changes.
public struct UndeclaredSource: Error, CustomStringConvertible {
    public let source: FrameSource
    public let frame: FrameSubject

    public var description: String {
        "the theme drew \(source) into \(frame) without listing it in sources(for:)"
    }
}

/// The words on a framed screenshot or a video, from the String Catalog.
public struct Caption: Hashable, Sendable {
    public enum Line: String, CaseIterable, Sendable {
        /// A few words above the headline naming the feature.
        case kicker
        case headline
        /// A sentence under the headline.
        case subline
    }

    public var kicker: String?
    public var headline: String
    public var subline: String?

    public init(kicker: String? = nil, headline: String, subline: String? = nil) {
        self.kicker = kicker
        self.headline = headline
        self.subline = subline
    }
}

/// What a caption belongs to.
public enum CaptionSubject: Hashable, Sendable {
    case screenshot(Shot)
    case video(CreativeAsset.Kind)
    /// A screenshot of a custom page, by the page's key.
    case pageScreenshot(String, Shot)
    /// A screenshot of an experiment treatment, by the treatment's key.
    case treatmentScreenshot(String, Shot)

    /// `screenshot.inbox`, `video.header`, `page.pro.screenshot.library`,
    /// `treatment.story.screenshot.library`.
    public var key: String {
        switch self {
        case .screenshot(let shot): "screenshot.\(shot.name)"
        case .video(let kind): "video.\(kind.rawValue)"
        case .pageScreenshot(let page, let shot): "\(CustomPage.keyPrefix(page))screenshot.\(shot.name)"
        case .treatmentScreenshot(let treatment, let shot): "\(Treatment.keyPrefix(treatment))screenshot.\(shot.name)"
        }
    }

    var title: String {
        switch self {
        case .screenshot(let shot): "the \(shot) screenshot"
        case .video(let kind): "the \(kind.title) video"
        case .pageScreenshot(let page, let shot): "the \(shot) screenshot on the \(page) page"
        case .treatmentScreenshot(let treatment, let shot): "the \(shot) screenshot in the \(treatment) treatment"
        }
    }
}

/// How an app's product page header and search result videos move: the
/// assets, their timing, and the stage they play on. The package composes
/// the devices; the stage draws everything behind and over them.
public protocol MotionTheme: Sendable {
    var motion: Motion { get }
    var assets: [CreativeAsset] { get }
    /// What every locale of `asset` shares, drawn once per render.
    func stage(for asset: CreativeAsset) -> any MotionStage
}

/// One asset's stage. Its canvas is `CreativeAsset.Kind.size`.
public protocol MotionStage: Sendable {
    /// The device a layer of `platform` shows its captures in, around
    /// `screen`: the brand's finish and build.
    func device(_ platform: Platform.Kind, screen: CGRect) -> any DeviceLook
    /// The light behind each device, which floats with it, or nil for none.
    var deviceGlow: CGColor? { get }
    /// The light a screen casts around its device, added to what is behind
    /// it and dissolving with the screen, or nil for none.
    func light(from screen: CGImage, of device: any DeviceLook) -> CIImage?
    /// Sets the caption on a transparent canvas, once per locale, and returns
    /// what its text covers. It must sit inside the asset's safe area, clear
    /// of every device, which are mirrored for a right-to-left locale when
    /// the motion says so.
    func drawCaption(_ caption: Caption, on canvas: Canvas, locale: StoreLocale) -> CGRect
    /// The ground at `time`, under a caption and devices placed as `layout`
    /// says.
    func background(at time: Double, layout: VideoLayout) -> CIImage
    /// Everything over the devices at `time`, the caption included.
    func foreground(over image: CIImage, caption: CaptionLayer, layout: VideoLayout, at time: Double) -> CIImage
}

extension MotionStage {
    public func light(from screen: CGImage, of device: any DeviceLook) -> CIImage? { nil }
}

/// Where one video's caption and devices sit, for a ground lit around them.
public struct VideoLayout: Sendable {
    /// What the caption's text covers.
    public let caption: CGRect
    /// What each device's body can reach as it floats, in declaration order.
    public let devices: [CGRect]
    /// The video's locale, whose direction a stage may follow.
    public let locale: StoreLocale

    public init(caption: CGRect, devices: [CGRect], locale: StoreLocale) {
        self.caption = caption
        self.devices = devices
        self.locale = locale
    }
}

/// A caption drawn for a video: the image, and what its text covers.
public struct CaptionLayer: Sendable {
    public let image: CIImage
    public let bounds: CGRect

    public init(image: CIImage, bounds: CGRect) {
        self.image = image
        self.bounds = bounds
    }
}

/// A video's loop.
public struct Motion: Sendable {
    /// How the devices float against each other.
    public enum Floating: Sendable {
        /// Each a share of the loop behind the one before, so the set
        /// never moves as one.
        case staggered
        /// All at once, from rest at the start of the loop.
        case inStep
    }

    public var seconds: Double
    /// 30 or 60, which App Store Connect takes.
    public var fps: Int
    /// How long one screen takes to dissolve into the next.
    public var dissolve: Double
    public var floating: Floating
    /// Whether a right-to-left locale's video places its devices mirrored,
    /// as the store mirrors its page.
    public var mirrorsRightToLeft: Bool

    public init(seconds: Double, fps: Int, dissolve: Double, floating: Floating = .staggered, mirrorsRightToLeft: Bool = false) {
        self.seconds = seconds
        self.fps = fps
        self.dissolve = dissolve
        self.floating = floating
        self.mirrorsRightToLeft = mirrorsRightToLeft
    }

    /// Where in the loop device `index` of `count` starts its float, in
    /// radians.
    public func floatPhase(_ index: Int, of count: Int) -> Double {
        switch floating {
        case .staggered: 2 * .pi * Double(index) / Double(count)
        case .inStep: 0
        }
    }

    public var frames: Int { Int((seconds * Double(fps)).rounded()) }

    public static let frameRates = [30, 60]
}

/// A product page header or search result video: the poster frame and the
/// devices on it.
public struct CreativeAsset: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case header
        case search

        public var placementType: String {
            switch self {
            case .header: "PRODUCT_PAGE_HEADER_ASSET"
            case .search: "APP_STORE_SEARCH_RESULTS_ASSET"
            }
        }

        public var title: String {
            switch self {
            case .header: "product page header"
            case .search: "search results"
            }
        }

        /// The canvas App Store Connect takes.
        public var size: CGSize {
            switch self {
            case .header: CGSize(width: 3840, height: 1646)
            case .search: CGSize(width: 3840, height: 2560)
            }
        }

        /// What survives every crop the App Store makes, from Apple's
        /// templates, in Core Graphics coordinates (origin bottom left).
        public var safeArea: CGRect {
            switch self {
            case .header: CGRect(x: 1097, y: 1646 - 493 - 661, width: 1646, height: 661)
            case .search: CGRect(x: 836, y: 2560 - 765 - 1030, width: 2168, height: 1030)
            }
        }
    }

    public var kind: Kind
    /// The frame App Store Connect shows before the loop plays, in seconds.
    public var poster: Double
    public var devices: [DeviceLayer]

    public init(_ kind: Kind, poster: Double, devices: [DeviceLayer]) {
        self.kind = kind
        self.poster = poster
        self.devices = devices
    }

    public var size: CGSize { kind.size }
}

/// What a device in a video shows for its share of the loop.
public enum VideoScreen: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// A scene captured on the device's platform.
    case capture(Shot)
    /// A movie, one of the files the project's `CaptureFiles` prepare,
    /// playing from this many seconds in for as long as it is in view,
    /// letterboxed on black.
    case movie(String, from: Double)

    public init(stringLiteral scene: String) {
        self = .capture(Shot(scene))
    }

    public var description: String {
        switch self {
        case .capture(let shot): "\(shot)"
        case .movie(let name, let start): "\(name) from \(start) s"
        }
    }
}

/// A device in a video, showing screens in turn.
public struct DeviceLayer: Sendable {
    public var platform: Platform.Kind
    /// Each shown for an equal share of the loop.
    public var screens: [VideoScreen]
    /// The screen's left edge, top edge and width, in fractions of the canvas
    /// from its top left.
    public var x: CGFloat
    public var top: CGFloat
    public var width: CGFloat
    /// When the first screen has finished dissolving into the second, in
    /// seconds. Each later change follows an equal share of the loop on.
    public var firstChange: Double
    /// How far the device floats each way, in fractions of the canvas:
    /// rightwards and downwards.
    public var drift: CGVector

    public init(_ platform: Platform.Kind, screens: [VideoScreen], x: CGFloat, top: CGFloat, width: CGFloat, firstChange: Double,
                drift: CGVector) {
        self.platform = platform
        self.screens = screens
        self.x = x
        self.top = top
        self.width = width
        self.firstChange = firstChange
        self.drift = drift
    }

    public func schedule(_ motion: Motion) -> ScreenSchedule {
        ScreenSchedule(screens: screens.count, firstChange: firstChange, loop: motion.seconds, dissolve: motion.dissolve)
    }

    /// The scenes it shows.
    public var captures: [Shot] {
        screens.compactMap { if case .capture(let shot) = $0 { shot } else { nil } }
    }
}

extension MotionTheme {
    /// Problems with the declarations, before anything is captured.
    func problems(platforms: [Platform], files: Set<String>) -> [String] {
        var problems: [String] = []
        if !Motion.frameRates.contains(motion.fps) {
            problems.append("videos run at \(motion.fps) fps, and App Store Connect takes \(Motion.frameRates.map(String.init).joined(separator: " or "))")
        }
        if motion.seconds <= 0 || motion.dissolve < 0 { problems.append("videos need a positive length and dissolve") }
        let kinds = assets.map(\.kind)
        for kind in kinds.repeated {
            problems.append("the \(kind.title) video is declared twice")
        }
        for asset in assets {
            let name = "the \(asset.kind.title) video"
            if asset.poster < 0 || asset.poster >= motion.seconds {
                problems.append("\(name)'s poster at \(asset.poster) s is outside its \(motion.seconds) s loop")
            }
            if asset.devices.isEmpty { problems.append("\(name) has no devices") }
            for (index, layer) in asset.devices.enumerated() {
                let device = "\(name), device \(index + 1)"
                if !platforms.contains(where: { $0.kind == layer.platform }) {
                    problems.append("\(device) is a \(layer.platform.name), which is not a configured platform")
                }
                if layer.screens.isEmpty { problems.append("\(device) shows no screens") }
                if layer.captures.isEmpty { problems.append("\(device) shows no capture to size its screen by") }
                if layer.width <= 0 { problems.append("\(device) has no width") }
                let schedule = layer.schedule(motion)
                if schedule.state(at: asset.poster).mix > 0 {
                    problems.append("\(name)'s poster frame catches device \(index + 1) mid-dissolve")
                }
                for (position, screen) in layer.screens.enumerated() {
                    guard case .movie(let file, _) = screen else { continue }
                    if !files.contains(file) {
                        problems.append("\(device) plays \(file), which the project's capture files do not include")
                    }
                    let window = schedule.window(of: position)
                    if window.lowerBound < 0 || window.upperBound > motion.seconds {
                        problems.append("\(device) plays \(file) across the loop's seam, where the movie would jump")
                    }
                }
            }
        }
        return problems
    }
}
