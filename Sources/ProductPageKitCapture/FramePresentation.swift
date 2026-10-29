#if DEBUG
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Runs work once what the app has drawn so far is on screen: after a number
/// of display refreshes, which cannot come before the main thread commits the
/// frame it is drawing.
@MainActor
final class FramePresentation: NSObject {
    private var remaining: Int
    private var then: (@MainActor () -> Void)?

    private init(frames: Int, then: @escaping @MainActor () -> Void) {
        remaining = frames
        self.then = then
    }

    /// Calls `then` after `frames` refreshes. The display link holds the
    /// presentation until it is invalidated.
    static func after(frames: Int = 2, then: @escaping @MainActor () -> Void) {
        let presentation = FramePresentation(frames: frames, then: then)
        #if os(macOS)
        // No screen, as in a test run without a display: nothing waits to be shown.
        guard let link = NSScreen.main?.displayLink(target: presentation, selector: #selector(tick)) else { return then() }
        #else
        let link = CADisplayLink(target: presentation, selector: #selector(tick))
        #endif
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        remaining -= 1
        guard remaining <= 0, let then else { return }
        self.then = nil
        link.invalidate()
        then()
    }
}
#endif
