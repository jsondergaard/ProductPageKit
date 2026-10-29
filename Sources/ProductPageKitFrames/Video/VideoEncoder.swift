public import AVFoundation
public import CoreImage
public import Foundation

/// Writes frames as an H.264 MP4, the codec App Store Connect takes for
/// header and search videos.
public enum VideoEncoder {
    /// Writes `frames` frames of `size` at `fps`, asking `frame` for each by
    /// its index.
    public static func encode(to url: URL, size: CGSize, fps: Int, frames: Int,
                              frame: (Int) throws -> CIImage) async throws {
        let width = Int(size.width), height = Int(size.height)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                // Generous: App Store Connect re-encodes, and grain over dark
                // gradients is what a lean first encode loses.
                AVVideoAverageBitRateKey: Int(Double(width * height * fps) * 0.16),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: width, height: height)))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        guard let pool = receiver.pixelBufferPool else { throw VideoError.noBuffers }
        let bounds = CGRect(origin: .zero, size: size)
        let context = CIContext(options: [.workingColorSpace: Canvas.colorSpace, .outputColorSpace: Canvas.colorSpace])
        for index in 0..<frames {
            try Task.checkCancellation()
            let buffer = try pool.makeMutablePixelBuffer()
            // Core Image autoreleases each frame's intermediate bitmaps, and a
            // task's loop never drains them on its own.
            try autoreleasepool {
                let image = try frame(index).cropped(to: bounds)
                buffer.withUnsafeBuffer { context.render(image, to: $0, bounds: bounds, colorSpace: Canvas.colorSpace) }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(index), timescale: CMTimeScale(fps)))
        }
        receiver.finish()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? VideoError.unfinished }
    }
}

public enum VideoError: Error, CustomStringConvertible {
    case noBuffers
    case unfinished

    public var description: String {
        switch self {
        case .noBuffers: "the video writer gave no pixel buffers"
        case .unfinished: "the video writer did not finish"
        }
    }
}
