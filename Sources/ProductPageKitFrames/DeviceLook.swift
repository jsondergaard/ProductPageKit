public import CoreGraphics

/// How a device is drawn around what its screen shows, in three passes,
/// body, screen and glass, so a video can dissolve one screen into the next
/// between the body and what lies over the glass. `DeviceBezel` is the
/// package's; a brand with its own build draws its own.
public protocol DeviceLook: Sendable {
    /// Where the screen's content is drawn.
    var screen: CGRect { get }
    /// The body's outline, which a video checks stays clear of its caption.
    var outline: CGRect { get }
    /// Everything `drawBody` touches, its shadow included.
    var bodyExtent: CGRect { get }
    /// Everything `drawGlass` touches.
    var glassExtent: CGRect { get }
    /// The body, and its shadow.
    func drawBody(in context: CGContext)
    /// `image` filling the screen, in the screen's shape.
    func drawScreen(_ image: CGImage, in context: CGContext)
    /// Whatever lies over the screen.
    func drawGlass(in context: CGContext)
}

extension DeviceLook {
    /// Where the light behind the device centres, and how far it reaches.
    public var glowCenter: CGPoint { CGPoint(x: screen.midX, y: screen.maxY - screen.width * 0.15) }
    public var glowRadius: CGFloat { screen.width * 0.95 }
    public var glowExtent: CGRect {
        CGRect(x: glowCenter.x - glowRadius, y: glowCenter.y - glowRadius, width: 2 * glowRadius, height: 2 * glowRadius)
    }

    /// The light behind the device.
    public func drawGlow(in context: CGContext, color: CGColor, opacity: CGFloat = 0.42) {
        ProductPageKitFrames.drawGlow(in: context, center: glowCenter, radius: glowRadius, color: color, opacity: opacity)
    }

    /// Body, screen and glass.
    public func draw(_ capture: CGImage, in context: CGContext) {
        drawBody(in: context)
        drawScreen(capture, in: context)
        drawGlass(in: context)
    }
}
