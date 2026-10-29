import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ProductPageKitFrames
import ProductPageKitTestSupport

@Suite struct TextColumnTests {
    let style = TextStyle(size: 40, weight: .bold, color: .hex(0xFFFFFF))

    @Test func aLongLineWrapsAtSpaces() {
        let layout = TextColumn(x: 0, top: 1000, width: 300).layout("Every alert, accounted for, every time.", style: style)
        #expect(layout.lines.count > 1)
        #expect(layout.lines.dropLast().allSatisfy { $0.hasSuffix(" ") })
        #expect(layout.lines.joined() == "Every alert, accounted for, every time.")
    }

    /// Broken as late as it can be, the last word would sit alone.
    @Test func theLastLineIsBalanced() {
        let text = "Everything, and what became of it."
        let column = TextColumn(x: 0, top: 1000, width: 560)
        let layout = column.layout(text, style: style)
        #expect(layout.lines.count == 2)
        let widths = layout.lines.map { line in
            column.layout(line.trimmingCharacters(in: .whitespaces), style: style).bounds.width
        }
        #expect(widths[1] >= widths[0] * 0.5, "\(layout.lines)")
    }

    @Test func aHeadlineShrinksToFitItsLines() {
        let text = "A headline far too long for four lines in a column this narrow, which comes down a size"
        let layout = TextColumn(x: 0, top: 1000, width: 400).layout(text, style: TextStyle(size: 60, color: .hex(0), maxLines: 4))
        #expect(layout.lines.count <= 4)
        #expect(layout.size < 60)
        #expect(layout.size >= 36)
    }

    /// "Eén lijst, altijd gesynchroniseerd" fitted three lines by breaking
    /// its last word.
    @Test func aHeadlineShrinksRatherThanBreakAWord() {
        let text = "One list, always synchronised"
        let style = TextStyle(size: 60, color: .hex(0), maxLines: 3)
        let layout = TextColumn(x: 0, top: 1000, width: 300).layout(text, style: style)
        #expect(layout.size < 60)
        #expect(layout.lines.map { $0.trimmingCharacters(in: .whitespaces) }.last == "synchronised")
    }

    @Test func accentMarksAreNotDrawn() {
        let layout = TextColumn(x: 0, top: 1000, width: 2000).layout("Ring *until you answer.*", style: style)
        #expect(layout.lines == ["Ring until you answer."])
    }

    @Test func aBreakIsKeptAndCentredTextCentres() {
        let column = TextColumn(x: 100, top: 1000, width: 1000, alignment: .center)
        let layout = column.layout("Hear it\nthe moment", style: style)
        #expect(layout.lines.count == 2)
        #expect(abs(layout.bounds.midX - 600) < 1)
    }

    /// Baselines step down by the line height, and a tight line height eats
    /// into the space above the first.
    @Test func baselinesFollowTheLineHeight() {
        let column = TextColumn(x: 0, top: 1000, width: 2000)
        let loose = column.layout("One\nTwo\nThree", style: TextStyle(size: 100, color: .hex(0), lineHeight: 1.2))
        let tight = column.layout("One\nTwo\nThree", style: TextStyle(size: 100, color: .hex(0), lineHeight: 0.9))
        let natural = loose.ascent + loose.descent
        #expect(loose.baselines.count == 3)
        #expect(abs((loose.baselines[0] - loose.baselines[1]) - natural * 1.2) < 1)
        #expect(abs((tight.baselines[1] - tight.baselines[2]) - natural * 0.9) < 1)
        #expect(tight.baselines[0] > 1000 - tight.ascent)
        #expect(loose.ascent > 80 && loose.descent > 10)
    }

    @Test func aDesignChangesTheFace() {
        let column = TextColumn(x: 0, top: 1000, width: 2000)
        let rounded = TextStyle(size: 40, weight: .bold, design: .rounded, color: .hex(0))
        #expect(column.layout("Dinner, decided", style: rounded).bounds.width
                != column.layout("Dinner, decided", style: style).bounds.width)
    }

    /// The span runs from red at its cap height to blue below its baseline;
    /// the rest keeps the text's colour.
    @Test func aGradientAccentFillsItsSpanTopToBottom() {
        let canvas = Canvas(size: CGSize(width: 600, height: 120))
        let accented = TextStyle(size: 80, weight: .black, color: .hex(0x00FF00),
                                 accent: .gradient(top: .hex(0xFF0000), bottom: .hex(0x0000FF)))
        let bounds = TextColumn(x: 10, top: 110, width: 580).draw("II *II*", style: accented, in: canvas.context)
        let image = canvas.image()
        let pixels = image.dataProvider!.data! as Data
        func color(atX x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            // Premultiplied ARGB, rows from the top.
            let offset = (image.height - 1 - y) * image.bytesPerRow + x * 4
            return (pixels[offset + 1], pixels[offset + 2], pixels[offset + 3], pixels[offset])
        }
        func inked(_ columns: Range<Int>, y: Int) -> [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)] {
            columns.map { color(atX: $0, y: y) }.filter { $0.alpha == 255 }
        }
        let left = Int(bounds.minX)..<Int(bounds.midX) - 10
        let right = Int(bounds.midX) + 10..<Int(bounds.maxX)
        // The rows the capitals fill, a few pixels in from their top and foot.
        let rows = (0..<image.height).filter { !inked(right, y: $0).isEmpty }
        let high = rows.max()! - 4, low = rows.min()! + 4
        #expect(!inked(left, y: high).isEmpty)
        #expect(inked(left, y: high).allSatisfy { $0.green > 200 && $0.red < 50 })
        let top = inked(right, y: high), foot = inked(right, y: low)
        #expect(!top.isEmpty && !foot.isEmpty)
        #expect(top.allSatisfy { $0.red > $0.blue && $0.green < 50 })
        #expect(foot.allSatisfy { $0.blue > $0.red && $0.green < 50 })
    }

    @Test func uppercasedStylesSetCapitals() {
        let layout = TextColumn(x: 0, top: 100, width: 1000).layout("Quiet hours", style: TextStyle(size: 20, color: .hex(0), uppercased: true))
        #expect(layout.lines == ["QUIET HOURS"])
    }

    @Test func theCoveredRectHangsFromTheTop() {
        let layout = TextColumn(x: 50, top: 900, width: 800).layout("One line", style: style)
        #expect(abs(layout.bounds.maxY - 900) < 1)
        #expect(layout.bounds.minX == 50)
    }
}

@Suite struct DeviceBezelTests {
    /// A capture with a corner marked, so a flipped or misplaced screen shows.
    static func capture(width: Int, height: Int) -> CGImage {
        let canvas = Canvas(size: CGSize(width: width, height: height))
        drawGradient(in: canvas.context, rect: canvas.bounds, top: .hex(0x3A6EA5), bottom: .hex(0xC0D6DF))
        canvas.context.setFillColor(.hex(0xE8834F))
        canvas.context.fill(CGRect(x: 0, y: height - height / 8, width: width / 4, height: height / 8))
        return canvas.image()
    }

    /// A light ground's build: a warm, short shadow, no island, and lengths
    /// that follow a wider measure than the screen.
    static let ink = DeviceBezel.Style(
        corners: .init(iPhone: 0.085, iPad: 0.035, iPhoneDuo: 0.03, mac: 0.012, appleTV: 0.004), bezels: .init(0.01),
        shadowOffset: 0.014, shadowBlur: 0.045, shadowColor: .hex(0x3A2418, alpha: 0.34),
        edge: .init(color: .hex(0xFFFFFF, alpha: 0.16), width: 0.0016), seam: .init(color: .hex(0x000000, alpha: 0.22), width: 0.0012),
        island: false)

    func drawn(_ model: DeviceBezel.Model, capture: CGImage, width: CGFloat, style: DeviceBezel.Style = .standard,
               measure: CGFloat? = nil) -> CGImage {
        let height = width * CGFloat(capture.height) / CGFloat(capture.width)
        let canvas = Canvas(size: CGSize(width: width * 1.5, height: height * 1.4))
        drawGradient(in: canvas.context, rect: canvas.bounds, top: .hex(0x222222), bottom: .hex(0x111111))
        let bezel = DeviceBezel(model, screen: CGRect(x: width * 0.25, y: height * 0.2, width: width, height: height),
                                style: style, measure: measure)
        bezel.drawGlow(in: canvas.context, color: .hex(0xD4622F))
        bezel.draw(capture, in: canvas.context)
        return canvas.image()
    }

    @Test func iPhone() throws {
        try Golden.check(drawn(.iPhone, capture: Self.capture(width: 330, height: 717), width: 300), named: "bezel-iphone")
    }

    @Test func iPad() throws {
        try Golden.check(drawn(.iPad, capture: Self.capture(width: 516, height: 688), width: 400), named: "bezel-ipad")
    }

    /// No Dynamic Island on the inner display, and corners as wide as its own.
    @Test func iPhoneDuo() throws {
        try Golden.check(drawn(.iPhoneDuo, capture: Self.capture(width: 634, height: 446), width: 500), named: "bezel-iphone-duo")
    }

    @Test func mac() throws {
        try Golden.check(drawn(.mac, capture: Self.capture(width: 640, height: 400), width: 500), named: "bezel-mac")
    }

    @Test func appleTV() throws {
        try Golden.check(drawn(.appleTV, capture: Self.capture(width: 640, height: 360), width: 500), named: "bezel-appletv")
    }

    @Test func aStyleBuildsTheDevice() throws {
        try Golden.check(drawn(.iPhone, capture: Self.capture(width: 330, height: 717), width: 300, style: Self.ink, measure: 1000),
                         named: "bezel-iphone-styled")
        let bezel = DeviceBezel(.iPhone, screen: CGRect(x: 0, y: 0, width: 300, height: 650), style: Self.ink, measure: 1000)
        #expect(bezel.bezelWidth == 10)
        #expect(DeviceBezel(.iPhone, screen: CGRect(x: 0, y: 0, width: 300, height: 650), style: Self.ink).bezelWidth == 6)
    }

    @Test func everyPartFitsItsExtent() {
        let bezel = DeviceBezel(.iPhone, screen: CGRect(x: 500, y: 500, width: 300, height: 650))
        #expect(bezel.bodyExtent.contains(bezel.outline))
        #expect(bezel.glassExtent.contains(bezel.outline))
        #expect(bezel.outline.contains(bezel.screen))
    }
}

@Suite struct ImageFormatTests {
    let image = DeviceBezelTests.capture(width: 40, height: 30)

    @Test func encodesPNGAndJPEG() throws {
        for format in [ImageFormat.png, .jpeg(quality: 0.9)] {
            let data = try format.encode(image)
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try CGImage.read(from: url).size == CGSize(width: 40, height: 30))
        }
        #expect(try ImageFormat.png.encode(image).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(try ImageFormat.jpeg(quality: 0.9).encode(image).prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func identifiersNameTheSettings() {
        #expect(ImageFormat.png.identifier == "png")
        #expect(ImageFormat.jpeg(quality: 0.8).identifier != ImageFormat.jpeg(quality: 0.9).identifier)
    }

    @Test func grainIsTheSameEveryTime() {
        #expect(Golden.pixels(Grain().tile) == Golden.pixels(Grain().tile))
        #expect(Golden.pixels(Grain(seed: 1).tile) != Golden.pixels(Grain(seed: 2).tile))
    }
}

@Suite struct MotionTests {
    @Test func screensChangeOnSchedule() {
        let schedule = ScreenSchedule(screens: 3, firstChange: 1, loop: 12, dissolve: 0.5)
        #expect(schedule.changes == [1, 5, 9])
        #expect(schedule.state(at: 0).shown == 0)
        #expect(schedule.state(at: 0).mix == 0)
        #expect(schedule.state(at: 0.75).mix > 0)
        #expect(schedule.state(at: 0.75).next == 1)
        #expect(schedule.state(at: 2).shown == 1)
        #expect(schedule.state(at: 9.5).shown == 0)
        // The last change dissolves back into the first screen across the loop's end.
        #expect(schedule.state(at: 12.8).next == 1)
    }

    @Test func aScreenIsInViewBetweenItsDissolves() {
        let schedule = ScreenSchedule(screens: 3, firstChange: 1, loop: 12, dissolve: 0.5)
        #expect(schedule.window(of: 1) == 0.5...5)
        #expect(schedule.window(of: 2) == 4.5...9)
        // The first screen is in view across the loop's end.
        #expect(schedule.window(of: 0) == -3.5...1)
    }

    @Test func oneScreenNeverChanges() {
        let schedule = ScreenSchedule(screens: 1, firstChange: 1, loop: 12, dissolve: 0.5)
        #expect(schedule.changes.isEmpty)
        #expect(schedule.state(at: 5) == (0, 0, 0))
    }

    @Test func aLightBandFallsAwayFromItsCentre() {
        #expect(LightBand.strength(distance: 0, halfWidth: 10) == 1)
        #expect(LightBand.strength(distance: 5, halfWidth: 10) == 0.5)
        #expect(LightBand.strength(distance: -12, halfWidth: 10) == 0)
    }

    @Test func seededRandomRepeats() {
        var a = SeededRandom(seed: 7), b = SeededRandom(seed: 7)
        let first = (0..<5).map { _ in a.next(0...1) }
        #expect(first == (0..<5).map { _ in b.next(0...1) })
        #expect(first.allSatisfy { (0...1).contains($0) })
    }

    @Test func aFloatingDeviceReturnsToWhereItStarted() {
        let bezel = DeviceBezel(.iPhone, screen: CGRect(x: 100, y: 100, width: 60, height: 130))
        let device = FloatingDevice(look: bezel, screens: [.still(DeviceBezelTests.capture(width: 60, height: 130))], lights: [nil],
                                    glow: .hex(0xFF0000), schedule: ScreenSchedule(screens: 1, firstChange: 0, loop: 2, dissolve: 0.2),
                                    drift: CGVector(dx: 10, dy: 5), phase: 0)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
        let context = CIContext()
        let start = context.createCGImage(device.composited(over: background, at: 0), from: background.extent)!
        let end = context.createCGImage(device.composited(over: background, at: 2), from: background.extent)!
        let middle = context.createCGImage(device.composited(over: background, at: 0.5), from: background.extent)!
        #expect(Golden.pixels(start) == Golden.pixels(end))
        #expect(Golden.pixels(start) != Golden.pixels(middle))
        #expect(device.reach == bezel.outline.insetBy(dx: -10, dy: -5))
    }

    /// The light a screen casts goes with it: full while it is shown, and
    /// handed to the next screen's as they dissolve.
    @Test func aScreensLightDissolvesWithIt() {
        let bezel = DeviceBezel(.iPhone, screen: CGRect(x: 100, y: 100, width: 60, height: 130))
        let red = CIImage(color: CIColor(red: 0.5, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        let device = FloatingDevice(look: bezel, screens: [.still(DeviceBezelTests.capture(width: 60, height: 130)),
                                                           .still(DeviceBezelTests.capture(width: 60, height: 130))],
                                    lights: [red, nil], glow: nil,
                                    schedule: ScreenSchedule(screens: 2, firstChange: 1, loop: 2, dissolve: 0.5), drift: .zero, phase: 0)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
        func redness(at time: Double) -> UInt8 {
            let image = CIContext().createCGImage(device.composited(over: background, at: time), from: background.extent)!
            return Golden.pixels(image)[(299 * 300 + 10) * 4]
        }
        let shown = redness(at: 0.2), dissolving = redness(at: 0.75)
        #expect(shown > 150)
        #expect(dissolving > 50 && dissolving < shown - 50)
        #expect(redness(at: 1.5) == 0)
    }

    /// A movie on a screen plays from when the screen comes into view.
    @Test func aMoviePlaysOnItsScreen() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await VideoEncoder.encode(to: url, size: CGSize(width: 320, height: 160), fps: 30, frames: 60) { index in
            CIImage(color: CIColor(red: index < 30 ? 1 : 0, green: index < 30 ? 0 : 1, blue: 0))
        }
        let reel = try await MovieReel(url, from: 0.5, seconds: 1)
        #expect(reel.poster.width == 320)
        let context = CIContext()
        func color(at seconds: Double) -> [UInt8] {
            let frame = reel.frame(at: seconds)!
            let image = context.createCGImage(frame, from: frame.extent)!
            return Array(Golden.pixels(image)[0..<3])
        }
        #expect(color(at: 0.2)[0] > 200)
        #expect(color(at: 0.8)[1] > 200)
    }

    @Test func encodesEveryFrameAtItsSize() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await VideoEncoder.encode(to: url, size: CGSize(width: 320, height: 160), fps: 30, frames: 15) { index in
            CIImage(color: CIColor(red: Double(index) / 15, green: 0, blue: 0))
        }
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 160))
        #expect(try await track.load(.nominalFrameRate).rounded() == 30)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 0.5) < 0.05)
    }
}
