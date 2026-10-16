#if DEBUG
import ProductPageKitControl

/// What the views report about readiness: whether every `.captureReady`
/// condition holds, for the scene generation they were drawn for.
struct CaptureReadiness: Hashable, Sendable {
    /// Nil until the director's modifier stamps it.
    var generation: Int?
    var conditionsMet: Bool
}

/// The director's rules, without SwiftUI or a socket, so each transition is
/// tested on its own.
///
/// Every `apply` of a new scene starts a generation. A scene is ready when the
/// views drawn for that generation report every condition met, as does every
/// condition on screen, a sheet's or cover's included, the scene is active,
/// and on a Mac its window is key. Ready is reported once per `apply`; until
/// then, what the scene waits for is reported whenever it changes.
struct DirectorState: Equatable {
    enum Effect: Equatable {
        /// Show this scene: set it as current and run the app's closure.
        case apply(SceneRequest)
        case ready(SceneRequest)
        case waiting(SceneRequest, [Waiting.Reason])
        /// Report where the scene's highlights are.
        case highlights(SceneRequest)
        case failed(SceneRequest, reason: String)
        case quit
    }

    /// What the app is showing.
    private(set) var showing: SceneRequest?
    private(set) var generation = 0
    /// Asked for and not yet reported.
    private(set) var pending: SceneRequest?
    /// What `pending` was last reported waiting for.
    private var reported: [Waiting.Reason]?
    private(set) var hasQuit = false
    private var readiness = CaptureReadiness(generation: nil, conditionsMet: true)
    private var presentedConditionsMet = true
    private var isActive: Bool
    private var isWindowKey: Bool
    private let requiresActiveScene: Bool

    /// - Parameters:
    ///   - requiresActiveScene: false for a view a test hosts, which has no
    ///     scene phase.
    ///   - requiresKeyWindow: true on a Mac, where an inactive window is
    ///     drawn with grey controls.
    init(showing: SceneRequest?, requiresActiveScene: Bool, requiresKeyWindow: Bool) {
        self.showing = showing
        isActive = !requiresActiveScene
        isWindowKey = !requiresKeyWindow
        self.requiresActiveScene = requiresActiveScene
    }

    mutating func receive(_ message: RunnerMessage, knownScenes: Set<String>) -> [Effect] {
        guard !hasQuit else { return [] }
        switch message {
        case .apply(let request):
            guard knownScenes.contains(request.scene) else {
                return [.failed(request, reason: "\(request.scene) is not one of the app's scenes")]
            }
            pending = request
            reported = nil
            var effects: [Effect] = []
            if showing != request {
                showing = request
                generation += 1
                effects.append(.apply(request))
            }
            return effects + evaluate()
        case .highlights(let request):
            return showing == request ? [.highlights(request)] : [.failed(request, reason: "\(request) is not on screen")]
        case .export, .taken:
            // The director's component exporter answers these.
            return []
        case .quit:
            hasQuit = true
            pending = nil
            return [.quit]
        }
    }

    /// The app's closure threw.
    mutating func applyFailed(_ request: SceneRequest, reason: String) -> [Effect] {
        guard pending == request else { return [] }
        pending = nil
        return [.failed(request, reason: reason)]
    }

    mutating func update(readiness: CaptureReadiness) -> [Effect] {
        self.readiness = readiness
        return evaluate()
    }

    /// Every condition on screen, which reaches into sheets and covers where
    /// the hierarchy's own report does not.
    mutating func update(presentedConditionsMet: Bool) -> [Effect] {
        self.presentedConditionsMet = presentedConditionsMet
        return evaluate()
    }

    mutating func update(active: Bool) -> [Effect] {
        guard requiresActiveScene else { return [] }
        isActive = active
        return evaluate()
    }

    mutating func update(windowKey: Bool) -> [Effect] {
        isWindowKey = windowKey
        return evaluate()
    }

    private mutating func evaluate() -> [Effect] {
        guard let pending else { return [] }
        let reasons = waitingFor
        guard reasons.isEmpty else {
            guard reasons != reported else { return [] }
            reported = reasons
            return [.waiting(pending, reasons)]
        }
        self.pending = nil
        return [.ready(pending)]
    }

    /// What the scene asked for waits for. The views' own conditions count
    /// once they are drawn for this generation.
    private var waitingFor: [Waiting.Reason] {
        var reasons: [Waiting.Reason] = []
        if readiness.generation != generation { reasons.append(.views) }
        if (readiness.generation == generation && !readiness.conditionsMet) || !presentedConditionsMet { reasons.append(.conditions) }
        if !isActive { reasons.append(.activeScene) }
        if !isWindowKey { reasons.append(.keyWindow) }
        return reasons
    }
}
#endif
