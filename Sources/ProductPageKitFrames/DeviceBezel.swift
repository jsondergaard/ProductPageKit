public import CoreGraphics

/// A device drawn around a capture: a body with the screen inset into it, a
/// deep shadow beneath, and a hairline of light along the edge so it
/// separates from a ground nearly the body's own colour. Every length follows
/// `measure`, the screen's width unless a theme says otherwise, so a phone
/// small in a wide banner is built like one filling a screenshot.
///
/// It draws in three passes, body, screen and glass, so a video can dissolve
/// one screen into the next between the body and what lies over the glass.
public struct DeviceBezel: DeviceLook {
    public enum Model: Sendable {
        /// With the Dynamic Island, which a simulator capture leaves out: the
        /// status bar sits either side of a gap.
        case iPhone
        case iPad
        /// The foldable iPhone's inner display, which has no Dynamic Island.
        case iPhoneDuo
        /// A window, so its corners are small and its edge thin.
        case mac
        case appleTV
    }

    /// How a brand builds its devices. Lengths are fractions of the bezel's
    /// `measure`; corners are fractions of the screen's own width.
    public struct Style: Sendable {
        /// One value per model.
        public struct PerModel: Sendable {
            public var iPhone: CGFloat
            public var iPad: CGFloat
            public var iPhoneDuo: CGFloat
            public var mac: CGFloat
            public var appleTV: CGFloat

            public init(iPhone: CGFloat, iPad: CGFloat, iPhoneDuo: CGFloat, mac: CGFloat, appleTV: CGFloat) {
                self.iPhone = iPhone
                self.iPad = iPad
                self.iPhoneDuo = iPhoneDuo
                self.mac = mac
                self.appleTV = appleTV
            }

            /// The same value for every model.
            public init(_ value: CGFloat) {
                self.init(iPhone: value, iPad: value, iPhoneDuo: value, mac: value, appleTV: value)
            }

            public subscript(model: Model) -> CGFloat {
                switch model {
                case .iPhone: iPhone
                case .iPad: iPad
                case .iPhoneDuo: iPhoneDuo
                case .mac: mac
                case .appleTV: appleTV
                }
            }
        }

        /// A line stroked along an edge.
        public struct Line: Sendable {
            public var color: CGColor
            public var width: CGFloat

            public init(color: CGColor, width: CGFloat) {
                self.color = color
                self.width = width
            }
        }

        /// The screen's corner radius, as a fraction of its width.
        public var corners: PerModel
        /// How far the body reaches past the screen, never less than 6 pixels.
        public var bezels: PerModel
        /// How far the shadow falls below the body, and how soft it is.
        public var shadowOffset: CGFloat
        public var shadowBlur: CGFloat
        public var shadowColor: CGColor
        /// The light along the body's edge and the seam at the screen's.
        public var edge: Line
        public var seam: Line
        /// Whether an iPhone gets its Dynamic Island.
        public var island: Bool

        public init(corners: PerModel, bezels: PerModel, shadowOffset: CGFloat, shadowBlur: CGFloat, shadowColor: CGColor,
                    edge: Line, seam: Line, island: Bool) {
            self.corners = corners
            self.bezels = bezels
            self.shadowOffset = shadowOffset
            self.shadowBlur = shadowBlur
            self.shadowColor = shadowColor
            self.edge = edge
            self.seam = seam
            self.island = island
        }

        /// A deep shadow and a bright edge, for a dark ground.
        ///
        /// iPhone Duo's corner is as wide as the inner display's own, which
        /// its simulator mask puts at 6.5% of the landscape width. Any
        /// tighter and the capture's black corners show inside the screen,
        /// beside a sidebar iOS rounds to the display.
        public static let standard = Style(
            corners: PerModel(iPhone: 0.085, iPad: 0.03, iPhoneDuo: 0.065, mac: 0.012, appleTV: 0.004),
            bezels: PerModel(iPhone: 0.0125, iPad: 0.025, iPhoneDuo: 0.0175, mac: 0.0125, appleTV: 0.008),
            shadowOffset: 0.0225, shadowBlur: 0.075, shadowColor: .hex(0x000000, alpha: 0.55),
            edge: Line(color: .hex(0xFFFFFF, alpha: 0.22), width: 0.002),
            seam: Line(color: .hex(0x000000, alpha: 0.35), width: 0.0015),
            island: true
        )
    }

    public let model: Model
    public let screen: CGRect
    public let finish: CGColor
    public let style: Style
    /// The width the style's lengths are fractions of.
    public let measure: CGFloat

    /// - Parameters:
    ///   - finish: the body's colour.
    ///   - measure: the width the style's lengths follow. The screen's by
    ///     default; a theme that shrinks a device to fit passes the width it
    ///     was laid out at, so the body keeps its build.
    public init(_ model: Model, screen: CGRect, finish: CGColor = .hex(0x1D1D1F), style: Style = .standard,
                measure: CGFloat? = nil) {
        self.model = model
        self.screen = screen
        self.finish = finish
        self.style = style
        self.measure = measure ?? screen.width
    }

    public var bezelWidth: CGFloat { max(measure * style.bezels[model], 6) }
    public var outline: CGRect { screen.insetBy(dx: -bezelWidth, dy: -bezelWidth) }
    var shadowOffset: CGFloat { measure * style.shadowOffset }
    var shadowBlur: CGFloat { measure * style.shadowBlur }
    public var bodyExtent: CGRect { outline.insetBy(dx: -2 * shadowBlur, dy: -2 * shadowBlur - shadowOffset) }
    /// Including the light stroked half outside the body's edge.
    public var glassExtent: CGRect { outline.insetBy(dx: -4, dy: -4) }

    private var screenRadius: CGFloat { screen.width * style.corners[model] }
    private var bezelPath: CGPath {
        let radius = screenRadius + bezelWidth
        return CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    private var screenPath: CGPath {
        CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)
    }

    public func drawBody(in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -shadowOffset), blur: shadowBlur, color: style.shadowColor)
        context.addPath(bezelPath)
        context.setFillColor(finish)
        context.fillPath()
        context.restoreGState()
    }

    public func drawScreen(_ capture: CGImage, in context: CGContext) {
        context.saveGState()
        context.addPath(screenPath)
        context.clip()
        context.draw(capture, in: screen)
        context.restoreGState()
    }

    /// The island, a light along the body's edge and a darker seam at the
    /// screen's. Between them the two lines do most of the work of looking real.
    public func drawGlass(in context: CGContext) {
        if model == .iPhone, style.island {
            // Proportions of the 6.9" screen, so it sits in the gap the status
            // bar leaves for it rather than over the time.
            let width = screen.width * 0.287
            let height = screen.width * 0.084
            let island = CGRect(x: screen.midX - width / 2, y: screen.maxY - screen.width * 0.025 - height,
                                width: width, height: height)
            context.saveGState()
            context.setFillColor(.hex(0x000000))
            context.addPath(CGPath(roundedRect: island, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(bezelPath)
        context.setStrokeColor(style.edge.color)
        context.setLineWidth(max(1, measure * style.edge.width))
        context.strokePath()
        context.addPath(screenPath)
        context.setStrokeColor(style.seam.color)
        context.setLineWidth(max(1, measure * style.seam.width))
        context.strokePath()
        context.restoreGState()
    }
}
