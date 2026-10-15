public import CoreGraphics
public import CoreImage
import Foundation

/// When a device's screens change in a loop. Change `n` finishes at
/// `changes[n]`, from screen `n` into the next, after dissolving for
/// `dissolve` seconds; the last change returns to the first screen, so the
/// loop starts on it.
public struct ScreenSchedule: Sendable {
    public let changes: [Double]
    public let loop: Double
    public let dissolve: Double

    /// `screens` shown for an equal share of `loop` each, the first change
    /// finishing at `firstChange`.
    public init(screens: Int, firstChange: Double, loop: Double, dissolve: Double) {
        let beat = loop / Double(screens)
        changes = screens > 1 ? (0..<screens).map { firstChange + Double($0) * beat } : []
        self.loop = loop
        self.dissolve = dissolve
    }

    /// The screen shown at `time`, the one it dissolves into next, and how far
    /// that dissolve has come, eased in and out.
    public func state(at time: Double) -> (shown: Int, next: Int, mix: Double) {
        guard !changes.isEmpty else { return (0, 0, 0) }
        let shown = changes.filter { $0 <= time }.count % changes.count
        let next = (changes + [changes[0] + loop]).first { $0 > time }!
        let progress = min(1, max(0, 1 - (next - time) / dissolve))
        return (shown, (shown + 1) % changes.count, progress * progress * (3 - 2 * progress))
    }

    /// When screen `index` is in view, its dissolves in and out included. A
    /// lone screen never leaves.
    public func window(of index: Int) -> ClosedRange<Double> {
        guard !changes.isEmpty else { return -Double.infinity...Double.infinity }
        let enter = index == 0 ? changes[changes.count - 1] - loop : changes[index - 1]
        let exit = changes[index]
        return (enter - dissolve)...exit
    }
}

/// A device in a video, drawn once: the glow behind it, its body, each screen
/// to dissolve over that with the light it casts, and its glass. It floats
/// on an ellipse that closes with the loop, and its glow breathes with it.
public struct FloatingDevice: Sendable {
    /// What one of its screens shows.
    public enum Screen: Sendable {
        case still(CGImage)
        /// A movie, letterboxed on black, playing from when the screen comes
        /// into view.
        case movie(MovieReel)
    }

    private enum Drawn {
        case still(CIImage)
        case movie(MovieReel, entersAt: Double, mask: CIImage)
    }

    let glow: CIImage?
    let body: CIImage
    private let screens: [Drawn]
    let lights: [CIImage?]
    let glass: CIImage
    public let schedule: ScreenSchedule
    /// How far it floats each way, in pixels.
    public let drift: CGVector
    /// Where in the loop its float starts, in radians.
    public let phase: Double
    /// Everything the body can reach as it floats.
    public let reach: CGRect
    private let screenRect: CGRect

    /// - Parameter lights: the light each screen casts, in canvas
    ///   coordinates, or nil for a screen that casts none.
    public init(look: any DeviceLook, screens: [Screen], lights: [CIImage?], glow: CGColor?, schedule: ScreenSchedule,
                drift: CGVector, phase: Double) {
        self.glow = glow.map { color in CIImage.drawn(in: look.glowExtent) { look.drawGlow(in: $0, color: color) } }
        body = CIImage.drawn(in: look.bodyExtent) { look.drawBody(in: $0) }
        let mask = CIImage.drawn(in: look.screen) { look.drawScreen(Self.white, in: $0) }
        self.screens = screens.enumerated().map { index, screen in
            switch screen {
            case .still(let image): .still(CIImage.drawn(in: look.screen) { look.drawScreen(image, in: $0) })
            case .movie(let reel): .movie(reel, entersAt: schedule.window(of: index).lowerBound, mask: mask)
            }
        }
        self.lights = lights
        glass = CIImage.drawn(in: look.glassExtent) { look.drawGlass(in: $0) }
        self.schedule = schedule
        self.drift = drift
        self.phase = phase
        reach = look.outline.insetBy(dx: -abs(drift.dx), dy: -abs(drift.dy))
        screenRect = look.screen
    }

    public func composited(over background: CIImage, at time: Double) -> CIImage {
        let state = schedule.state(at: time)
        let angle = 2 * .pi * time / schedule.loop + phase
        let shift = CGAffineTransform(translationX: drift.dx * sin(angle), y: drift.dy * sin(angle))
        var image = background
        if let glow { image = glow.faded(0.85 + 0.15 * cos(angle)).transformed(by: shift).composited(over: image) }
        if let light = lights[state.shown] { image = light.faded(1 - state.mix).transformed(by: shift).lighting(image) }
        if state.mix > 0, let light = lights[state.next] { image = light.faded(state.mix).transformed(by: shift).lighting(image) }
        image = body.transformed(by: shift).composited(over: image)
        image = screen(state.shown, at: time).transformed(by: shift).composited(over: image)
        if state.mix > 0 {
            image = screen(state.next, at: time).faded(state.mix).transformed(by: shift).composited(over: image)
        }
        return glass.transformed(by: shift).composited(over: image)
    }

    private func screen(_ index: Int, at time: Double) -> CIImage {
        switch screens[index] {
        case .still(let image):
            return image
        case .movie(let reel, let entersAt, let mask):
            let black = CIImage(color: .black).cropped(to: screenRect)
            guard let frame = reel.frame(at: time - entersAt) else { return black.masked(by: mask) }
            let scale = min(screenRect.width / frame.extent.width, screenRect.height / frame.extent.height)
            let fitted = frame.samplingLinear().transformed(by: CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: screenRect.midX - frame.extent.width * scale / 2, ty: screenRect.midY - frame.extent.height * scale / 2))
            return fitted.composited(over: black).masked(by: mask)
        }
    }

    /// One white pixel, which a look stretches over its screen for a mask
    /// in the screen's shape.
    private static let white: CGImage = {
        let context = Canvas.bitmap(width: 1, height: 1)
        context.setFillColor(.hex(0xFFFFFF))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }()
}
