public import CoreGraphics

/// A tile of monochrome noise, drawn over a whole frame at low opacity.
///
/// Flat colour is what makes a rendered screenshot look like a slide template;
/// grain makes the frame read as one printed surface. The noise is seeded, so
/// two renders of one frame are byte-identical.
public struct Grain: Sendable {
    public let tile: CGImage

    public init(seed: UInt64 = 0xACC1_7100, size: Int = 192) {
        var state = seed
        // xorshift64*: no system randomness, so the output is stable.
        func next() -> UInt8 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 33)
        }
        // Centred on mid-grey and shallow.
        var pixels = (0..<size * size).map { _ in UInt8(112 + Int(next()) % 32) }
        tile = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        }
    }

    /// Overlays the grain on everything drawn so far.
    public func draw(in context: CGContext, opacity: CGFloat = 0.06) {
        context.saveGState()
        context.setBlendMode(.overlay)
        context.setAlpha(opacity)
        context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
        context.restoreGState()
    }
}

/// A soft circular wash of `color`, strongest at `center` and gone at
/// `radius`. One, large, behind a device lifts it off a dark ground without
/// a drawn edge.
public func drawGlow(in context: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, opacity: CGFloat) {
    let gradient = CGGradient(colorsSpace: Canvas.colorSpace, colors: [color.faded(opacity), color.faded(0)] as CFArray,
                              locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: [])
}

/// A vertical gradient filling `rect`, `top` at its top edge.
public func drawGradient(in context: CGContext, rect: CGRect, top: CGColor, bottom: CGColor) {
    let gradient = CGGradient(colorsSpace: Canvas.colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.clip(to: rect)
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.minX, y: rect.minY),
                               options: [])
    context.restoreGState()
}
