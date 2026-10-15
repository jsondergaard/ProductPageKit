public import AVFoundation
public import CoreImage
import Synchronization

/// A movie read forward one frame at a time, tone-mapped to the SDR the
/// video is encoded in, for a device's screen to play.
public final class MovieReel: Sendable {
    /// The frame at the start, which stands in for the movie where it is
    /// still, such as the light its screen casts.
    public let poster: CGImage
    private let start: Double
    private let state: Mutex<State>

    private struct State: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
        var shown: CIImage?
        var upcoming: (seconds: Double, image: CIImage)?
    }

    /// Opens `url` to play `seconds` from `start`.
    public init(_ url: URL, from start: Double, seconds: Double) async throws {
        let asset = AVURLAsset(url: url)
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await asset.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = AVVideoComposition(configuration: configuration)
        reader.add(output)
        // A second past the end, so the frame shown at the last moment is
        // read, and no further than the movie goes.
        let duration = try await asset.load(.duration).seconds
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: min(seconds + 1, duration - start), preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? MovieError.unreadable(url) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        poster = try await generator.image(at: CMTime(seconds: start, preferredTimescale: 600)).image
        self.start = start
        state = Mutex(State(reader: reader, output: output))
    }

    /// The frame on screen `seconds` after the start. Forward only: a time
    /// before the last one asked for gets that one's frame.
    public func frame(at seconds: Double) -> CIImage? {
        let target = start + seconds
        return state.withLock { state in
            while true {
                if state.upcoming == nil, let sample = state.output.copyNextSampleBuffer(),
                   let buffer = CMSampleBufferGetImageBuffer(sample) {
                    state.upcoming = (CMSampleBufferGetPresentationTimeStamp(sample).seconds, CIImage(cvImageBuffer: buffer))
                }
                guard let next = state.upcoming, next.seconds <= target + 1e-6 else { break }
                state.shown = next.image
                state.upcoming = nil
            }
            return state.shown ?? state.upcoming?.image
        }
    }
}

public enum MovieError: Error, CustomStringConvertible {
    case unreadable(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): "could not read \(url.path) as a movie"
        }
    }
}
