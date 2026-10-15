import ProductPageKitCapture
import SwiftUI
import Testing
@testable import SampleApp

/// Draws the App Review screenshot when a capture run asks for it, the way an
/// app's StoreKit test would under `SKTestSession`.
@MainActor
struct ReviewScreenshotTests {
    @Test(.enabled(if: CaptureHost.test.isControlled))
    func inAppPurchases() async throws {
        let director = CaptureDirector<ReviewScene>(host: .test)
        let screen = PurchaseView().captureDirector(director) { _, _ in }
        #if os(macOS)
        let host = NSHostingView(rootView: screen)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        #else
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        #endif
        await director.untilQuit()
        #if os(macOS)
        window.orderOut(nil)
        #else
        window.isHidden = true
        #endif
    }
}
