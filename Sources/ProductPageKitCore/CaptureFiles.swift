public import Foundation

/// Files the app reads over loopback HTTP while it is captured, such as a
/// film its player plays, served at `http://127.0.0.1:<port>/<name>`. A
/// theme can draw from them too: a still through `FrameSource.file`, a
/// movie through `VideoScreen.movie`.
public protocol CaptureFiles: Sendable {
    /// The port the app expects them on.
    var port: UInt16 { get }
    /// Every file's name.
    var names: [String] { get }
    /// Makes sure each named file is in `directory`, which the cache keeps
    /// between runs, so a file already there need not be made again.
    func prepare(in directory: URL, log: @escaping @Sendable (String) -> Void) async throws
}
