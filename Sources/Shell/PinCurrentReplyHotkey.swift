import AppKit

/// S3 — 全局 ⌘⇧P 热键:把当前 Bonded chain 的 assistant 气泡内容 pin 到桌面。
///
/// 跟 `GlobalChatHotkey` 同套实现路径(NSEvent global + local monitor,不用 Carbon
/// Event Manager 复杂签名)。global monitor 需要 Accessibility 权限,app 已经
/// 因为 window tracking 申请过。本地 fallback 让 OpenPetAgent 自己 foreground
/// 时也能响应。
@MainActor
public final class PinCurrentReplyHotkey {

    public struct Combo: Sendable, Equatable {
        public let keyCode: UInt16
        public let modifiers: NSEvent.ModifierFlags

        public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⌘⇧P — Command + Shift + P。`kVK_ANSI_P = 35`。
        public static let commandShiftP = Combo(
            keyCode: 35,
            modifiers: [.command, .shift]
        )
    }

    private let combo: Combo
    private let onTrigger: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init(
        combo: Combo = .commandShiftP,
        onTrigger: @escaping @MainActor () -> Void
    ) {
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
            return nil  // swallow,避免 ⌘⇧P 同时落到当前 focused 控件
        }
    }

    public func stop() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}
