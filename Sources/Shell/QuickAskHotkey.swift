import AppKit

/// C2 — 全局 ⌘⇧Space 热键: 召唤 Bonded 输入气泡, 若系统当前有选中文本
/// 则预填到输入框 (等待用户确认 / 追加上下文后再发送)。
///
/// 设计与 `PinCurrentReplyHotkey` / `GlobalChatHotkey` 同套实现路径
/// (NSEvent global + local monitor 双路, 不用 Carbon Event Manager 复杂签名)。
/// global monitor 需要 Accessibility 权限 — app 已经因为 window tracking
/// 申请过。本地 fallback 让 OpenPetAgent 自己 foreground 时也能响应。
///
/// 选择 ⌘⇧Space 是为了让用户在任意 app 里"选中一段文本 → 一键带文本召唤
/// 桌宠"的肌肉记忆稳定: ⌥Space 是空召唤, ⌘⇧Space 是带 selection 的快问;
/// 跟 macOS 默认 ⌘Space (Spotlight) 冲突最小。
@MainActor
public final class QuickAskHotkey {

    public struct Combo: Sendable, Equatable {
        public let keyCode: UInt16
        public let modifiers: NSEvent.ModifierFlags

        public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⌘⇧Space — Command + Shift + Space。`kVK_Space = 49`。
        public static let commandShiftSpace = Combo(
            keyCode: 49,
            modifiers: [.command, .shift]
        )
    }

    private let combo: Combo
    private let onTrigger: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init(
        combo: Combo = .commandShiftSpace,
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
            return nil  // swallow,避免 ⌘⇧Space 同时落到当前 focused 控件
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
