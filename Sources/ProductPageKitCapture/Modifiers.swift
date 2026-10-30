#if DEBUG
public import SwiftUI

extension View {
    /// Puts the view under the director's control. `apply` runs on the main
    /// actor for each scene the runner asks for, and swaps whatever the views
    /// read, so the next scene needs no relaunch.
    ///
    /// The hierarchy gets a new identity for every scene applied, so view
    /// state starts fresh, unless `resettingViews` is false: an app that
    /// reaches its scenes by navigating, as a deep link would, keeps its
    /// views and holds `.captureReady` false until the navigation is done.
    /// On a Mac the window is sized from the project's configuration and
    /// kept in front.
    public func captureDirector<Scene: CaptureScene>(
        _ director: CaptureDirector<Scene>,
        resettingViews: Bool = true,
        apply: @escaping @MainActor (Scene, String?) throws -> Void
    ) -> some View {
        modifier(DirectorModifier(director: director, resettingViews: resettingViews, apply: apply))
    }

    /// Holds the ready signal back while `isReady` is false: data still
    /// loading, an image not decoded. Every condition under the director has
    /// to hold, a sheet's or a full-screen cover's included.
    public func captureReady(_ isReady: Bool) -> some View {
        modifier(ReadyModifier(isReady: isReady))
    }
}

/// A condition reaches the director twice: as a preference, which the
/// director's modifier stamps with the scene generation it was drawn for, and
/// through the environment, which reaches into sheets and covers, where no
/// preference goes.
private struct ReadyModifier: ViewModifier {
    let isReady: Bool
    @Environment(\.captureConditions) private var conditions
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .preference(key: CaptureReadinessKey.self, value: CaptureReadiness(generation: nil, conditionsMet: isReady))
            .onChange(of: isReady, initial: true) { _, isReady in conditions?.set(id, isReady) }
            .onDisappear { conditions?.remove(id) }
    }
}

/// Every `.captureReady` condition on screen, by the view that holds it.
@MainActor
final class ConditionRegistry {
    private var conditions: [UUID: Bool] = [:]
    var onChange: () -> Void = {}

    var allMet: Bool { !conditions.values.contains(false) }

    func set(_ id: UUID, _ isReady: Bool) {
        guard conditions[id] != isReady else { return }
        conditions[id] = isReady
        onChange()
    }

    func remove(_ id: UUID) {
        guard conditions.removeValue(forKey: id) != nil else { return }
        onChange()
    }
}

extension EnvironmentValues {
    @Entry var captureConditions: ConditionRegistry?

    /// True under a director a runner is driving. A view that loops on purpose,
    /// such as a pulse, holds still while it is: a scene that never stops
    /// moving never passes the runner's check for two matching frames.
    @Entry public var isCapturingScreenshots = false
}

struct CaptureReadinessKey: PreferenceKey {
    static let defaultValue = CaptureReadiness(generation: nil, conditionsMet: true)

    static func reduce(value: inout CaptureReadiness, nextValue: () -> CaptureReadiness) {
        let next = nextValue()
        value = CaptureReadiness(generation: value.generation ?? next.generation,
                                 conditionsMet: value.conditionsMet && next.conditionsMet)
    }
}

private struct DirectorModifier<Scene: CaptureScene>: ViewModifier {
    let director: CaptureDirector<Scene>
    let resettingViews: Bool
    let apply: @MainActor (Scene, String?) throws -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let generation = director.generation
        let capturing = director.isCapturing
        content
            .withoutAnimations(capturing)
            .environment(\.isCapturingScreenshots, capturing)
            .environment(\.captureHighlights, director.highlights)
            .environment(\.captureConditions, director.conditions)
            .environment(\.captureMoving, director.moving)
            .id(resettingViews ? generation : 0)
            // Stamped here, so a condition that has not been redrawn for the
            // new scene cannot pass for it.
            .transformPreference(CaptureReadinessKey.self) { $0.generation = generation }
            .onPreferenceChange(CaptureReadinessKey.self) { [director] readiness in
                MainActor.assumeIsolated { director.update(readiness: readiness) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                director.update(active: phase == .active)
            }
            .background(WindowReader { director.attach($0) })
            .onAppear { director.start(apply: apply) }
    }
}

extension View {
    /// Every change lands at once while `on`: a fade or a slide only holds
    /// back the check for two matching frames.
    func withoutAnimations(_ on: Bool) -> some View {
        transaction { transaction in
            guard on else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

/// Hands over the window a view is placed in.
#if os(macOS)
private struct WindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(found: found) }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let found: @MainActor (NSWindow) -> Void

        init(found: @escaping @MainActor (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
#else
private struct WindowReader: UIViewRepresentable {
    let found: @MainActor (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView { ReaderView(found: found) }
    func updateUIView(_ view: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        let found: @MainActor (UIWindow) -> Void

        init(found: @escaping @MainActor (UIWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { found(window) }
        }
    }
}
#endif
#endif
