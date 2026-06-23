import RuntimeBridge
import Testing
@testable import Orchestrator

@Test("Behavior engine reports idle when render state has no snow and no contact")
func behaviorEngineReportsIdleWhenRenderStateHasNoSnowAndNoContact() {
    let engine = BehaviorEngine()
    let state = RenderState(
        petPositionX: 0,
        petPositionY: 0,
        petRotation: 0,
        particleCount: 0,
        contactCount: 0,
        isSnowEnabled: false
    )

    #expect(engine.behavior(for: state) == .idle)
}

@Test("Behavior engine reports tracking when render state reports cursor contact")
func behaviorEngineReportsTrackingWhenRenderStateReportsCursorContact() {
    let engine = BehaviorEngine()
    let state = RenderState(
        petPositionX: 0,
        petPositionY: 0,
        petRotation: 0,
        particleCount: 0,
        contactCount: 1,
        isSnowEnabled: false
    )

    #expect(engine.behavior(for: state) == .tracking)
}

@Test("Behavior engine reports snowing when snow is enabled regardless of contact")
func behaviorEngineReportsSnowingWhenSnowIsEnabledRegardlessOfContact() {
    let engine = BehaviorEngine()
    let snowingNoContact = RenderState(
        petPositionX: 0,
        petPositionY: 0,
        petRotation: 0,
        particleCount: 5,
        contactCount: 0,
        isSnowEnabled: true
    )
    let snowingWithContact = RenderState(
        petPositionX: 0,
        petPositionY: 0,
        petRotation: 0,
        particleCount: 5,
        contactCount: 3,
        isSnowEnabled: true
    )

    #expect(engine.behavior(for: snowingNoContact) == .snowing)
    #expect(engine.behavior(for: snowingWithContact) == .snowing)
}
