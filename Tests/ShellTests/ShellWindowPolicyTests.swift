import AppKit
import Testing
@testable import Shell

@MainActor
@Test("factory companion windows use policy below menu bar")
func factoryCompanionWindowsUsePolicyBelowMenuBar() {
    let frame = NSRect(x: 0, y: 24, width: 1440, height: 876)
    let overlay = ShellWindowFactory.makeOverlayWindow(
        descriptor: WindowDescriptor(kind: .overlay, isInteractive: false, level: 0),
        screenFrame: frame
    )
    let pet = ShellWindowFactory.makePetWindow(
        descriptor: WindowDescriptor(kind: .pet, isInteractive: true, level: 1),
        screenFrame: frame,
        initialState: .default
    )
    let chat = ShellWindowFactory.makeChatWindow(
        descriptor: WindowDescriptor(kind: .chat, isInteractive: true, level: 2),
        petFrame: pet.frame,
        replyHandler: { _ in "" }
    )

    for window in [overlay, pet, chat] {
        #expect(window.level == NSWindow.Level.floating)
        #expect(window.level.rawValue < NSWindow.Level.mainMenu.rawValue)
        #expect(window.level.rawValue < NSWindow.Level.statusBar.rawValue)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == NSColor.clear)
    }
    #expect(overlay.collectionBehavior == ShellWindowPolicy.passiveCompanionBehavior)
    #expect(pet.collectionBehavior == ShellWindowPolicy.activeCompanionBehavior)
    #expect(chat.collectionBehavior == ShellWindowPolicy.passiveCompanionBehavior)

    overlay.orderOut(nil)
    pet.orderOut(nil)
    chat.orderOut(nil)
}

@MainActor
@Test("companion overlay policy stays below menu bar while spanning spaces")
func companionOverlayPolicyStaysBelowMenuBar() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    ShellWindowPolicy.applyCompanionOverlayStyle(
        to: window,
        title: "Policy Test",
        interactive: false,
        behavior: ShellWindowPolicy.passiveCompanionBehavior
    )

    #expect(window.title == "Policy Test")
    #expect(window.level == .floating)
    #expect(window.level.rawValue < NSWindow.Level.mainMenu.rawValue)
    #expect(window.level.rawValue < NSWindow.Level.statusBar.rawValue)
    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(window.collectionBehavior.contains(.stationary))
    #expect(window.collectionBehavior.contains(.ignoresCycle))
    #expect(window.ignoresMouseEvents)
    #expect(!window.isOpaque)
    #expect(window.backgroundColor == .clear)
}

@Test("clamp keeps overlay frames inside visible work area")
func clampKeepsOverlayFramesInsideVisibleWorkArea() {
    let visible = NSRect(x: 0, y: 24, width: 1440, height: 876)
    let frame = NSRect(x: -80, y: 870, width: 320, height: 160)

    let clamped = ShellWindowPolicy.clamp(frame, inside: visible, margin: 8)

    #expect(clamped.minX == 8)
    #expect(clamped.maxY == 892)
    #expect(clamped.minY >= visible.minY + 8)
    #expect(clamped.maxY <= visible.maxY - 8)
}
