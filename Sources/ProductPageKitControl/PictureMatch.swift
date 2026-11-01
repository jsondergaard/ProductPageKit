#if DEBUG
public import CoreGraphics
import Foundation

/// Whether two drawings show the same picture, by one measure for the runner
/// photographing a scene and the app drawing a component: a channel that
/// moved by no more than `channelThreshold` is the same colour, which glass
/// re-sampling its backdrop never exceeds, and at most `tolerance` of the
/// pixels may differ beyond that.
public struct PictureMatch: Sendable {
    /// The share of pixels that may differ: a caret's blink passes, a
    /// spinner does not.
    public var tolerance: Double
    /// A channel difference at or below this is the same colour.
    public var channelThreshold: UInt8

    public init(tolerance: Double = 0.0002, channelThreshold: UInt8 = 2) {
        self.tolerance = tolerance
        self.channelThreshold = channelThreshold
    }

    public func sameColour(_ a: UInt8, _ b: UInt8) -> Bool {
        (a > b ? a - b : b - a) <= channelThreshold
    }

    /// - Parameter moving: what moves on purpose, as fractions of the picture
    ///   from its top left, which is left out of the comparison.
    public func matches(_ a: CGImage, _ b: CGImage, ignoring moving: [CGRect] = []) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let first = a.rgbaPixels, let second = b.rgbaPixels
        else { return false }
        let width = CGFloat(a.width), height = CGFloat(a.height)
        let ignored = moving.map { CGRect(x: $0.minX * width, y: $0.minY * height, width: $0.width * width, height: $0.height * height).integral }
        let allowed = Int(Double(a.width * a.height) * tolerance)
        let rowBytes = a.width * 4
        var differing = 0
        first.withUnsafeBufferPointer { lhs in
            second.withUnsafeBufferPointer { rhs in
                for row in 0..<a.height {
                    let start = row * rowBytes
                    // Rows are compared whole first; only a row that differs
                    // is looked at pixel by pixel.
                    guard memcmp(lhs.baseAddress! + start, rhs.baseAddress! + start, rowBytes) != 0 else { continue }
                    let skipped = ignored.filter { CGFloat(row) >= $0.minY && CGFloat(row) < $0.maxY }
                    for pixel in stride(from: start, to: start + rowBytes, by: 4)
                    where (0..<4).contains(where: { !sameColour(lhs[pixel + $0], rhs[pixel + $0]) }) {
                        let column = CGFloat((pixel - start) / 4)
                        if skipped.contains(where: { column >= $0.minX && column < $0.maxX }) { continue }
                        differing += 1
                        if differing > allowed { return }
                    }
                }
            }
        }
        return differing <= allowed
    }
}

extension CGImage {
    /// Premultiplied sRGB RGBA, eight bits a channel, whatever the image's own
    /// layout.
    public var rgbaPixels: [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
#endif
