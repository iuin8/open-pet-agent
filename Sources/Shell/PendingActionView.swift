import SwiftUI

/// 权限卡片的纯数据模型(Shell 内,不依赖 AgentSensing)。App 层把 `PermissionPrompt`
/// 映射成它,保持感知层 UI-free、Shell 层感知-free。
///
/// (P3.3 从退役的 `PermissionCardView.swift` 迁来 —— 头顶独立权限卡已退役,改为会话流底部内联
/// `PendingActionView`;模型本身复用不变。)
public struct PermissionCardModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case plan, question, standard }

    public let kind: Kind
    /// 卡片标题(工具名 / 「计划审批」/ 问题头)。
    public let title: String
    /// 详情正文(命令 / 计划摘要 / 问题文本)。可空。
    public let detail: String?
    /// 项目名(可选,角标)。
    public let project: String?
    /// Question 型的选项(标签)。其余型为空。
    public let options: [String]

    public init(kind: Kind, title: String, detail: String?, project: String? = nil, options: [String] = []) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.project = project
        self.options = options
    }
}

/// 一条**待用户处置**的外部 agent 请求(权限 / 问题),内联在 Claude Code 会话流底部。
/// 模型 + 四类回调(App 层映射成 `HookResponder.respond`):点允许 / 拒绝 / 选项 / 自定义答案。
/// `onSuperseded`:被新请求顶替时给旧 responder 弃权兜底(免旧 Claude 连接等到超时)。
///
/// 含闭包 → 非 `Equatable`;`AgentSessionStore` 以 `@Published` 持有,变化触发刷新即可。
public struct PendingAction: Identifiable {
    /// 请求唯一 id(requestId)—— 多并发请求入队/出队的 key。App 层生成 UUID。
    public let id: String
    public let model: PermissionCardModel
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onSelectOption: (Int) -> Void
    let onSubmit: (String) -> Void
    let onSuperseded: () -> Void
    /// 点「定位会话」→ App 打开触发它的会话 + 把权限卡尖角重锚到对应消息行(可再点切回 pet 旁,2026-06-16)。
    /// nil = 不显示该按钮(如合成调试请求 / 拿不到 sessionId)。
    let onLocate: (() -> Void)?

    public init(
        id: String = UUID().uuidString,
        model: PermissionCardModel,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void,
        onSelectOption: @escaping (Int) -> Void,
        onSubmit: @escaping (String) -> Void,
        onSuperseded: @escaping () -> Void,
        onLocate: (() -> Void)? = nil
    ) {
        self.id = id
        self.model = model
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onSelectOption = onSelectOption
        self.onSubmit = onSubmit
        self.onSuperseded = onSuperseded
        self.onLocate = onLocate
    }
}

/// 会话流底部的**内联待答块** —— Claude Code 抛权限/问题时,在 Claude Code tab 会话流末尾出现,
/// 用户原地点「允许/拒绝」或选选项或敲自定义答案。
///
/// 区别于退役的头顶 `PermissionCardBubble`:**无独立卡 chrome**(它嵌在会话流里,只用 accent 染色
/// callout 区分),按钮/选项 UI 沿用退役 `PermissionCardView` 的样式。自定义答案输入框仅 question
/// 型显示(AskUserQuestion 的「Other」自由文本路径,user 决策:输入框只答「在等你」的)。
struct PendingActionView: View {
    let action: PendingAction
    @State private var customAnswer: String = ""

    private var model: PermissionCardModel { action.model }
    private var accent: Color { Color(ChatBubbleTheme.accent) }
    private var textPrimary: Color { Color(ChatBubbleTheme.textPrimary) }
    private var textMuted: Color { Color(ChatBubbleTheme.textMuted) }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatBubbleTheme.stackGap) {
            header
            if let detail = model.detail, !detail.isEmpty {
                Text(detail)
                    .font(Font(ChatBubbleTheme.bodyFont))
                    .foregroundStyle(textPrimary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.kind == .question, !model.options.isEmpty {
                optionsList
                customAnswerField
            } else {
                allowDenyButtons
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - Header(图标 + 标题 + 项目角标)

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
            Text(model.title)
                .font(Font(ChatBubbleTheme.buttonFont))
                .foregroundStyle(textPrimary)
                .lineLimit(1)
            // 定位会话:打开触发它的会话 + 尖角重锚到对应消息行(可再点切回 pet 旁)。
            if let onLocate = action.onLocate {
                Button(action: onLocate) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开会话并定位到触发这条请求的消息")
            }
            Spacer(minLength: 4)
            if let project = model.project, !project.isEmpty {
                Text(project)
                    .font(Font(ChatBubbleTheme.captionFont))
                    .foregroundStyle(textMuted)
                    .lineLimit(1)
            }
        }
    }

    private var iconName: String {
        switch model.kind {
        case .plan:     return "doc.text.fill"
        case .question: return "questionmark.circle.fill"
        case .standard: return "hand.raised.fill"
        }
    }

    // MARK: - 允许 / 拒绝

    private var allowDenyButtons: some View {
        HStack(spacing: 6) {
            Button(action: action.onAllow) {
                Text("允许")
                    .font(Font(ChatBubbleTheme.buttonFont))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: ChatBubbleTheme.cornerRadiusSmall).fill(accent))
            }
            .buttonStyle(.plain)

            Button(action: action.onDeny) {
                Text("拒绝")
                    .font(Font(ChatBubbleTheme.buttonFont))
                    .foregroundStyle(textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: ChatBubbleTheme.cornerRadiusSmall)
                            .strokeBorder(textMuted.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 问题选项(逐行可点)

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.options.enumerated()), id: \.offset) { idx, opt in
                Button { action.onSelectOption(idx) } label: {
                    HStack(spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(accent.opacity(0.15)))
                        Text(opt)
                            .font(Font(ChatBubbleTheme.bodyFont))
                            .foregroundStyle(textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ChatBubbleTheme.cornerRadiusSmall)
                            .strokeBorder(textMuted.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 自定义答案(AskUserQuestion 的 Other 自由文本)

    private var customAnswerField: some View {
        HStack(spacing: 6) {
            TextField("或输入自定义答案…", text: $customAnswer)
                .textFieldStyle(.plain)
                .font(Font(ChatBubbleTheme.bodyFont))
                .foregroundStyle(textPrimary)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: ChatBubbleTheme.cornerRadiusSmall)
                        .fill(Color(ChatBubbleTheme.inputFill))
                )
                .onSubmit(submitCustom)
            Button(action: submitCustom) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(canSubmit ? accent : textMuted.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCustom() {
        let trimmed = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        action.onSubmit(trimmed)
    }
}
