import AgentSensing
import SwiftUI

/// pet 旁权限侧卡的内容:把 `AgentSessionStore` 的待答**队列**堆叠展示(最新在上),每条一个
/// `PendingActionView`(允许/拒绝/选项/自定义答案)。≥2 条时顶部「N 个待处理 + 全部允许/拒绝」批量。
/// 观察 store → 队列增删自动刷新;队列空时 App 收起本卡(见 `PermissionCardWindowController`)。
///
/// (2026-06-16:权限/问题从会话流底部内联 **改为 pet 旁独立侧卡** —— 陪伴卡片关着也能答,
/// 多并发请求并存不互相顶替;堆叠队列 + bulk 呈现。)
struct PermissionStackView: View {
    @ObservedObject var store: AgentSessionStore
    /// 尖角几何(controller 据锚定结果驱动:pet 模式指 pet,row 模式指会话消息行)。
    @ObservedObject var card: PermissionCardState

    static let width: CGFloat = 340
    /// 尖角戳出长度(= `ChatCardShape.tailHeight`)。
    static let beak: CGFloat = 11

    private var queue: [PendingAction] { store.pendingQueue(for: .claudeCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // 最新在上(新请求最显眼)。
            ForEach(queue.reversed()) { action in
                PendingActionView(action: action)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .padding(beakEdge, Self.beak)   // 给尖角让出戳出空间(在 tail 那侧)
        .background(bubble.fill(ChatCardTheme.cardBackground))
        .overlay(bubble.stroke(ChatCardTheme.hairline, lineWidth: 0.5))
    }

    /// 带尖角的卡片轮廓(`ChatCardShape` 包 `SpeechBubbleShape`,beak 指向 pet/消息行)。
    private var bubble: ChatCardShape {
        ChatCardShape(tailSide: card.tailSide, tailPercent: card.tailPercent,
                      cornerRadius: ChatCardTheme.cardRadius, tailHeight: Self.beak)
    }

    /// content 往哪侧 padding 让出 beak 空间(与 tailSide 同侧)。
    private var beakEdge: Edge.Set {
        switch card.tailSide {
        case .top:    return .top
        case .bottom: return .bottom
        case .left:   return .leading
        case .right:  return .trailing
        case .none:   return []   // 无尖角 → 不让出空间
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatCardTheme.accent)
            Text(queue.count <= 1 ? "等你处理" : "\(queue.count) 个待处理")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.85))
            Spacer(minLength: 8)
            // 批量仅作用于「允许/拒绝」型(标准权限/计划);问题(AskUserQuestion)需逐个答,不参与 bulk。
            if bulkResolvable.count >= 2 {
                bulkButton("全部允许", color: ChatCardTheme.accent) { resolveAll(allow: true) }
                bulkButton("全部拒绝", color: ChatCardTheme.textPrimary.opacity(0.55)) { resolveAll(allow: false) }
            }
        }
    }

    private var bulkResolvable: [PendingAction] {
        queue.filter { $0.model.kind != .question }
    }

    private func bulkButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    /// 批量允许/拒绝(快照迭代,各 onAllow/onDeny 会把自身从队列移除,不影响快照)。仅作用于非问题型。
    private func resolveAll(allow: Bool) {
        for a in bulkResolvable { allow ? a.onAllow() : a.onDeny() }
    }
}
