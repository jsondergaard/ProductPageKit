public import CoreGraphics
public import CoreImage

extension CIImage {
    /// Draws once into a bitmap covering `rect` of a canvas, in the canvas's
    /// own coordinates, and returns it placed where it was drawn. A layer that
    /// does not change is drawn this way once and composited every frame.
    public static func drawn(in rect: CGRect, _ draw: (CGContext) -> Void) -> CIImage {
        let bounds = rect.integral
        let context = Canvas.bitmap(width: Int(bounds.width), height: Int(bounds.height))
        context.interpolationQuality = .high
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(context)
        return CIImage(cgImage: context.makeImage()!).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    /// This image at `alpha` times its opacity.
    public func faded(_ alpha: Double) -> CIImage {
        alpha >= 1 ? self : applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }

    /// This image's light added to `background`, as `.plusLighter` adds it.
    public func lighting(_ background: CIImage) -> CIImage {
        applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: background])
    }

    /// This image wherever `mask` is opaque, clear elsewhere.
    public func masked(by mask: CIImage) -> CIImage {
        applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
    }
}

/// A soft band of white light across the line `direction` points along,
/// `halfWidth` either side of `center`: opaque at the centre, gone at its
/// edges, with `strength(at:)`'s profile.
public struct LightBand: Sendable {
    public let center: CGPoint
    public let direction: CGVector
    public let halfWidth: CGFloat

    public init(center: CGPoint, direction: CGVector, halfWidth: CGFloat) {
        self.center = center
        self.direction = direction
        self.halfWidth = halfWidth
    }

    public var image: CIImage {
        func ramp(from: CGFloat, to: CGFloat) -> CIImage {
            CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x + direction.dx * from, y: center.y + direction.dy * from),
                "inputPoint1": CIVector(x: center.x + direction.dx * to, y: center.y + direction.dy * to),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            ])!.outputImage!
        }
        return ramp(from: -halfWidth, to: 0).applyingFilter("CIMinimumCompositing", parameters: [
            kCIInputBackgroundImageKey: ramp(from: halfWidth, to: 0),
        ])
    }

    /// How strongly a band `halfWidth` either side of its centre lights a
    /// point `distance` from it.
    public static func strength(distance: CGFloat, halfWidth: CGFloat) -> CGFloat {
        let x = max(0, 1 - abs(distance) / halfWidth)
        return x * x * (3 - 2 * x)
    }
}

/// A seeded generator, so every render scatters the same things.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next(_ range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return range.lowerBound + Double(state >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
