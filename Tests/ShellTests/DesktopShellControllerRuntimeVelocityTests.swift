import AppKit
import Testing
@testable import Shell
@testable import Rendering

// MARK: - DesktopShellController runtime-velocity wiring tests
//
// Phase A.5.1 step 4 (runtime side): `applyRuntimePetVelocity(position:now:)`
// is called by `MinimalAppDelegate.advanceRuntimeFrame` after the Rust runtime
// hands back a new `pet_pose`. Rust doesn't surface a velocity field, so the
// shell derives it Swift-side from successive position samples and feeds it
// to `petRenderer.updateForVelocity(_:)` so the orb squashes during physics-
// driven motion (bounce / free-fall / wall collision), not only user drag.
//
// We can't introspect orb GPU output from a unit test, so a
// `RecordingPetRenderer` double captures the velocity sequence and we assert
// wiring shape: first-frame suppression, second-frame emission, idle-
// threshold flushing to `.zero`.

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

@Suite("DesktopShellController — runtime-velocity wiring (A.5.1 step 4 / runtime)")
@MainActor
struct DesktopShellControllerRuntimeVelocityTests {

    @Test("first applyRuntimePetVelocity does not emit a velocity (no anchor)")
    func firstRuntimeFrameSuppressed() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let mock = RecordingPetRenderer()
        controller.petRenderer = mock

        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 100, y: 100),
            now: 1.0
        )

        #expect(mock.receivedVelocities.isEmpty,
                "first runtime frame must only record baseline, not emit a velocity")
    }

    @Test("second applyRuntimePetVelocity emits velocity with correct magnitude+direction")
    func secondRuntimeFrameEmitsVelocity() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let mock = RecordingPetRenderer()
        controller.petRenderer = mock

        // Δt = 1/60 s, Δx = 6 → vx = 360 px/s. Above the 5 px/s idle threshold,
        // so we expect a non-zero velocity emission.
        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 100, y: 100),
            now: 1.0
        )
        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 106, y: 100),
            now: 1.0 + (1.0 / 60.0)
        )

        #expect(mock.receivedVelocities.count == 1,
                "second runtime frame must emit exactly one velocity")
        let v = mock.receivedVelocities.last ?? .zero
        #expect(abs(v.dx - 360.0) < 0.5,
                "vx should be ≈ Δx/Δt = 360 px/s, got \(v.dx)")
        #expect(abs(v.dy) < 0.5,
                "vy should be ≈ 0 (no Y motion), got \(v.dy)")
    }

    @Test("near-zero pet motion flushes .zero so orb eases to state base")
    func idleMotionFlushesZeroVelocity() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let mock = RecordingPetRenderer()
        controller.petRenderer = mock

        // Δx = 0.05 over 1/60 s → |v| ≈ 3 px/s, below the 5 px/s idle
        // threshold. Should emit `.zero`, not the tiny jitter velocity.
        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 200, y: 200),
            now: 2.0
        )
        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 200.05, y: 200),
            now: 2.0 + (1.0 / 60.0)
        )

        #expect(mock.receivedVelocities.count == 1,
                "idle-magnitude runtime delta must still emit one update (the zero release)")
        #expect(mock.receivedVelocities.last == .zero,
                "velocity below idle threshold must be emitted as .zero, got \(String(describing: mock.receivedVelocities.last))")
    }

    @Test("applyRuntimePetVelocity is safe when petRenderer is nil (Metal-less)")
    func runtimeVelocitySafeWithNilRenderer() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.petRenderer = nil

        // Must not crash on either the first (baseline) or the second
        // (emission) call when no renderer is attached.
        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 100, y: 100),
            now: 1.0
        )
        controller.applyRuntimePetVelocity(
            position: NSPoint(x: 110, y: 100),
            now: 1.0 + (1.0 / 60.0)
        )
    }
}
