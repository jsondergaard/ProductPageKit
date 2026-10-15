public import AppKit
public import CoreGraphics
import CoreText

/// How a run of text is set.
public struct TextStyle: Sendable {
    /// How the span between asterisks, `*like this*`, is filled.
    public enum Accent: Sendable {
        case color(CGColor)
        /// From `top` at the cap height down to `bottom` below the baseline,
        /// line by line.
        case gradient(top: CGColor, bottom: CGColor)
    }

    public var size: CGFloat
    public var weight: NSFont.Weight
    /// The system font's design: `.rounded`, `.serif`.
    public var design: NSFontDescriptor.SystemDesign
    public var color: CGColor
    public var accent: Accent?
    /// Letter spacing, as a fraction of the size.
    public var tracking: CGFloat
    public var lineHeight: CGFloat
    /// Shrinks the text, down to six tenths of `size`, until it fits in this
    /// many lines without breaking a word. Without it the text wraps freely.
    public var maxLines: Int?
    public var uppercased: Bool

    public init(size: CGFloat, weight: NSFont.Weight = .regular, design: NSFontDescriptor.SystemDesign = .default,
                color: CGColor, accent: Accent? = nil, tracking: CGFloat = 0, lineHeight: CGFloat = 1.1, maxLines: Int? = nil,
                uppercased: Bool = false) {
        self.size = size
        self.weight = weight
        self.design = design
        self.color = color
        self.accent = accent
        self.tracking = tracking
        self.lineHeight = lineHeight
        self.maxLines = maxLines
        self.uppercased = uppercased
    }
}

/// A column text is set in: from `x` to `x + width`, its first line's top at
/// `top`, in the context's own coordinates.
///
/// Lines are balanced: a paragraph broken as late as it can be leaves its last
/// word alone, so the column narrows, keeping its alignment edge, until the
/// last line is at least half the longest, as long as that costs no line and
/// breaks no word.
public struct TextColumn: Sendable {
    public enum Alignment: Sendable {
        case leading
        case center
    }

    public var x: CGFloat
    public var top: CGFloat
    public var width: CGFloat
    public var alignment: Alignment

    public init(x: CGFloat, top: CGFloat, width: CGFloat, alignment: Alignment = .leading) {
        self.x = x
        self.top = top
        self.width = width
        self.alignment = alignment
    }

    /// The column moved down by `distance`.
    public func lowered(by distance: CGFloat) -> TextColumn {
        TextColumn(x: x, top: top - distance, width: width, alignment: alignment)
    }

    /// `text` as it would be set.
    public func layout(_ text: String, style: TextStyle) -> TextLayout {
        let floor = style.size * 0.6
        var size = style.size
        while true {
            let string = attributed(style.uppercased ? text.uppercased() : text, style: style, size: size)
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRangeMake(0, 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let rect = CGRect(x: x, y: top - fitted.height, width: width, height: ceil(fitted.height))
            var frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: rect, transform: nil), nil)
            var lines = CTFrameGetLines(frame) as! [CTLine]
            if let maxLines = style.maxLines, lines.count > maxLines || !Self.breaksAtSpaces(lines, in: string.string),
               size > floor {
                size -= style.size * 0.04
                continue
            }
            if lines.count > 1 {
                for fraction in stride(from: 0.96, through: 0.5, by: -0.02) {
                    let narrow = width * fraction
                    let narrowRect = CGRect(x: alignment == .center ? x + (width - narrow) / 2 : x, y: rect.minY,
                                            width: narrow, height: rect.height)
                    let candidate = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0),
                                                             CGPath(rect: narrowRect, transform: nil), nil)
                    let candidateLines = CTFrameGetLines(candidate) as! [CTLine]
                    guard candidateLines.count == lines.count,
                          CTFrameGetVisibleStringRange(candidate).length == string.length,
                          Self.breaksAtSpaces(candidateLines, in: string.string)
                    else { break }
                    frame = candidate
                    lines = candidateLines
                    let widths = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }
                    if let last = widths.last, let longest = widths.max(), last >= longest * 0.5 { break }
                }
            }
            let longest = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
            let left = alignment == .center ? x + (width - longest) / 2 : x
            let characters = string.string as NSString
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
            let font = Self.font(style, size: size)
            return TextLayout(
                frame: frame,
                lines: lines.map {
                    let range = CTLineGetStringRange($0)
                    return characters.substring(with: NSRange(location: range.location, length: range.length))
                },
                size: size,
                bounds: CGRect(x: left, y: rect.minY, width: longest, height: rect.height),
                baselines: origins.map { rect.minY + $0.y },
                ascent: font.ascender,
                descent: -font.descender)
        }
    }

    /// Sets and draws `text`. Returns the rect its lines cover.
    @discardableResult
    public func draw(_ text: String, style: TextStyle, in context: CGContext) -> CGRect {
        let layout = layout(text, style: style)
        guard case .gradient(let top, let bottom) = style.accent else {
            CTFrameDraw(layout.frame, context)
            return layout.bounds
        }
        let lines = CTFrameGetLines(layout.frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(layout.frame, CFRangeMake(0, 0), &origins)
        let path = CTFrameGetPath(layout.frame).boundingBox
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [top, bottom] as CFArray,
                                  locations: [0, 1])!
        for (line, lineOrigin) in zip(lines, origins) {
            // Line origins are measured from the frame's own corner.
            let origin = CGPoint(x: path.minX + lineOrigin.x, y: path.minY + lineOrigin.y)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard attributes[Self.accentKey] != nil else {
                    context.textPosition = origin
                    CTRunDraw(run, context, CFRange())
                    continue
                }
                let font = attributes[kCTFontAttributeName] as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                let outline = CGMutablePath()
                for (glyph, position) in zip(glyphs, positions) {
                    var place = CGAffineTransform(translationX: origin.x + position.x, y: origin.y + position.y)
                    if let glyphPath = CTFontCreatePathForGlyph(font, glyph, &place) { outline.addPath(glyphPath) }
                }
                let size = CTFontGetSize(font)
                context.saveGState()
                context.addPath(outline)
                context.clip()
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: origin.y + size * 0.75),
                                           end: CGPoint(x: 0, y: origin.y - size * 0.2),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
        }
        return layout.bounds
    }

    /// Marks the runs a gradient accent fills.
    private static let accentKey = NSAttributedString.Key("ProductPageKitAccent")

    private func attributed(_ text: String, style: TextStyle, size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment == .center ? .center : .left
        paragraph.lineHeightMultiple = style.lineHeight
        let font = Self.font(style, size: size)
        let string = NSMutableAttributedString()
        // A span may open on one line and close on the next, so the spans
        // alternate across the whole text.
        for (index, span) in text.components(separatedBy: "*").enumerated() where !span.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(cgColor: style.color)!,
                .paragraphStyle: paragraph,
                .kern: style.tracking * size,
            ]
            if index % 2 == 1 {
                switch style.accent {
                case .color(let color): attributes[.foregroundColor] = NSColor(cgColor: color)!
                case .gradient: attributes[Self.accentKey] = true
                case nil: break
                }
            }
            string.append(NSAttributedString(string: span, attributes: attributes))
        }
        return string
    }

    private static func font(_ style: TextStyle, size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: style.weight)
        return system.fontDescriptor.withDesign(style.design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    }

    /// Whether every line but the last ends at a space. Narrower than its
    /// longest word, a column breaks inside the word or before the comma
    /// after it.
    static func breaksAtSpaces(_ lines: [CTLine], in text: String) -> Bool {
        let characters = Array(text.utf16)
        for line in lines.dropLast() {
            let range = CTLineGetStringRange(line)
            let last = range.location + range.length - 1
            guard last >= 0, last < characters.count, let scalar = Unicode.Scalar(characters[last]),
                  scalar.properties.isWhitespace
            else { return false }
        }
        return true
    }
}

/// Text set in a column, ready to draw.
public struct TextLayout {
    let frame: CTFrame
    /// Each line's text, as broken.
    public let lines: [String]
    /// The size it was set at, after shrinking to fit.
    public let size: CGFloat
    /// What its lines cover.
    public let bounds: CGRect
    /// Each line's baseline, top first, for a theme that places type by its
    /// ink rather than its line boxes: a line height under 1 is taken from
    /// above the first line, so its capitals rise past `bounds`.
    public let baselines: [CGFloat]
    /// How far the font reaches above and below a baseline, at the size set.
    public let ascent: CGFloat
    public let descent: CGFloat
}
