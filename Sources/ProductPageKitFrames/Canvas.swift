public import CoreGraphics

/// A transparent sRGB bitmap at an exact pixel size, which a frame is drawn
/// into with Core Graphics.
///
/// Core Graphics puts the origin at the bottom left. Layouts are written from
/// the top left in fractions of the canvas, so `point(x:top:)` converts.
public final class Canvas {
    public let size: CGSize
    public let context: CGContext

    public init(size: CGSize) {
        self.size = size
        context = Canvas.bitmap(width: Int(size.width), height: Int(size.height))
        context.interpolationQuality = .high
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }
    public var shortSide: CGFloat { min(size.width, size.height) }

    /// The point `x` of the width across and `top` of the height down.
    public func point(x: CGFloat, top: CGFloat) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * (1 - top))
    }

    public func image() -> CGImage {
        context.makeImage()!
    }

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    }
}

extension CGColor {
    /// An sRGB colour from `0xRRGGBB`.
    public static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// This colour at `alpha` times its own opacity.
    public func faded(_ alpha: CGFloat) -> CGColor {
        copy(alpha: self.alpha * alpha)!
    }
}
