import CoreGraphics
import ProductPageKitControl
import ProductPageKitTestSupport
import Testing
@testable import ProductPageKitCapture

@Suite struct PictureMatchTests {
    @Test func picturesMatchWithinTheTolerance() {
        let match = PictureMatch(tolerance: 0.001)
        #expect(match.matches(testImage(), testImage()))
        #expect(match.matches(testImage(), testImage(marked: 10)))
        #expect(!match.matches(testImage(), testImage(marked: 11)))
        #expect(!match.matches(testImage(), testImage(width: 101)))
    }

    /// Glass re-samples its backdrop on every drawing and moves its edges by
    /// a level or two; that is the same colour, however many pixels it
    /// touches, and one level more is not.
    @Test func aChannelMovedByTheThresholdIsTheSameColour() {
        let match = PictureMatch(tolerance: 0)
        // The test image is grey at half opacity, every channel 128.
        #expect(match.matches(testImage(), testImage(marked: 5000, mark: [126, 127, 128, 126])))
        #expect(!match.matches(testImage(), testImage(marked: 1, mark: [125, 128, 128, 128])))
    }

    /// A video playing moves on purpose; the rest of the picture decides.
    @Test func whatMovesOnPurposeIsLeftOut() {
        let match = PictureMatch(tolerance: 0)
        // The first 500 pixels are the top five rows.
        #expect(!match.matches(testImage(), testImage(marked: 500)))
        #expect(match.matches(testImage(), testImage(marked: 500), ignoring: [CGRect(x: 0, y: 0, width: 1, height: 0.05)]))
        #expect(!match.matches(testImage(), testImage(marked: 600), ignoring: [CGRect(x: 0, y: 0, width: 1, height: 0.05)]))
    }
}

@MainActor @Suite struct ComponentStillnessTests {
    /// Draws `drawings` in turn, then the last one again, counting draws.
    final class Drawer {
        let drawings: [CGImage]
        var drawn = 0
        init(_ drawings: [CGImage]) { self.drawings = drawings }
        func draw() -> CGImage {
            defer { drawn += 1 }
            return drawings[min(drawn, drawings.count - 1)]
        }
    }

    /// Two drawings whose glass edges moved by a level or two are the same
    /// picture, so the component is taken at the second.
    @Test func glassNoiseHoldsStill() async throws {
        let noisy = testImage(marked: 3000, mark: [126, 127, 126, 128])
        let drawer = Drawer([testImage(), noisy, testImage()])
        let drawing = try await ComponentExporter.holdStill(draw: drawer.draw)
        #expect(drawer.drawn == 2)
        #expect(drawing === noisy)
    }

    @Test func aChangingComponentIsTakenOnceItSettles() async throws {
        let settled = testImage(marked: 4000)
        let drawer = Drawer([testImage(marked: 1000), testImage(marked: 2000), settled])
        let drawing = try await ComponentExporter.holdStill(draw: drawer.draw)
        #expect(drawer.drawn == 4)
        #expect(drawing === settled)
    }

    @Test func aComponentThatNeverSettlesFailsAtTheDeadline() async throws {
        let drawer = Drawer((0..<1000).map { testImage(marked: $0 % 2 == 0 ? 0 : 5000, mark: [125, 125, 125, 128]) })
        await #expect {
            try await ComponentExporter.holdStill(for: .milliseconds(300), draw: drawer.draw)
        } throws: { error in
            guard case ComponentError.unstable = error else { return false }
            return true
        }
        #expect(drawer.drawn > 2)
    }
}
