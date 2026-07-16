import AppKit
import Testing
@testable import Shell

@MainActor
@Test("pinned panels stay at floating level so menu bar popovers can cover them")
func pinnedPanelsStayAtFloatingLevel() {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false
    )

    WindowPinState.apply(panel, pinned: true)

    #expect(panel.level == NSWindow.Level.floating)
    #expect(panel.level.rawValue < NSWindow.Level.mainMenu.rawValue)
    #expect(panel.level.rawValue < NSWindow.Level.statusBar.rawValue)
    #expect(panel.collectionBehavior == ShellWindowPolicy.activeCompanionBehavior)
}

@MainActor
@Test("unpinned panels remain normal transient windows")
func unpinnedPanelsRemainNormalTransientWindows() {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false
    )

    WindowPinState.apply(panel, pinned: false)

    #expect(panel.level == NSWindow.Level.normal)
    #expect(panel.collectionBehavior == ShellWindowPolicy.transientCompanionBehavior)
}
