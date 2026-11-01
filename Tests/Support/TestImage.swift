public import CoreGraphics
import Foundation

/// A grey image 100 pixels tall with its first `marked` pixels, from the top
/// left, painted `mark`: white unless named.
public func testImage(marked: Int = 0, width: Int = 100, mark: [UInt8] = [255, 255, 255, 255]) -> CGImage {
    var pixels = [UInt8](repeating: 128, count: width * 100 * 4)
    for pixel in 0..<marked { pixels.replaceSubrange(pixel * 4..<pixel * 4 + 4, with: mark) }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
