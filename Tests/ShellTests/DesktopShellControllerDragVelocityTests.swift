import AppKit
import Testing
@testable import Shell
@testable import Rendering

// MARK: - DesktopShellController drag-velocity wiring tests
//
// Phase A.5.1 step 4: handlePetDragDidMove(to:) samples successive drag
// positions, computes screen-space velocity (px/s) between samples, and
// forwards it to `petRenderer.updateForVelocity(_:)`. handlePetDragDidEnd
// flushes `.zero` to release the squash override and resets the sampler.
//
// We can't measure the orb's GPU output from a unit test, so a
// `RecordingPetRenderer` double captures the velocity sequence and we
// assert wiring shape: counts, ordering, magnitudes, and release.

@MainActor
private final class RecordingPetRenderer: PetRenderer {
    let contentLayer: CALayer = {
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        return l
    }()
    private(set) var receivedStates: [PetEmotionState] = []
    private(set) var receivedVelocities: [CGVector] = []

    func updateForState(_ state: PetEmotionState) {
        receivedStates.append(state)
    }

    func updateForVelocity(_ velocity: CGVector) {
        receivedVelocities.append(velocity)
    }
}

@Suite("DesktopShellController — drag-velocity wiring (A.5.1 step 4)")
@MainActor
struct DesktopShellControllerDragVelocityTests {

    @Test("handlePetDragDidMove emits a velocity on the second sample onwards")
    func dragMoveEmitsVelocityFromSecondSample() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let mock = RecordingPetRenderer()
        controller.petRenderer = mock

        // First sample: only records the starting position; no velocity to
        // compute against. Must not emit a synthetic infinite-velocity spike.
        controller.handlePetDragDidMove(to: NSPoint(x: 100, y: 100))
        #expect(mock.receivedVelocities.isEmpty,
                "first drag sample must not emit a velocity (no prior anchor)")

        // Second sample: now there's a prior anchor → exactly one velocity
        // entry is emitted. We don't pin its magnitude (CACurrentMediaTime
        // dt jitter makes that flaky); we only require that the renderer
        // observed *some* velocity event for the move.
        controller.handlePetDragDidMove(to: NSPoint(x: 150, y: 100))
        #expect(mock.receivedVelocities.count == 1,
                "second drag sample must emit exactly one velocity")
    }

    @Test("handlePetDragDidEnd flushes .zero velocity and resets tracking")
    func dragEndFlushesZeroAndResets() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let mock = RecordingPetRenderer()
        controller.petRenderer = mock

        controller.handlePetDragDidMove(to: NSPoint(x: 100, y: 100))
        controller.handlePetDragDidMove(to: NSPoint(x: 150, y: 100))
        let beforeEnd = mock.receivedVelocities.count
        controller.handlePetDragDidEnd(at: NSPoint(x: 200, y: 100))

        // End must emit one .zero velocity — the "release" signal that lets
        // the orb's squash ease back to the chat-state base.
        #expect(mock.receivedVelocities.count == beforeEnd + 1,
                "drag end must emit one additional (release) velocity event")
        #expect(mock.receivedVelocities.last == .zero,
                "drag end's velocity must be .zero, got \(String(describing: mock.receivedVelocities.last))")

        // After end, a fresh drag should *not* synthesize a velocity from the
        // pre-end position — the sampler must have reset to a clean origin.
        let afterEndCount = mock.receivedVelocities.count
        controller.handlePetDragDidMove(to: NSPoint(x: 400, y: 400))
        #expect(mock.receivedVelocities.count == afterEndCount,
                "first move after drag end must not emit a velocity (sampler reset)")
    }

    @Test("dragVelocity wiring is safe when petRenderer is nil (Metal-less)")
    func dragVelocitySafeWithNilRenderer() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.petRenderer = nil

        // Must not crash — handle drag without a renderer attached, the
        // legacy behaviour (window sync + interaction event) is preserved.
        controller.handlePetDragDidMove(to: NSPoint(x: 100, y: 100))
        controller.handlePetDragDidMove(to: NSPoint(x: 150, y: 100))
        controller.handlePetDragDidEnd(at: NSPoint(x: 200, y: 100))
        #expect(controller.interactionEvents.count >= 3,
                "drag intent events must still be recorded even with no orb renderer")
    }
}
