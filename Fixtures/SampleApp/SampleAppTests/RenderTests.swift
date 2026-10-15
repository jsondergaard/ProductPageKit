import ProductPageKitCapture
import SwiftUI
import Testing

/// A screen no scene of the app draws, put up by a test the way a UI test
/// drives the system: a banner in the colour the variant names, beside a
/// spinner that never stops, which the test says moves.
@MainActor
struct RenderTests {
    enum Render: String, CaptureScene {
        case banner
    }

    @Test(.enabled(if: CaptureHost.test.isControlled))
    func banner() async throws {
        let director = CaptureDirector<Render>(host: .test)
        var shown: Window?
        await director.direct { _, variant in
            shown?.close()
            let window = try Window(Banner(colour: variant == "red" ? .red : .blue))
            shown = window
            // The spinner's half of the screen.
            return CaptureShown(moving: [CGRect(x: 0, y: 0.5, width: 1, height: 0.5)])
        }
        shown?.close()
    }
}

private struct Banner: View {
    let colour: Color

    var body: some View {
        VStack(spacing: 0) {
            colour.overlay(Text("Banner").font(.largeTitle).foregroundStyle(.white))
            TimelineView(.animation) { context in
                Rectangle()
                    .fill(.white)
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            }
        }
        .frame(minWidth: 400, minHeight: 400)
    }
}

/// A window of the test host's own, key and in front.
@MainActor
private final class Window {
    #if os(macOS)
    private let window: NSWindow

    init(_ view: some View) throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.orderOut(nil) }
    #else
    private let window: UIWindow

    init(_ view: some View) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    func close() { window.isHidden = true }
    #endif
}
