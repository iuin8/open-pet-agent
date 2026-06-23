import AppKit
import Testing
@testable import Shell

/// Regression tests for the M.2 menu-bar regression where `screenFrames`
/// (visibleFrame) was used for CGWindow y-flip math. The fix introduces
/// `fullScreenFrames` (NSScreen.frame including menu bar) so the per-frame
/// tick can flip CGWindow.y against the full screen height — restoring the
/// pre-M.2 behavior where snow correctly stops on top of windows instead
/// of falling through them by the menu-bar offset (~24px).

@MainActor
private func makeWindow(frame: NSRect) -> NSWindow {
    let w = NSWindow(
        contentRect: frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    w.isReleasedWhenClosed = false
    return w
}

@Test("fullScreenFrames starts empty alongside screenFrames")
@MainActor
func fullScreenFramesStartsEmpty() {
    let registry = OverlayWindowRegistry { frame in makeWindow(frame: frame) }
    #expect(registry.fullScreenFrames.isEmpty)
    #expect(registry.screenFrames.isEmpty)
}

@Test("sync(displayIDs:screenFrameProvider:) leaves fullScreenFrames empty (test path)")
@MainActor
func syncDisplayIDsDoesNotPopulateFullFrames() {
    let registry = OverlayWindowRegistry { frame in makeWindow(frame: frame) }
    let id: CGDirectDisplayID = 42
    let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1176)
    registry.sync(displayIDs: [id], screenFrameProvider: { _ in visibleFrame })
    #expect(registry.screenFrames[id] == visibleFrame)
    // Test path doesn't have real NSScreen.frame info, so fullScreenFrames is
    // not populated here. tickRegistryCoordinators must gracefully fall back
    // to visibleFrame when fullScreenFrames is missing.
    #expect(registry.fullScreenFrames[id] == nil)
}

@Test("Removing display clears both screenFrames and fullScreenFrames")
@MainActor
func removingDisplayClearsBothFrames() {
    let registry = OverlayWindowRegistry { frame in makeWindow(frame: frame) }
    let id: CGDirectDisplayID = 1
    let visible = NSRect(x: 0, y: 0, width: 1920, height: 1176)
    let full = NSRect(x: 0, y: 0, width: 1920, height: 1200)

    registry.sync(displayIDs: [id], screenFrameProvider: { _ in visible })
    // Manually seed fullScreenFrames to simulate the sync(screens:) path.
    registry.fullScreenFrames[id] = full
    #expect(registry.fullScreenFrames[id] != nil)
    #expect(registry.screenFrames[id] != nil)

    // Now sync with empty display list — both must clear.
    registry.sync(displayIDs: [], screenFrameProvider: { _ in .zero })
    #expect(registry.screenFrames[id] == nil)
    #expect(registry.fullScreenFrames[id] == nil)
}

@Test("fullScreenFrames height differs from visibleFrame height (menu bar)")
@MainActor
func fullScreenFramesHigherThanVisible() {
    // Verifies the registry stores both frames as independent rectangles,
    // so per-frame y-flip math can pick the right one.
    let registry = OverlayWindowRegistry { frame in makeWindow(frame: frame) }
    let id: CGDirectDisplayID = 1
    let visible = NSRect(x: 0, y: 0, width: 1920, height: 1176)
    let full = NSRect(x: 0, y: 0, width: 1920, height: 1200)

    registry.sync(displayIDs: [id], screenFrameProvider: { _ in visible })
    registry.fullScreenFrames[id] = full

    #expect(registry.screenFrames[id]?.height == 1176)
    #expect(registry.fullScreenFrames[id]?.height == 1200)
    #expect((registry.fullScreenFrames[id]?.height ?? 0)
            - (registry.screenFrames[id]?.height ?? 0) == 24,
            "Difference between full and visible height must equal the menu bar (24)")
}
