#if os(macOS)
import Foundation
import Testing
@testable import ProductPageKitCapture

@MainActor @Suite struct FramePresentationTests {
    /// Ready waits for the screen to refresh, so it never goes out in the
    /// same update that drew the scene.
    @Test func runsAfterTheScreenRefreshesNotStraightAway() async {
        var ran = false
        FramePresentation.after { ran = true }
        #expect(!ran)
        let deadline = Date().addingTimeInterval(2)
        while !ran, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(ran)
    }
}
#endif
