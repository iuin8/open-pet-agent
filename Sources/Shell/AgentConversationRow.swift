import AgentSensing
import SwiftUI

/// 外部会话流的单条渲染。四型各自样式:
/// - `.user`:右对齐 accent 气泡(人发给 agent 的 prompt)。
/// - `.assistant`:左对齐暖奶油气泡 + markdown 富文本(agent 在说话)。
/// - `.tool`:全宽紧凑行,状态字形(运行中 / ✓ / ✗)+ 工具名 + 摘要(借鉴 claude-devtools (https://github.com/matt1398/claude-devtools)
///   的 tool-call 紧凑呈现)。有详情 → 点行弹侧卡(2026-06-16:所有详情统一走侧卡,无内联 accordion)。
/// - `.awaiting`:accent 染色 callout「在等你…」(P3.3 会在此挂内联待答块,当前只读提示)。
struct AgentConversationRow: View {
    let item: ConversationItem
    /// 该行**哪个子区**正被侧卡查看(画 halo 脉冲环高亮);nil = 未高亮。`.primary`=主内容(气泡/工具/思考),
    /// `.metadata`=模型轮元数据栏 —— 点哪个子区光圈就亮哪个(2026-06-16 用户反馈,不再错亮到总结行)。
    var highlightRegion: RowHighlightRegion? = nil
    /// 点有详情的 tool 行 / 长文本行触发 → 弹侧卡看全文(2026-06-16:所有详情统一走侧卡,无内联 accordion)。
    var onExpandToSide: (() -> Void)? = nil
    /// D2:该 Task/Agent 行关联的子 agent(命中则在行下挂「子 agent」入口);nil = 无。
    var subagentRef: SubagentRef? = nil
    /// 点「子 agent」入口 → 弹子 agent 侧卡看其完整 transcript。
    var onOpenSubagent: (() -> Void)? = nil
    /// 点模型一轮的**元数据栏** → 弹「元数据行」侧卡(思考/工具,不含总结,2026-06-16 用户反馈:分离)。
    var onOpenTurnSteps: (() -> Void)? = nil
    /// 点 workflow 🧩 → 开 workflow 衍生 agent 列表卡(#9)。参数 = run id。
    var onOpenWorkflow: ((String) -> Void)? = nil
    /// P1-5:点用户行里的图片缩略图 → 开图片侧卡看全图。参数 = 被点的附件。
    var onOpenImage: ((ImageAttachment) -> Void)? = nil

    static let compactBoundaryLabel = "/compact · 上下文已压缩"

    var body: some View {
        switch item.kind {
        case .user(let text):
            userRow(text)
        case .assistant(let text):
            bubbleRow(text, isUser: false)
        case .tool(let name, let summary, let state, let input, let output):
            toolBlock(name: name, summary: summary, state: state, input: input, output: output)
        case .awaiting(let reason):
            if item.detailAffordance == .sideCard {
                Button { onExpandToSide?() } label: { awaitingRow(reason) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .expandable(onAccentFill: false)
            } else {
                awaitingRow(reason)
            }
        case .thinking(let text):
            thinkingRow(text)
        case .assistantTurn(let turn):
            turnRow(turn)
        case .systemNotice(let text):
            if item.detailAffordance == .sideCard {
                Button { onExpandToSide?() } label: { systemNoticeRow(text) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .expandable(onAccentFill: false)
            } else {
                systemNoticeRow(text)
            }
        case .compactBoundary:
            if item.detailAffordance == .sideCard {
                Button { onExpandToSide?() } label: { compactBoundaryRow }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .expandable(onAccentFill: false)
            } else {
                compactBoundaryRow
            }
        }
    }

    // MARK: - 系统通知

    private func systemNoticeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.35))
                .frame(width: 13, height: 16)
            Text(text)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.55))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChatCardTheme.inputFill.opacity(0.65)))
    }

    // MARK: - /compact 上下文压缩边界(分割线)

    /// 「上下文已压缩」分割线:两侧 hairline + 居中 chip,提示此处往上是被 /compact 压缩的旧上下文。
    private var compactBoundaryRow: some View {
        HStack(spacing: 8) {
            Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5)
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 9, weight: .semibold))
                Text(Self.compactBoundaryLabel).font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
            .fixedSize()
            Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5)
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 模型一轮(元数据栏 + 最终文字,2026-06-16 turn 模型)

    @ViewBuilder
    private func turnRow(_ a: AssistantTurn) -> some View {
        // 总结(finalText)超 3 行 → 可点开「总结详情」侧卡;元数据栏 → 点开「元数据行」侧卡(分离,2026-06-16)。
        let summaryExpandable = ConversationItem(id: item.id, kind: .assistant(text: a.finalText), timestamp: item.timestamp)
            .detailAffordance == .sideCard
        let hasSteps = a.toolCount + a.thinkingCount > 0
        let showBar = hasSteps || a.contextTokens != nil || a.isRunning || a.hasError || a.wasInterrupted
        VStack(alignment: .leading, spacing: 4) {
            if showBar {
                TurnMetadataBar(
                    turn: a,
                    onTap: hasSteps ? { onOpenTurnSteps?() } : nil   // 元数据栏 → 元数据行侧卡(只 steps)
                )
                .overlay { if highlightRegion == .metadata { HaloRing() } }   // 点元数据栏 → 光圈亮在**元数据栏**(不再错亮总结行)
                .hoverHalo(hasSteps)
            }
            if !a.finalText.isEmpty {
                if summaryExpandable {
                    Button { onExpandToSide?() } label: {   // 总结行 → 总结详情侧卡(只全文,不含元数据)
                        highlightDecorated(bubble(a.finalText, isUser: false, collapsed: true))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .expandable(onAccentFill: false)
                } else {
                    highlightDecorated(bubble(a.finalText, isUser: false, collapsed: false))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if a.isRunning {
                Text("正在思考…").font(.system(size: 11, weight: .regular, design: .rounded)).italic()
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.4)).padding(.leading, 4)
            }
            // P1-6:中断标**独立**显 —— 无 finalText 时单独成行、有 finalText 时附其后(否则被中断的「先说结论」轮看不出已中断);
            // 被中断 → isRunning 强制 false,不会与「正在思考…」并存。
            if a.wasInterrupted {
                Text("(已中断)").font(.system(size: 11, weight: .regular, design: .rounded)).italic()
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.35)).padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 思考行(仅轮次时间线侧卡;主流被折进元数据栏)

    @ViewBuilder
    private func thinkingRow(_ text: String) -> some View {
        if item.detailAffordance == .sideCard {
            Button { onExpandToSide?() } label: { thinkingContent(text, collapsed: true) }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).expandable(onAccentFill: false)
        } else {
            thinkingContent(text, collapsed: false).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func thinkingContent(_ text: String, collapsed: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "brain").font(.system(size: 11))
                .foregroundColor(ChatCardTheme.accent.opacity(0.55)).frame(width: 13, height: 16)
            Text(text).font(.system(size: 12)).italic()
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.6))
                .lineLimit(collapsed ? 2 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChatCardTheme.accent.opacity(0.05)))
    }

    // MARK: - user / assistant 气泡

    /// 用户行:文字气泡(有文字才显)+ 图片缩略图条(P1-5)。纯图片消息只显缩略图、无空气泡。
    @ViewBuilder
    private func userRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty { bubbleRow(text, isUser: true) }
            if !item.attachments.isEmpty { attachmentStrip(item.attachments) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 图片缩略图条:每张 capped `Self.thumbHeight` 高(等比,圆角),横排;点击 → 图片侧卡看全图。
    /// 多张换行(`FlowLayout` 没有 → 用 `LazyVGrid` 自适应列)。
    private static let thumbHeight: CGFloat = 64

    @ViewBuilder
    private func attachmentStrip(_ attachments: [ImageAttachment]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(attachments) { att in
                Button { onOpenImage?(att) } label: {
                    thumbnail(att)
                }
                .buttonStyle(.plain)
                .help("点击看大图")
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func thumbnail(_ att: ImageAttachment) -> some View {
        if let img = NSImage(data: att.data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: Self.thumbHeight * 2.2, maxHeight: Self.thumbHeight)
                .frame(height: Self.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(ChatCardTheme.hairline, lineWidth: 0.5)
                )
        } else {
            // 解码失败兜底(损坏 / 不支持格式)。
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ChatCardTheme.textPrimary.opacity(0.06))
                .frame(width: Self.thumbHeight * 1.4, height: Self.thumbHeight)
                .overlay(Image(systemName: "photo").foregroundColor(ChatCardTheme.textPrimary.opacity(0.3)))
        }
    }

    @ViewBuilder
    private func bubbleRow(_ text: String, isUser: Bool) -> some View {
        // P3.8 G1:全宽(与工具行齐),transcript 风格。G2:很长消息(.sideCard)折叠 + ⤢ → 点弹侧卡看全文。
        if item.detailAffordance == .sideCard {
            Button { onExpandToSide?() } label: {
                highlightDecorated(bubble(text, isUser: isUser, collapsed: true))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .expandable(onAccentFill: isUser)
        } else {
            highlightDecorated(bubble(text, isUser: isUser, collapsed: false))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 高亮装饰:viewing in 侧卡的行画 halo 脉冲环。文本行(bubbleRow)与工具行(toolBlock)共用。
    /// (源行 midY 由 `TranscriptListCoordinator` 用 `rect(ofRow:)` 算 —— NSTableView 容器里 SwiftUI
    ///  preference 跨不过边界,故不在此上报。)
    @ViewBuilder
    private func highlightDecorated<V: View>(_ v: V) -> some View {
        v.overlay { if highlightRegion == .primary { HaloRing() } }
    }

    /// 折叠态最多 3 行(2026-06-16 用户反馈):user 纯文本走 `lineLimit(3)` + `…` 截断;markdown 走 maxHeight≈3 行 + 底部渐隐。
    private static let collapsedMarkdownHeight: CGFloat = 64

    @ViewBuilder
    private func bubble(_ text: String, isUser: Bool, collapsed: Bool) -> some View {
        let fill = isUser ? ChatCardTheme.userBubbleFill : ChatCardTheme.petBubbleFill
        Group {
            if isUser {
                Text(text)
                    .font(ChatCardTheme.body)
                    .foregroundStyle(ChatCardTheme.userBubbleText)
                    .textSelection(.enabled)
                    .lineLimit(collapsed ? 3 : nil)
                    .truncationMode(.tail)
            } else {
                MarkdownTextView(
                    content: text,
                    tint: ChatCardTheme.accent,
                    maxWidth: ChatCardTheme.messageTextWidth,
                    baseFont: ChatCardTheme.body
                )
                .foregroundStyle(ChatCardTheme.petBubbleText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxHeight: (collapsed && !isUser) ? Self.collapsedMarkdownHeight : nil, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {   // markdown 折叠时底部渐隐到气泡色,提示「还有更多」(user 用 … 截断,不渐隐)
            if collapsed && !isUser {
                LinearGradient(colors: [fill.opacity(0), fill], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22).allowsHitTesting(false)
            }
        }
        .background(bubbleShape(isUser: isUser).fill(isUser ? ChatCardTheme.userBubbleFill : ChatCardTheme.petBubbleFill))
        .overlay { if !isUser { bubbleShape(isUser: isUser).stroke(ChatCardTheme.petBubbleStroke, lineWidth: 0.5) } }
    }

    private func bubbleShape(isUser: Bool) -> UnevenRoundedRectangle {
        let r = ChatCardTheme.bubbleRadius
        let tail = ChatCardTheme.tailCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: isUser ? r : tail,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: isUser ? tail : r,
            style: .continuous
        )
    }

    // MARK: - tool 行(紧凑、全宽,可点展开详情)

    @ViewBuilder
    private func toolBlock(name: String, summary: String, state: ConversationItem.ToolState, input: String?, output: String?) -> some View {
        let affordance = item.detailAffordance
        VStack(alignment: .leading, spacing: 5) {
            // 有详情 → 点行弹侧卡(Button 命中可靠,onTapGesture 会被滚动手势吞)+ 右下角双箭头;无详情 → 普通 HStack。
            if affordance == .none {
                toolHeaderRow(name: name, summary: summary, state: state)
            } else {
                Button { onExpandToSide?() } label: {
                    toolHeaderRow(name: name, summary: summary, state: state)
                        .overlay { if highlightRegion == .primary { HaloRing() } }
                }
                .buttonStyle(.plain)
                .expandable(onAccentFill: false)
            }
            // D2/#9:Task/Agent/Workflow 这类行级入口挂在具体工具行下，不挤占 assistant turn 元数据栏。
            if let ref = subagentRef { subagentPill(ref) }
            if let runId = item.workflowRunId { workflowPill(runId) }
        }
    }

    /// 子 agent 入口药丸(person.2 + 类型 + chevron),点 → 弹子 agent 侧卡。缩进归属上方 tool 行。
    private func subagentPill(_ ref: SubagentRef) -> some View {
        rowActionPill(icon: "person.2.fill", title: ref.agentType) { onOpenSubagent?() }
    }

    private func workflowPill(_ runId: String) -> some View {
        rowActionPill(icon: "puzzlepiece.extension.fill", title: "workflow") {
            if let onOpenWorkflow { onOpenWorkflow(runId) }
            else { onExpandToSide?() }
        }
    }

    private func rowActionPill(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .medium, design: .rounded)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(ChatCardTheme.accent.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(ChatCardTheme.accent.opacity(0.10)))
            .overlay(Capsule().stroke(ChatCardTheme.accent.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
    }

    private func toolHeaderRow(name: String, summary: String, state: ConversationItem.ToolState) -> some View {
        HStack(alignment: .top, spacing: 7) {
            toolGlyph(state)
                .frame(width: 13, height: 16)   // 与首行文字基线对齐
            (
                Text(name).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.75))
                + Text(summary.isEmpty ? "" : "  \(summary)")
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.5))
            )
            .lineLimit(1)                 // 固定 1 行(2026-06-16 用户反馈),超长 … 尾截断,点击看详情
            .truncationMode(.tail)
            Spacer(minLength: 0)          // 展开指示统一走 .expandable 的右下角双箭头(不在此行内放)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ChatCardTheme.inputFill)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func toolGlyph(_ state: ConversationItem.ToolState) -> some View {
        switch state {
        case .running:
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ChatCardTheme.accent)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: .systemGreen))
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: .systemRed))
        }
    }

    // MARK: - awaiting callout(P3.3 内联待答块的占位)

    private func awaitingRow(_ reason: AwaitReason) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "bell.fill")
                .font(.system(size: 11))
                .foregroundColor(ChatCardTheme.accent)
                .frame(width: 13, height: 16)
            Text(Self.awaitingText(reason))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ChatCardTheme.accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(ChatCardTheme.accent.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    static func awaitingText(_ reason: AwaitReason) -> String {
        switch reason {
        case .question(let title):    return "在等你回答：\(title)"
        case .permission(let tool):   return "在等你确认：\(tool)"
        case .notification(let msg):  return msg
        }
    }

}

// `HaloRing`(P3.7-③ 源行 halo,呼吸式 stroke 在「细+亮 ↔ 粗+淡」间往返,指示「正在侧卡看这行」)
// 现为 CALayer 驱动(`BreathingLayerViews.swift`)—— SwiftUI `.repeatForever` 会把整棵卡片树标脏每帧
// 重评。CA 动画在 render server 跑,不进 AttributeGraph。`isHighlighted` 时以 overlay 插入,收起即移除。

extension View {
    /// 可点元素的悬停光圈(深靛细环,提示「可点」)。metadata 栏等**无展开图标**的可点元素用它。`enabled=false` 透传。
    @ViewBuilder
    func hoverHalo(_ enabled: Bool) -> some View {
        if enabled { modifier(HoverHaloModifier()) } else { self }
    }

    /// 可展开看详情的**消息行**:悬停光圈 + **右下角双箭头**(常驻淡显 + hover 加深),统一展开感知(2026-06-16 用户反馈)。
    /// `onAccentFill` = 行底是 accent 橙(user 气泡)→ 图标用白色(橙底上 accent 橙看不见);否则用 accent 橙。
    func expandable(onAccentFill: Bool = false) -> some View {
        modifier(ExpandableRowModifier(onAccentFill: onAccentFill))
    }
}

/// 悬停光圈(深靛细环)。深靛在橙/白/奶白三类行底都清晰(走亮度对比),不与 accent 橙、teal selection 撞。
private struct HoverHaloModifier: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ChatCardTheme.hoverHalo.opacity(hovering ? 0.32 : 0), lineWidth: 1.5)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }
}

/// 可展开行:悬停深靛光圈 + 右下角双箭头(arrow.up.left.and.arrow.down.right)。
/// 双箭头常驻 0.4 淡显(让用户知道可展开)、hover 0.9 加深;`allowsHitTesting(false)` 不夺行点击。
private struct ExpandableRowModifier: ViewModifier {
    let onAccentFill: Bool
    @State private var hovering = false
    private var iconTint: Color { onAccentFill ? .white : ChatCardTheme.accent }
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ChatCardTheme.hoverHalo.opacity(hovering ? 0.32 : 0), lineWidth: 1.5)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(iconTint.opacity(hovering ? 0.9 : 0.4))
                    .padding(5)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }
}
