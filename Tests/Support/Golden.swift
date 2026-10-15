public import CoreGraphics
import Foundation
import ImageIO
public import Testing
import UniformTypeIdentifiers

/// Compares a drawing with the image recorded in a `Golden/` folder beside
/// the test that calls it. `PRODUCTPAGE_RECORD_GOLDEN=1 swift test` records
/// them again, after a deliberate change to how something draws.
public enum Golden {
    /// Fails when more than `tolerance` of the channels differ by more than a
    /// few levels, which leaves room for font rendering between OS versions.
    /// Both are compared at most `width` pixels wide, which keeps the
    /// recorded files small.
    public static func check(_ image: CGImage, named name: String, tolerance: Double = 0.002, width: Int = 480,
                             filePath: String = #filePath, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let image = scaled(image, toWidth: width)
        let directory = URL(filePath: filePath).deletingLastPathComponent().appending(path: "Golden")
        let url = directory.appending(path: "\(name).png")
        if ProcessInfo.processInfo.environment["PRODUCTPAGE_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination), sourceLocation: sourceLocation)
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let golden = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("No golden image \(name).png. Record it with PRODUCTPAGE_RECORD_GOLDEN=1.", sourceLocation: sourceLocation)
            return
        }
        #expect(golden.width == image.width && golden.height == image.height, "\(name) changed size", sourceLocation: sourceLocation)
        guard golden.width == image.width, golden.height == image.height else { return }
        let (a, b) = (pixels(golden), pixels(image))
        let differing = zip(a, b).filter { abs(Int($0) - Int($1)) > 3 }.count
        let fraction = Double(differing) / Double(a.count)
        #expect(fraction <= tolerance, "\(name): \(String(format: "%.3f", fraction * 100))% of channels differ", sourceLocation: sourceLocation)
    }

    static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage {
        guard image.width > width else { return image }
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    public static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
