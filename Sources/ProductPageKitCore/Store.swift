public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A store the product page is published to.
public enum Store: String, CaseIterable, Sendable {
    case appStore
    case googlePlay

    /// Who enforces its rules, as problems name it.
    public var name: String {
        switch self {
        case .appStore: "App Store Connect"
        case .googlePlay: "Google Play"
        }
    }
}

/// An image slot of a Google Play listing, by the Publishing API's name for
/// it: each is a list per language, shown in upload order.
public enum PlayImageType: String, CaseIterable, Sendable {
    case phoneScreenshots
    case sevenInchScreenshots
    case tenInchScreenshots
    case tvScreenshots
    case wearScreenshots
    case featureGraphic
    case tvBanner

    /// Images the slot holds.
    public var maximumImages: Int {
        switch self {
        case .featureGraphic, .tvBanner: 1
        default: 8
        }
    }

    /// The largest file Google Play takes, or nil where its help names none.
    public var maximumBytes: Int? {
        switch self {
        case .featureGraphic, .tvBanner: nil
        default: 8 << 20
        }
    }

    /// The size a theme draws it at unless it says otherwise.
    public var canvas: CGSize {
        switch self {
        case .phoneScreenshots: CGSize(width: 1080, height: 1920)
        case .sevenInchScreenshots: CGSize(width: 1920, height: 1080)
        case .tenInchScreenshots: CGSize(width: 2560, height: 1440)
        case .tvScreenshots: CGSize(width: 1920, height: 1080)
        case .wearScreenshots: CGSize(width: 454, height: 454)
        case .featureGraphic: CGSize(width: 1024, height: 500)
        case .tvBanner: CGSize(width: 1280, height: 720)
        }
    }

    /// Whether Google Play takes an image of `size` in this slot. Phone and
    /// tablet screenshots are 16:9 or 9:16 with each side 320 to 3840
    /// pixels; Wear's are square, 384 to 3840; TV screenshots are 1920 × 1080
    /// or 3840 × 2160; the feature graphic is 1024 × 500 and the TV banner
    /// 1280 × 720.
    public func accepts(_ size: CGSize) -> Bool {
        let width = Int(size.width), height = Int(size.height)
        guard CGFloat(width) == size.width, CGFloat(height) == size.height else { return false }
        switch self {
        case .phoneScreenshots, .sevenInchScreenshots, .tenInchScreenshots:
            return (320...3840).contains(width) && (320...3840).contains(height)
                && (width * 9 == height * 16 || width * 16 == height * 9)
        case .wearScreenshots:
            return width == height && (384...3840).contains(width)
        case .tvScreenshots:
            return (width, height) == (1920, 1080) || (width, height) == (3840, 2160)
        case .featureGraphic:
            return (width, height) == (1024, 500)
        case .tvBanner:
            return (width, height) == (1280, 720)
        }
    }

    /// The sizes `accepts` takes, as a problem quotes them.
    public var sizeRule: String {
        switch self {
        case .phoneScreenshots, .sevenInchScreenshots, .tenInchScreenshots: "16:9 or 9:16, each side 320 to 3840 pixels"
        case .wearScreenshots: "square, 384 to 3840 pixels a side"
        case .tvScreenshots: "1920 × 1080 or 3840 × 2160"
        case .featureGraphic: "1024 × 500"
        case .tvBanner: "1280 × 720"
        }
    }

    /// Why Google Play would refuse `image` in this slot, or nothing. It
    /// takes PNG without alpha or JPEG, at a size `accepts`, and no larger
    /// than `maximumBytes`.
    public func problems(_ image: ImageFacts) -> [String] {
        var problems: [String] = []
        switch image.format {
        case .png where image.hasAlpha:
            problems.append("is a PNG with an alpha channel, and Google Play takes 24-bit PNG without one")
        case .png, .jpeg:
            break
        case .other:
            problems.append("is neither PNG nor JPEG")
        }
        if !accepts(image.size) {
            problems.append("is \(Int(image.size.width)) × \(Int(image.size.height)), and Google Play takes \(sizeRule)")
        }
        if let maximumBytes, image.bytes > maximumBytes {
            problems.append("is \(image.bytes >> 20) MB, and Google Play takes up to \(maximumBytes >> 20) MB")
        }
        return problems
    }
}

/// What a store's rules read of an image file, without decoding its pixels.
public struct ImageFacts: Equatable, Sendable {
    public enum Format: Sendable {
        case png, jpeg, other
    }

    public let size: CGSize
    public let hasAlpha: Bool
    public let format: Format
    public let bytes: Int

    public init(size: CGSize, hasAlpha: Bool, format: Format, bytes: Int) {
        self.size = size
        self.hasAlpha = hasAlpha
        self.format = format
        self.bytes = bytes
    }

    /// The facts of the image in `data`, or nil when it is not one.
    public init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let type = CGImageSourceGetType(source).map { $0 as String }
        format = switch type {
        case UTType.png.identifier: .png
        case UTType.jpeg.identifier: .jpeg
        default: .other
        }
        size = CGSize(width: width, height: height)
        hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        bytes = data.count
    }
}
