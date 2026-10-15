import CoreGraphics
import CoreImage
import Foundation
@testable import ProductPageKit

/// A small theme built only from the package's parts, as an app's would be:
/// a ground, the caption above, and the capture in a bezel below. The list
/// also has the blue basket component laid over its corner.
struct SampleFrames: FrameTheme {
    static let basket = Component("basket", variant: "blue")

    func sources(for frame: FrameSubject) -> [FrameSource] {
        let own = FrameSource.capture(frame.shot, on: frame.platform)
        return frame.shot == "list" ? [own, .component(Self.basket, on: frame.platform)] : [own]
    }

    func render(_ shot: FramedShot, on canvas: Canvas) throws {
        let size = canvas.size
        let grounds: [(UInt32, UInt32)] = [(0x1F2A44, 0x0B0F1A), (0x2B1F44, 0x100B1A)]
        let ground = grounds[shot.position % grounds.count]
        drawGradient(in: canvas.context, rect: canvas.bounds, top: .hex(ground.0), bottom: .hex(ground.1))
        let portrait = size.height > size.width
        let column = TextColumn(x: size.width * 0.08, top: size.height * (portrait ? 0.93 : 0.8), width: size.width * (portrait ? 0.84 : 0.3))
        SampleFrames.draw(shot.caption, in: column, size: size.width * (portrait ? 0.09 : 0.04), context: canvas.context)
        let width = size.width * (portrait ? 0.8 : 0.55)
        let capture = try shot.capture
        let height = width * CGFloat(capture.height) / CGFloat(capture.width)
        let screen = CGRect(x: portrait ? size.width * 0.1 : size.width * 0.4, y: size.height * (portrait ? 0.62 : 0.85) - height,
                            width: width, height: height)
        let bezel = DeviceBezel(shot.platform.bezel, screen: screen)
        bezel.drawGlow(in: canvas.context, color: .hex(0x4F8AE8))
        bezel.draw(capture, in: canvas.context)
        // Each highlight outlined where it sits on the screen.
        let scale = screen.width / CGFloat(capture.width)
        canvas.context.setStrokeColor(Self.highlight)
        canvas.context.setLineWidth(8)
        for rect in try shot.highlights {
            canvas.context.stroke(CGRect(x: screen.minX + rect.minX * scale, y: screen.maxY - rect.maxY * scale,
                                         width: rect.width * scale, height: rect.height * scale))
        }
        if shot.shot == "list" {
            let basket = try shot.image(.component(Self.basket, on: shot.platform))
            let width = size.width * 0.3
            canvas.context.draw(basket, in: CGRect(x: size.width * 0.65, y: size.height * 0.05, width: width,
                                                   height: width * CGFloat(basket.height) / CGFloat(basket.width)))
        }
    }

    static let highlight = CGColor.hex(0xFFD60A)

    @discardableResult
    static func draw(_ caption: Caption, in column: TextColumn, size: CGFloat, context: CGContext) -> CGRect {
        var column = column
        var covered = CGRect.null
        if let kicker = caption.kicker {
            let used = column.draw(kicker, style: TextStyle(size: size * 0.3, weight: .semibold, color: .hex(0x4F8AE8), uppercased: true),
                                   in: context)
            covered = covered.union(used)
            column = column.lowered(by: used.height + size * 0.2)
        }
        let headline = column.draw(caption.headline, style: TextStyle(size: size, weight: .bold, color: .hex(0xFFFFFF),
                                                                      accent: .color(.hex(0x4F8AE8)), maxLines: 3), in: context)
        covered = covered.union(headline)
        if let subline = caption.subline {
            covered = covered.union(column.lowered(by: headline.height + size * 0.3)
                .draw(subline, style: TextStyle(size: size * 0.4, color: .hex(0xFFFFFF, alpha: 0.7)), in: context))
        }
        return covered
    }
}

/// A one-second loop: a phone dissolving between two shots beside the
/// caption, on a plain ground.
struct SampleMotion: MotionTheme {
    var motion = Motion(seconds: 1, fps: 30, dissolve: 0.2)
    var assets: [CreativeAsset]
    /// Where the caption's column sits, in fractions of the canvas.
    var column = (x: 0.3, top: 0.32, width: 0.4)

    init(shots: [VideoScreen], phone: (x: CGFloat, top: CGFloat, width: CGFloat) = (0.75, 0.2, 0.08)) {
        assets = [CreativeAsset(.header, poster: 0.5, devices: [
            DeviceLayer(.iPhone, screens: shots, x: phone.x, top: phone.top, width: phone.width, firstChange: 0.25,
                        drift: CGVector(dx: 0.001, dy: 0.002)),
        ])]
    }

    func stage(for asset: CreativeAsset) -> any MotionStage {
        SampleStage(size: asset.size, column: column)
    }
}

struct SampleStage: MotionStage {
    let size: CGSize
    let column: (x: Double, top: Double, width: Double)

    var deviceGlow: CGColor? { .hex(0x4F8AE8) }

    func device(_ platform: Platform.Kind, screen: CGRect) -> any DeviceLook {
        DeviceBezel(platform.bezel, screen: screen)
    }

    func drawCaption(_ caption: Caption, on canvas: Canvas, locale: StoreLocale) -> CGRect {
        SampleFrames.draw(caption, in: TextColumn(x: size.width * column.x, top: size.height * (1 - column.top),
                                                  width: size.width * column.width, alignment: .center),
                          size: size.height * 0.08, context: canvas.context)
    }

    /// A plain ground, a little lighter behind the caption.
    func background(at time: Double, layout: VideoLayout) -> CIImage {
        CIImage(color: CIColor(red: 0.1, green: 0.12, blue: 0.16)).cropped(to: layout.caption.insetBy(dx: -40, dy: -40))
            .composited(over: CIImage(color: CIColor(red: 0.05, green: 0.07, blue: 0.1 + 0.05 * time))
                .cropped(to: CGRect(origin: .zero, size: size)))
    }

    func foreground(over image: CIImage, caption: CaptionLayer, layout: VideoLayout, at time: Double) -> CIImage {
        caption.image.composited(over: image)
    }
}
