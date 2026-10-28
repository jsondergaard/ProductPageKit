import CoreGraphics
import Foundation
import ImageIO
import ProductPageKitCore
import UniformTypeIdentifiers

/// A captured frame: the image, and its PNG when the capture produced one.
struct Frame: @unchecked Sendable {
    let image: CGImage
    let png: Data

    init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RunnerError.unreadableCapture }
        self.image = image
        self.png = png
    }

    init(image: CGImage) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw RunnerError.unreadableCapture }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RunnerError.unreadableCapture }
        self.image = image
        png = data as Data
    }

    /// Whether the display's mask is drawn: a simulator screenshot composed
    /// as usual has the rounded corners masked black.
    var isMasked: Bool {
        guard let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let pixel = FrameStability.pixels(corner)
        else { return false }
        return pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255
    }

    /// Whether the frame shows anything: a display that is off photographs
    /// black. Read from a 64 × 64 reduction, which is enough to tell.
    var showsContent: Bool {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        return (0..<side * side * 4).contains { $0 % 4 != 3 && pixels[$0] > 8 }
    }

    /// Fractions of the frame, as the app reports them, in its pixels.
    func highlights(_ fractions: [CGRect]) -> Highlights {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return Highlights(fractions.map {
            CGRect(x: $0.minX * width, y: $0.minY * height, width: $0.width * width, height: $0.height * height).integral
        })
    }
}

/// Decides when a scene has stopped moving: frames are taken one after
/// another, after the app has said ready, until two in a row match. That
/// catches a transition, a spinner or an image arriving late, at the cost of
/// one or two frames when nothing moves.
struct FrameStability {
    /// The share of pixels that may differ between matching frames: a caret's
    /// blink passes, a spinner does not.
    var tolerance = 0.0002
    /// A channel difference at or below this is the same colour.
    var channelThreshold: UInt8 = 2
    /// Frames to try before giving up on a scene that never settles.
    var maximumFrames = 40
    /// Where a scene that never settles leaves its last two frames and what
    /// changed between them, or nil to leave nothing.
    var evidence: URL?

    /// - Parameter moving: what moves on purpose, as fractions of the frame
    ///   from its top left, which is left out of the comparison.
    /// - Parameter remeasuring: asks the app where what moves is now, when two
    ///   frames differ: a view can mount after the app said ready.
    func settle(_ what: String, moving: [CGRect] = [], remeasuring: (() async throws -> [CGRect])? = nil,
                capture: () async throws -> Frame) async throws -> Frame {
        var moving = moving
        var previous = try await capture()
        for _ in 1..<maximumFrames {
            let frame = try await capture()
            if frame.png == previous.png || matches(previous.image, frame.image, ignoring: moving) { return frame }
            if let remeasuring {
                moving = try await remeasuring()
                if matches(previous.image, frame.image, ignoring: moving) { return frame }
            }
            previous = frame
        }
        let last = try await capture()
        throw RunnerError.unstable(what, frames: maximumFrames,
                                   evidence: try evidence.map { try record(what, previous, last, ignoring: moving, in: $0) })
    }

    /// Writes `a`, `b` and a map of where they differ: changed pixels red
    /// over the second frame greyed, what moves on purpose blue.
    private func record(_ what: String, _ a: Frame, _ b: Frame, ignoring moving: [CGRect], in directory: URL) throws -> URL {
        let stem = what.filter { $0.isLetter || $0.isNumber || $0 == " " }.replacingOccurrences(of: " ", with: "-")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try a.png.write(to: directory.appending(path: "\(stem)-1.png"))
        try b.png.write(to: directory.appending(path: "\(stem)-2.png"))
        if a.image.width == b.image.width, a.image.height == b.image.height,
           let first = Self.pixels(a.image), var map = Self.pixels(b.image) {
            let width = a.image.width, height = a.image.height
            let ignored = moving.map {
                CGRect(x: $0.minX * CGFloat(width), y: $0.minY * CGFloat(height), width: $0.width * CGFloat(width),
                       height: $0.height * CGFloat(height)).integral
            }
            for row in 0..<height {
                for column in 0..<width {
                    let pixel = (row * width + column) * 4
                    let changed = (0..<3).contains { first[pixel + $0].distance(to: map[pixel + $0]) > channelThreshold }
                    let grey = UInt8((Int(map[pixel]) + Int(map[pixel + 1]) + Int(map[pixel + 2])) / 9)
                    let onPurpose = ignored.contains { $0.contains(CGPoint(x: column, y: row)) }
                    let (red, green, blue): (UInt8, UInt8, UInt8) = changed && !onPurpose ? (255, 0, 0) : onPurpose ? (grey, grey, 160) : (grey, grey, grey)
                    map[pixel] = red; map[pixel + 1] = green; map[pixel + 2] = blue; map[pixel + 3] = 255
                }
            }
            if let image = CGImage.rgba(map, width: width, height: height) {
                try Frame(image: image).png.write(to: directory.appending(path: "\(stem)-changed.png"))
            }
        }
        return directory.appending(path: "\(stem)-changed.png")
    }

    func matches(_ a: CGImage, _ b: CGImage, ignoring moving: [CGRect] = []) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let first = Self.pixels(a), let second = Self.pixels(b)
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
                    where (0..<4).contains(where: { lhs[pixel + $0].distance(to: rhs[pixel + $0]) > channelThreshold }) {
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

    /// RGBA, eight bits a channel, whatever the capture's own layout.
    static func pixels(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}

private extension UInt8 {
    func distance(to other: UInt8) -> UInt8 { self > other ? self - other : other - self }
}

/// A component shown over black and then over white, as a Mac app shows one
/// so the window server draws its glass, made transparent: a pixel's opacity
/// is how far the two backdrops fail to show through it, and its colour is
/// what it adds over black.
enum Matte {
    static func transparent(black: CGImage, white: CGImage) -> CGImage? {
        guard black.width == white.width, black.height == white.height,
              var dark = FrameStability.pixels(black), let light = FrameStability.pixels(white)
        else { return nil }
        for index in stride(from: 0, to: dark.count, by: 4) {
            var through = 0
            for channel in 0..<3 { through += Int(light[index + channel]) - Int(dark[index + channel]) }
            let opacity = UInt8(max(0, min(255, 255 - through / 3)))
            // Premultiplied: over black, a pixel already is colour times opacity.
            for channel in 0..<3 { dark[index + channel] = min(dark[index + channel], opacity) }
            dark[index + 3] = opacity
        }
        return CGImage.rgba(dark, width: black.width, height: black.height)
    }
}

extension CGImage {
    /// The image without its fully transparent edges, so a component is
    /// placed by what it draws.
    func trimmingTransparentEdges() -> CGImage {
        guard let pixels = FrameStability.pixels(self) else { return self }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 0 {
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return self }
        return cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? self
    }

    /// Premultiplied sRGB RGBA, eight bits a channel.
    static func rgba(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        var pixels = pixels
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
    }
}
