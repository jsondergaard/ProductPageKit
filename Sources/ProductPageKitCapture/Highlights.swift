#if DEBUG
import CoreGraphics
public import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    /// Marks the view, while `isOn`, as one a frame theme may draw attention
    /// to: the runner records where it is with the capture, and the theme
    /// gets its rect as `FramedShot.highlights`. `isOn` picks one row of a
    /// list.
    public func captureHighlight(_ isOn: Bool = true) -> some View {
        modifier(MarkerModifier(isOn: isOn, registry: \.captureHighlights))
    }

    /// Marks the view, while `isOn`, as one that moves on purpose, such as a
    /// video playing: the runner's check for two matching frames leaves it
    /// out, and the scene counts as settled when everything else is.
    public func captureMoving(_ isOn: Bool = true) -> some View {
        modifier(MarkerModifier(isOn: isOn, registry: \.captureMoving))
    }
}

extension EnvironmentValues {
    @Entry var captureHighlights: MarkerRegistry?
    @Entry var captureMoving: MarkerRegistry?
}

/// Views marked for the runner, measured against their window when a scene
/// is ready. A platform view rather than a geometry reader, which a list row
/// measures against its own cell.
@MainActor
final class MarkerRegistry {
    private let markers = NSHashTable<CaptureMarker>.weakObjects()

    fileprivate func add(_ marker: CaptureMarker) {
        markers.add(marker)
    }

    #if os(macOS)
    /// As fractions of `window`, title bar included, from its top left; top
    /// to bottom, then leading to trailing.
    func fractions(in window: NSWindow) -> [CGRect] {
        Self.sorted(markers.allObjects.filter { $0.isOn && $0.window === window && !$0.isHiddenOrHasHiddenAncestor }.map {
            Self.fraction(of: $0.convert($0.bounds, to: nil), in: window.frame.size, flipped: false)
        })
    }
    #else
    /// As fractions of each marker's window, which fills the screen.
    func fractions() -> [CGRect] {
        Self.sorted(markers.allObjects.compactMap { marker in
            guard marker.isOn, let window = marker.window, marker.isShowing else { return nil }
            return Self.fraction(of: marker.convert(marker.bounds, to: nil), in: window.bounds.size, flipped: true)
        })
    }
    #endif

    /// `rect` in a window `size` big, from its top left. AppKit's windows
    /// count from the bottom; `flipped` ones, UIKit's, from the top.
    nonisolated static func fraction(of rect: CGRect, in size: CGSize, flipped: Bool) -> CGRect {
        CGRect(x: rect.minX / size.width, y: (flipped ? rect.minY : size.height - rect.maxY) / size.height,
               width: rect.width / size.width, height: rect.height / size.height)
    }

    nonisolated static func sorted(_ rects: [CGRect]) -> [CGRect] {
        rects.filter { $0.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }
}

#if os(macOS)
final class CaptureMarker: NSView {
    var isOn = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
final class CaptureMarker: UIView {
    var isOn = false

    /// Neither it nor anything it is in hidden: a tab not selected keeps
    /// its views in the window.
    var isShowing: Bool {
        sequence(first: self as UIView, next: \.superview).allSatisfy { !$0.isHidden && $0.alpha > 0.01 }
    }
}
#endif

private struct MarkerModifier: ViewModifier {
    let isOn: Bool
    let registry: KeyPath<EnvironmentValues, MarkerRegistry?>
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        content.background {
            if let registry = environment[keyPath: registry] { MarkerView(isOn: isOn, registry: registry) }
        }
    }
}

#if os(macOS)
private struct MarkerView: NSViewRepresentable {
    let isOn: Bool
    let registry: MarkerRegistry

    func makeNSView(context: Context) -> CaptureMarker {
        let marker = CaptureMarker()
        registry.add(marker)
        return marker
    }

    func updateNSView(_ marker: CaptureMarker, context: Context) {
        marker.isOn = isOn
    }
}
#else
private struct MarkerView: UIViewRepresentable {
    let isOn: Bool
    let registry: MarkerRegistry

    func makeUIView(context: Context) -> CaptureMarker {
        let marker = CaptureMarker()
        marker.isUserInteractionEnabled = false
        registry.add(marker)
        return marker
    }

    func updateUIView(_ marker: CaptureMarker, context: Context) {
        marker.isOn = isOn
    }
}
#endif
#endif
