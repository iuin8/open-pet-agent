import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("SettingsContentView — Cmd-shortcut paste/copy/cut/select-all/undo/redo mapping")
struct SettingsContentViewKeyTests {
    private func keyEvent(
        char: String,
        modifiers: NSEvent.ModifierFlags,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: char,
            charactersIgnoringModifiers: char,
            isARepeat: false,
            keyCode: 0
        )!
    }

    @Test("Cmd+V → paste:")
    func cmdVMapsToPaste() {
        let event = keyEvent(char: "v", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == #selector(NSText.paste(_:)))
    }

    @Test("Cmd+C → copy:")
    func cmdCMapsToCopy() {
        let event = keyEvent(char: "c", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == #selector(NSText.copy(_:)))
    }

    @Test("Cmd+X → cut:")
    func cmdXMapsToCut() {
        let event = keyEvent(char: "x", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == #selector(NSText.cut(_:)))
    }

    @Test("Cmd+A → selectAll:")
    func cmdAMapsToSelectAll() {
        let event = keyEvent(char: "a", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == #selector(NSText.selectAll(_:)))
    }

    @Test("Cmd+Z → undo:")
    func cmdZMapsToUndo() {
        let event = keyEvent(char: "z", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == Selector(("undo:")))
    }

    @Test("Cmd+Shift+Z → redo:")
    func cmdShiftZMapsToRedo() {
        let event = keyEvent(char: "z", modifiers: [.command, .shift])
        #expect(SettingsContentView.editingSelector(for: event) == Selector(("redo:")))
    }

    @Test("Cmd+Q (unmapped) → nil so super sees it")
    func cmdQUnmapped() {
        let event = keyEvent(char: "q", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == nil)
    }

    @Test("Plain V (no Cmd) → nil; field editor handles it as typed input")
    func plainVUnmapped() {
        let event = keyEvent(char: "v", modifiers: [])
        #expect(SettingsContentView.editingSelector(for: event) == nil)
    }

    @Test("keyUp event with Cmd+V → nil; only keyDown maps")
    func keyUpUnmapped() {
        let event = keyEvent(char: "v", modifiers: [.command], type: .keyUp)
        #expect(SettingsContentView.editingSelector(for: event) == nil)
    }

    @Test("Uppercase V (Caps Lock) still maps to paste: (case-insensitive)")
    func uppercaseVStillMaps() {
        let event = keyEvent(char: "V", modifiers: [.command])
        #expect(SettingsContentView.editingSelector(for: event) == #selector(NSText.paste(_:)))
    }
}
