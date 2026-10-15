#if DEBUG
public import CoreGraphics
import ProductPageKitControl
public import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A view the app exports on its own, laid out at a width, for a frame theme
/// to compose: the app's real, localized interface rather than a crop of a
/// screenshot. Its views hold `.captureReady` false until they have loaded,
/// as a scene's do.
public struct CaptureComponent {
    public enum Height: Sendable {
        /// The height the view asks for at its width.
        case fitting
        /// The whole content of the first scroll view inside, for a list
        /// that would otherwise take the height it is offered.
        case scrollContent
        /// For a view that fills whatever height it is offered.
        case fixed(CGFloat)
    }

    /// In points.
    public let width: CGFloat
    public let height: Height
    /// Pixels per point. A simulator's screen scale unless more is asked for,
    /// for a component a frame shows larger than the device does. A Mac
    /// draws at its display's.
    public let scale: CGFloat?
    let view: AnyView
    let finish: @MainActor () async -> Void

    /// - Parameter finish: puts back whatever making the component changed,
    ///   such as a model put in one of its states, once it is exported.
    public init<Content: View>(width: CGFloat, height: Height = .fitting, scale: CGFloat? = nil,
                               finish: @escaping @MainActor () async -> Void = {}, @ViewBuilder content: () -> Content) {
        self.width = width
        self.height = height
        self.scale = scale
        self.finish = finish
        view = AnyView(content())
    }
}

/// A component the runner asks for: its name, the state to put it in, and
/// the variant of the app it is drawn in.
public struct CaptureComponentRequest: Hashable, Sendable {
    public let name: String
    public let state: String?
    public let variant: String?

    init(_ request: ComponentRequest) {
        name = request.name
        state = request.state
        variant = request.variant
    }
}

extension View {
    /// Answers the runner's requests for components. `make` builds the one
    /// asked for, in its state and variant, or returns nil for a name the
    /// app does not have.
    public func captureComponents<Scene: CaptureScene>(
        _ director: CaptureDirector<Scene>,
        make: @escaping @MainActor (CaptureComponentRequest) async throws -> CaptureComponent?
    ) -> some View {
        onAppear { director.components.make = make }
    }
}

/// Draws the components the runner asks for, one at a time.
@MainActor
final class ComponentExporter {
    var make: (@MainActor (CaptureComponentRequest) async throws -> CaptureComponent?)?
    private var send: (AppMessage) -> Void = { _ in }
    private var taken: CheckedContinuation<Void, Never>?
    private var queue: [ComponentRequest] = []
    private var isExporting = false
    private let appearance: CaptureAppearance?
    #if os(macOS)
    /// One window for every component, which outlives them: a window freed
    /// with a display pass still scheduled has SwiftUI update freed state.
    private lazy var stage: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.level = .floating
        if let appearance { window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) }
        return window
    }()
    #endif

    init(appearance: CaptureAppearance?) {
        self.appearance = appearance
    }

    func connect(_ send: @escaping (AppMessage) -> Void) {
        self.send = send
    }

    func receive(_ message: RunnerMessage) {
        switch message {
        case .export(let request):
            queue.append(request)
            guard !isExporting else { return }
            isExporting = true
            Task { await drain() }
        case .taken:
            taken?.resume()
            taken = nil
        default:
            break
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            do {
                guard let component = try await make?(CaptureComponentRequest(request)) else {
                    send(.exportFailed(ComponentFailure(request, reason: "the app has no component \(request.name)")))
                    continue
                }
                try await export(component, as: request)
                await component.finish()
            } catch {
                send(.exportFailed(ComponentFailure(request, reason: String(describing: error))))
            }
        }
        isExporting = false
    }

    /// Lays a component out until its size settles and every condition in it
    /// holds, or fails it after the deadline.
    private func settle(_ host: ComponentHost, layout: () -> Void) async throws {
        for _ in 0..<Self.attempts {
            layout()
            if host.conditionsMet { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ComponentError.notReady
    }

    /// Half a minute, a quarter of a second at a time.
    static let attempts = 120

    #if os(macOS)
    /// Shows the component in a window of its own, where the window server
    /// draws its glass, over black and then over white, for the runner to
    /// photograph each.
    private func export(_ component: CaptureComponent, as request: ComponentRequest) async throws {
        let host = ComponentHost()
        let view = NSHostingView(rootView: host.wrap(component.view))
        view.appearance = stage.appearance
        view.sizingOptions = [.intrinsicContentSize]
        view.translatesAutoresizingMaskIntoConstraints = false
        let window = stage
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let topLeft = NSPoint(x: screen.minX, y: screen.maxY)
        await onRunLoop {
            window.contentView?.addSubview(view)
            if let container = window.contentView {
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    view.topAnchor.constraint(equalTo: container.topAnchor),
                    view.widthAnchor.constraint(equalToConstant: component.width),
                ])
            }
            window.setFrameTopLeftPoint(topLeft)
            window.orderFrontRegardless()
        }
        defer { view.removeFromSuperview() }
        try await settle(host) {
            Self.layOut(view, in: window, component: component, topLeft: topLeft)
        }
        for backdrop in [ShownComponent.Backdrop.black, .white] {
            await onRunLoop {
                    window.backgroundColor = backdrop == .black ? .black : .white
                window.displayIfNeeded()
            }
            await withCheckedContinuation { continuation in
                taken = continuation
                send(.showing(ShownComponent(request, window: WindowInfo(number: window.windowNumber, frame: window.frame),
                                             backdrop: backdrop)))
            }
        }
    }

    private static func layOut(_ view: NSHostingView<AnyView>, in window: NSWindow, component: CaptureComponent, topLeft: NSPoint) {
        // An unbounded height is taken literally by a view that fills its
        // space, so the height comes from Auto Layout at a generous one.
        window.setContentSize(CGSize(width: component.width, height: 1_200))
        window.contentView?.layoutSubtreeIfNeeded()
        var height: CGFloat = switch component.height {
        case .fitting: view.fittingSize.height
        case .scrollContent: view.firstScrollView?.documentView?.frame.height ?? view.fittingSize.height
        case .fixed(let height): height
        }
        // A window refuses a frame that is not finite.
        height = min(max(1, height.rounded(.up)), 20_000)
        window.setContentSize(CGSize(width: component.width, height: height))
        window.setFrameTopLeftPoint(topLeft)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// AppKit and SwiftUI layout run from a plain main-queue block, as AppKit
    /// runs them, and never inside a Swift task, where a synchronous SwiftUI
    /// update fails its isolation checks.
    private func onRunLoop(_ body: @escaping @MainActor () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { body() }
                continuation.resume()
            }
        }
    }
    #else
    /// Draws the component in process, over the app's own window so glass
    /// samples what it would in the app, until two drawings in a row match.
    private func export(_ component: CaptureComponent, as request: ComponentRequest) async throws {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { throw ComponentError.noWindow }
        let stage = UIView(frame: window.bounds)
        stage.backgroundColor = window.traitCollection.userInterfaceStyle == .dark ? .black : .white
        window.addSubview(stage)
        defer { stage.removeFromSuperview() }
        let host = ComponentHost()
        let controller = UIHostingController(rootView: host.wrap(component.view))
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        stage.addSubview(controller.view)
        try await settle(host) { Self.layOut(controller, on: stage, component: component) }
        let scale = max(window.screen.scale, component.scale ?? 0)
        var previous: Data?
        for _ in 0..<Self.attempts {
            let png = try Self.draw(controller.view, scale: scale)
            if png == previous {
                send(.exported(ExportedComponent(request, png: png)))
                return
            }
            previous = png
            try await Task.sleep(for: .milliseconds(250))
            Self.layOut(controller, on: stage, component: component)
        }
        throw ComponentError.unstable
    }

    private static func layOut(_ controller: UIHostingController<AnyView>, on stage: UIView, component: CaptureComponent) {
        let proposed = if case .fixed(let height) = component.height { height } else { CGFloat.greatestFiniteMagnitude }
        let fitting = controller.sizeThatFits(in: CGSize(width: component.width, height: proposed))
        var size = CGSize(width: min(component.width, fitting.width.rounded(.up)), height: fitting.height.rounded(.up))
        switch component.height {
        case .fitting:
            break
        case .fixed(let height):
            size.height = height
        case .scrollContent:
            size = CGSize(width: component.width, height: max(size.height, stage.bounds.height))
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.layoutIfNeeded()
            if let scroll = controller.view.firstScrollView {
                size.height = (scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom)
                    .rounded(.up)
            }
        }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
    }

    private static func draw(_ view: UIView, scale: CGFloat) throws -> Data {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { throw ComponentError.empty }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let png = image.pngData() else { throw ComponentError.empty }
        return png
    }
    #endif
}

/// Whether every `.captureReady` condition inside a component holds. A
/// component has no scene generation, so only its conditions count.
@MainActor
final class ComponentHost {
    var conditionsMet = true

    func wrap(_ view: AnyView) -> AnyView {
        AnyView(view
            .environment(\.isCapturingScreenshots, true)
            .onPreferenceChange(CaptureReadinessKey.self) { [weak self] readiness in
                MainActor.assumeIsolated { self?.conditionsMet = readiness.conditionsMet }
            })
    }
}

enum ComponentError: Error, CustomStringConvertible {
    case noWindow
    case notReady
    case unstable
    case empty

    var description: String {
        switch self {
        case .noWindow: "the app has no key window to draw the component over"
        case .notReady: "the component's .captureReady conditions did not all hold within 30 seconds"
        case .unstable: "the component kept changing for 30 seconds; hold .captureReady false until it settles"
        case .empty: "the component laid out with no size"
        }
    }
}

#if os(macOS)
private extension NSView {
    var firstScrollView: NSScrollView? {
        if let scroll = self as? NSScrollView { return scroll }
        return subviews.lazy.compactMap(\.firstScrollView).first
    }
}
#else
private extension UIView {
    var firstScrollView: UIScrollView? {
        if let scroll = self as? UIScrollView { return scroll }
        return subviews.lazy.compactMap(\.firstScrollView).first
    }
}
#endif
#endif
