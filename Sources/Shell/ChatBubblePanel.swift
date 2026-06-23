import AppKit

/// `NSPanel` subclass that hosts the speech-bubble chat shell.
///
/// Configured to behave like an industry-standard macOS overlay (Raycast /
/// Spotlight / Apple Writing Tools style):
///
/// - `.nonactivatingPanel` style so clicking the panel does NOT pull the
///   app to the foreground — the bubble is a peripheral surface, not a
///   primary window.
/// - `canBecomeKey = true` so the input field *can* take keystrokes when
///   the user explicitly clicks into it (`NSApp.activate` + `makeKey`).
/// - `canBecomeMain = false` so the bubble is never treated as the app's
///   main window (no menu-bar tints, no main-window behaviors).
///
/// This is a borderless non-activating overlay-panel pattern for AppKit.
@MainActor
public final class ChatBubblePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
