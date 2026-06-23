import AppKit

/// Global summon hotkey for the chat bubble.
///
/// Listens for the configured key combination both globally (when other
/// apps are focused) and locally (when OpenPetAgent itself is focused) and
/// fires the supplied callback on each press. Defaults to **⌥Space** —
/// Open WebUI Desktop / Raycast-style summon, low conflict with macOS
/// (Spotlight owns ⌘Space) and most input methods.
///
/// Global event monitoring requires Accessibility permission, which the
/// app already requests for window tracking. If the permission is denied,
/// the local monitor still fires while OpenPetAgent is foreground — a
/// graceful degradation rather than a hard failure.
@MainActor
public final class GlobalChatHotkey {

    public struct Combo: Sendable, Equatable {
        public let keyCode: UInt16
        public let modifiers: NSEvent.ModifierFlags

        public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⌥Space — Option + Spacebar. `kVK_Space = 49`.
        public static let optionSpace = Combo(keyCode: 49, modifiers: .option)
    }

    private let combo: Combo
    private let onTrigger: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init(combo: Combo = .optionSpace, onTrigger: @escaping @MainActor () -> Void) {
        self.combo = combo
        self.onTrigger = onTrigger
    }

    public func start() {
        stop()
        let match = { [combo] (event: NSEvent) -> Bool in
            event.type == .keyDown
                && event.keyCode == combo.keyCode
                && event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask) == combo.modifiers
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard match(event) else { return }
            Task { @MainActor in self.onTrigger() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard match(event) else { return event }
            Task { @MainActor in self.onTrigger() }
            // Swallow so the spacebar doesn't also reach focused widgets.
            return nil
        }
    }

    public func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}
