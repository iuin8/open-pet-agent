import AppKit
import Foundation
import Shell

// MARK: - 对话卡片(用户主动 ask 入口)

extension MinimalAppDelegate {
    /// ⌥Space / pet 双击 / 灵动岛点击 / 菜单 统一通用入口:toggle 锚定 pet 旁的对话卡片。
    /// `ChatCardWindowController` 内部判定可见态,visible → hide,否则 show（spring 进场）。
    func toggleChatCard() {
        // 主动建议气泡可见时召唤 chat = 用户被勾起兴趣 → engaged（归零 decay）。
        notifyProactiveEngagementIfVisible()
        chatCardWindowController?.toggle()
        // N3.3: 召唤 = 向 pet 形象 dispatch .acknowledge 信号。Orb 默认空
        // supportedSignatures → no-op;角色化形象 (史莱姆等) 可以在 trigger
        // 里实现"挥手"之类反应。
        shellController?.dispatchSignature(.acknowledge)
    }

    /// 「清空对话」(pet 右键 / 菜单栏统一入口):确认弹窗 → 清 `ConversationStore`(pet chat
    /// 历史持久化)+ 重置卡片视图。destructive + 不可撤销,故必经确认;隐私控制基本盘
    /// (clear API 早有,本入口补 UI,companion-features-roadmap S2 之外)。
    func confirmAndClearConversation() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空与桌宠的对话记录？"
        alert.informativeText = "将删除全部聊天历史，此操作不可撤销。"
        let clearButton = alert.addButton(withTitle: "清空")
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await self.rootSystem.conversationStore?.clear()
            self.chatCardWindowController?.clearMessages()
        }
    }

    /// C2 — ⌘⇧Space 触发:读取系统当前选中文本 → 召唤对话卡片 →
    /// (若有选中) 预填到 composer,**不自动发送** — 跟 ChoiceCard 同款决策
    /// (HermesPet 决策 #17 防误触),由用户追加上下文后手动 Return。
    /// 无选中则空召唤(等同 `toggleChatCard` 行为)。
    func handleChatCardTriggered() {
        // 主动建议气泡可见时召唤 chat = engaged（归零 decay）。
        notifyProactiveEngagementIfVisible()
        let selected = AccessibilityReader.readSelectedText()
        chatCardWindowController?.toggleWithSelectedText(selected)
        shellController?.dispatchSignature(.acknowledge)
    }

    /// S3 — ⌘⇧P 触发:取当前 chain assistant 气泡(索引 1)的 markdown 源,
    /// 钉到桌面。空 chain / 空内容时 no-op。defaultOrigin 用屏幕中心稍偏右上。
    func pinCurrentAssistantReply() {
        guard let controller = pinCardController else { return }
        guard let session = bondedSession else { return }
        guard let assistantBubble = session.chain.bubble(at: 1) else {
            // 当前没有 assistant 回复可 pin —— silent fail
            return
        }
        let content = assistantBubble.currentText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !content.isEmpty else { return }

        let origin = defaultPinSpawnOrigin()
        Task { @MainActor in
            _ = await controller.add(content: content, defaultOrigin: origin)
        }
    }

    /// 屏幕中心稍偏右上 —— 不挡 pet 默认位置,也不贴边。
    /// 多张 pin 会由 controller 自己沿对角线偏移避免重叠。
    func defaultPinSpawnOrigin() -> NSPoint {
        let frame = currentScreenFrame()
        return NSPoint(
            x: frame.midX + 40,
            y: frame.midY + 40
        )
    }
}
