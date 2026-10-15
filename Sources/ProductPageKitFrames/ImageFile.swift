public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The file format framed screenshots are written in. App Store Connect takes
/// both.
public enum ImageFormat: Hashable, Sendable {
    case png
    /// `quality` from 0 to 1.
    case jpeg(quality: Double)

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    /// Names the format and its settings, for cache keys.
    public var identifier: String {
        switch self {
        case .png: "png"
        case .jpeg(let quality): "jpeg-\(quality)"
        }
    }

    public func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let type: UTType = self == .png ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageError.unwritable
        }
        var properties: [CFString: Any] = [:]
        if case .jpeg(let quality) = self { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.unwritable }
        return data as Data
    }
}

public enum ImageError: Error, CustomStringConvertible {
    case unreadable(URL)
    case unwritable

    public var description: String {
        switch self {
        case .unreadable(let url): "\(url.path) is not an image"
        case .unwritable: "the image could not be encoded"
        }
    }
}

extension CGImage {
    /// The first image in the file at `url`.
    public static func read(from url: URL) throws -> CGImage {
        try read(Data(contentsOf: url), from: url)
    }

    /// The first image in `data`, which was read from `url`.
    public static func read(_ data: Data, from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageError.unreadable(url) }
        return image
    }

    public var size: CGSize { CGSize(width: width, height: height) }
}
