import ProductPageKitControl
import ProductPageKitCore
import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKitCapture

@Suite struct DirectorStateTests {
    let scenes: Set<String> = ["inbox", "detail", "panel"]
    let inbox = SceneRequest(scene: "inbox")
    let detail = SceneRequest(scene: "detail", variant: "blue")

    /// An app that launched showing `inbox`, active, drawn for generation 0.
    func launched(requiresKeyWindow: Bool = false) -> DirectorState {
        var state = DirectorState(showing: inbox, requiresActiveScene: true, requiresKeyWindow: requiresKeyWindow)
        _ = state.update(active: true)
        _ = state.update(readiness: CaptureReadiness(generation: 0, conditionsMet: true))
        return state
    }

    @Test func theLaunchSceneIsReadyWithoutBeingAppliedAgain() {
        var state = launched()
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.ready(inbox)])
        #expect(state.generation == 0)
    }

    @Test func aNewSceneIsAppliedAndWaitsForItsOwnGeneration() {
        var state = launched()
        #expect(state.receive(.apply(detail), knownScenes: scenes) == [.apply(detail), .waiting(detail, [.views])])
        #expect(state.generation == 1)
        // The previous scene's views still report generation 0.
        #expect(state.update(readiness: CaptureReadiness(generation: 0, conditionsMet: true)) == [])
        #expect(state.update(readiness: CaptureReadiness(generation: 1, conditionsMet: false)) == [.waiting(detail, [.conditions])])
        #expect(state.update(readiness: CaptureReadiness(generation: 1, conditionsMet: true)) == [.ready(detail)])
        // Reported once.
        #expect(state.update(readiness: CaptureReadiness(generation: 1, conditionsMet: true)) == [])
    }

    /// A sheet or cover reports its conditions through the environment,
    /// since its preferences never reach the hierarchy under it.
    @Test func aConditionInACoverHoldsTheSceneBack() {
        var state = launched()
        _ = state.update(presentedConditionsMet: false)
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.waiting(inbox, [.conditions])])
        #expect(state.update(presentedConditionsMet: true) == [.ready(inbox)])
    }

    @MainActor
    @Test func theRegistryHoldsUntilEveryConditionIsMetOrGone() {
        let registry = ConditionRegistry()
        var changes = 0
        registry.onChange = { changes += 1 }
        let player = UUID(), artwork = UUID()
        registry.set(player, false)
        registry.set(artwork, true)
        #expect(!registry.allMet)
        registry.set(player, false)
        #expect(changes == 2)
        registry.remove(player)
        #expect(registry.allMet)
        #expect(changes == 3)
    }

    @Test func anInactiveSceneIsNotReady() {
        var state = launched()
        _ = state.update(active: false)
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.waiting(inbox, [.activeScene])])
        #expect(state.update(active: true) == [.ready(inbox)])
    }

    /// Said once for each change, so the runner brings the app forward
    /// again only when it has lost the front again.
    @Test func whatASceneWaitsForIsSaidWhenItChanges() {
        var state = DirectorState(showing: inbox, requiresActiveScene: true, requiresKeyWindow: false)
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.waiting(inbox, [.views, .activeScene])])
        #expect(state.update(readiness: CaptureReadiness(generation: 0, conditionsMet: false)) == [.waiting(inbox, [.conditions, .activeScene])])
        #expect(state.update(active: true) == [.waiting(inbox, [.conditions])])
        #expect(state.update(active: false) == [.waiting(inbox, [.conditions, .activeScene])])
        #expect(state.update(presentedConditionsMet: false) == [])
        #expect(state.update(presentedConditionsMet: true) == [])
        #expect(state.update(active: true) == [.waiting(inbox, [.conditions])])
        #expect(state.update(readiness: CaptureReadiness(generation: 0, conditionsMet: true)) == [.ready(inbox)])
        // Nothing more until the next apply.
        #expect(state.update(active: false) == [])
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.waiting(inbox, [.activeScene])])
    }

    @Test func aTestHostedViewHasNoScenePhaseToWaitFor() {
        var state = DirectorState(showing: nil, requiresActiveScene: false, requiresKeyWindow: false)
        _ = state.update(active: false)
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.apply(inbox), .waiting(inbox, [.views])])
        #expect(state.update(readiness: CaptureReadiness(generation: 1, conditionsMet: true)) == [.ready(inbox)])
    }

    @Test func aMacWaitsForItsWindowToBeKey() {
        var state = launched(requiresKeyWindow: true)
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.waiting(inbox, [.keyWindow])])
        #expect(state.update(windowKey: true) == [.ready(inbox)])
    }

    @Test func anUnknownSceneFails() {
        var state = launched()
        let unknown = SceneRequest(scene: "settings")
        #expect(state.receive(.apply(unknown), knownScenes: scenes) == [.failed(unknown, reason: "settings is not one of the app's scenes")])
        #expect(state.showing == inbox)
    }

    @Test func aThrowingApplyFailsTheRequest() {
        var state = launched()
        _ = state.receive(.apply(detail), knownScenes: scenes)
        #expect(state.applyFailed(detail, reason: "no fixture") == [.failed(detail, reason: "no fixture")])
        #expect(state.update(readiness: CaptureReadiness(generation: 1, conditionsMet: true)) == [])
    }

    /// Measured against the window, whichever way its platform counts, and
    /// sent as fractions of it from its top left, top to bottom.
    @Test func highlightsAreFractionsOfTheWindowFromItsTopLeft() {
        let size = CGSize(width: 400, height: 1000)
        let row = CGRect(x: 40, y: 500, width: 320, height: 100)
        #expect(MarkerRegistry.fraction(of: row, in: size, flipped: true) == CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1))
        #expect(MarkerRegistry.fraction(of: row, in: size, flipped: false) == CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1))
        let title = CGRect(x: 0.05, y: 0.1, width: 0.5, height: 0.05), offscreen = CGRect(x: 0.1, y: 1.2, width: 0.8, height: 0.1)
        #expect(MarkerRegistry.sorted([CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1), offscreen, title])
            == [title, CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)])
    }

    @Test func highlightsAreMeasuredForTheSceneOnScreenOnly() {
        var state = launched()
        _ = state.receive(.apply(inbox), knownScenes: scenes)
        #expect(state.receive(.photographed(inbox), knownScenes: scenes) == [.highlights(inbox)])
        #expect(state.receive(.photographed(detail), knownScenes: scenes) == [.failed(detail, reason: "detail (blue) is not on screen")])
    }

    /// A cold launch can be sent behind the home screen after it drew, and
    /// the frames then settle on the home screen: the scene says it left the
    /// front, even when it is back, and is ready again once in front.
    @Test func aSceneThatLeftTheFrontAfterReadySaysSo() {
        var state = launched()
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.ready(inbox)])
        #expect(state.update(active: false) == [])
        #expect(state.receive(.photographed(inbox), knownScenes: scenes) == [.leftFront(inbox)])
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.waiting(inbox, [.activeScene])])
        #expect(state.update(active: true) == [.ready(inbox)])
        #expect(state.receive(.photographed(inbox), knownScenes: scenes) == [.highlights(inbox)])

        _ = state.update(active: false)
        _ = state.update(active: true)
        #expect(state.receive(.photographed(inbox), knownScenes: scenes) == [.leftFront(inbox)])
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.ready(inbox)])
        #expect(state.receive(.photographed(inbox), knownScenes: scenes) == [.highlights(inbox)])
    }

    @Test func aMacWindowThatLostKeyAfterReadySaysSo() {
        var state = launched(requiresKeyWindow: true)
        _ = state.update(windowKey: true)
        #expect(state.receive(.apply(inbox), knownScenes: scenes) == [.ready(inbox)])
        _ = state.update(windowKey: false)
        _ = state.update(windowKey: true)
        #expect(state.receive(.photographed(inbox), knownScenes: scenes) == [.leftFront(inbox)])
    }

    /// Photographed before it said ready, it may not have been drawn.
    @Test func aScenePhotographedBeforeReadyHasNotStayedInFront() {
        var state = launched()
        _ = state.receive(.apply(detail), knownScenes: scenes)
        #expect(state.receive(.photographed(detail), knownScenes: scenes) == [.leftFront(detail)])
    }

    @Test func quitEndsTheSession() {
        var state = launched()
        #expect(state.receive(.quit, knownScenes: scenes) == [.quit])
        #expect(state.hasQuit)
        #expect(state.receive(.apply(detail), knownScenes: scenes) == [])
    }
}

@Suite struct ReviewSceneTests {
    /// The runner asks for a review screenshot by its kind's name, so every
    /// kind the configuration offers is a scene a test can draw.
    @Test func everyReviewScreenshotKindIsAReviewScene() {
        #expect(ReviewScreenshot.Kind.allCases.map(\.rawValue) == ReviewScene.allCases.map(\.rawValue))
    }
}
