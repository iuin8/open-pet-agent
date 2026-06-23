import AppKit
import SwiftUI

/// 侧卡里的**统一详情内容块**:一条工具条(换行 / 原文·markdown / 复制)+ 内容。
/// 工具 input/output、user/assistant 全文都走它 → 「看详情」交互统一(2026-06-16 用户反馈:
/// 所有看详情展开都收进侧卡;复制按钮旁加原文/markdown 切换 + 是否换行 + 标准 ⌘C 复制)。
///
/// 两个 toggle(各自 `@State`,每块独立 → 输入看渲染、输出看原文互不干扰):
/// - **原文 / markdown**(默认 markdown):markdown 模式 diff→`DiffView` 行级红绿背景、其余→`MarkdownTextView`;
///   原文模式 = 等宽纯文本逐字呈现(不解析 markdown/diff),看「真正发出去/收回来的字节」。
/// - **换行**(默认开):开 = 按卡宽折行;关 = 不折行 + 横向滚动看长行(读宽 diff / 长命令不被挤成多行)。
struct DetailContentView: View {
    let text: String
    /// markdown 折行宽度上限(侧卡传卡身宽)。
    var maxWidth: CGFloat = .infinity
    /// 段标签(输入/输出/角色名),显示在工具条左侧。nil/空则工具条只剩右侧按钮。
    var label: String?

    @State private var raw = false      // 默认 markdown
    @State private var wrap = true      // 默认换行

    /// 不换行模式给 markdown 的虚拟超宽(实际超此宽才折,远大于任何显示器 → 等效不折,交外层横向滚动)。
    private static let noWrapWidth: CGFloat = 100_000

    init(text: String, maxWidth: CGFloat = .infinity, label: String? = nil) {
        self.text = text
        self.maxWidth = maxWidth
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            toolbar
            content
        }
    }

    // MARK: - 工具条(标签 + 换行 + 原文/markdown + 复制)

    private var toolbar: some View {
        HStack(spacing: 6) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.45))
            }
            Spacer(minLength: 8)
            // 换行:默认开(muted);关 = active(accent),长行横向滚动。
            chip(icon: wrap ? "text.alignleft" : "arrow.left.and.right",
                 active: !wrap,
                 help: wrap ? "切到不换行(长行横向滚动)" : "切到换行") { wrap.toggle() }
            // 原文/markdown:默认 markdown(muted);原文 = active(accent)。
            chip(icon: raw ? "doc.plaintext" : "textformat",
                 active: raw,
                 help: raw ? "切到 markdown 渲染" : "切到原文(不解析)") { raw.toggle() }
            copyChip
        }
    }

    /// 工具条小药丸按钮。`active`(非默认态)时 accent 染色 + 浅底,默认态 muted。
    private func chip(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(active ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.4))
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? ChatCardTheme.accent.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var copyChip: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(ChatCardTheme.accent.opacity(0.7))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label?.isEmpty == false ? "复制\(label!)" : "复制全文")
    }

    // MARK: - 内容(换行 → 直排;不换行 → 横向滚动)

    @ViewBuilder
    private var content: some View {
        if wrap {
            rendered(noWrap: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                rendered(noWrap: true)
            }
        }
    }

    /// 据 raw / diff 分发渲染。`noWrap` 时不折行(交给外层横向滚动)。
    @ViewBuilder
    private func rendered(noWrap: Bool) -> some View {
        if raw {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.82))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: noWrap, vertical: true)
                .frame(maxWidth: noWrap ? nil : .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ChatCardTheme.inputFill.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ChatCardTheme.hairline, lineWidth: 0.5))
        } else if DiffView.looksLikeDiff(text) {
            DiffView(text: text, wrap: !noWrap)
        } else {
            MarkdownTextView(
                content: text, tint: ChatCardTheme.accent,
                maxWidth: noWrap ? Self.noWrapWidth : max(40, maxWidth - 20), baseFont: .system(size: 12, design: .default)
            )
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.82))
            .frame(maxWidth: noWrap ? nil : .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ChatCardTheme.inputFill.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ChatCardTheme.hairline, lineWidth: 0.5))
        }
    }
}
