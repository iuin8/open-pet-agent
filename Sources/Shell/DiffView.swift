import SwiftUI

/// 行级红/绿背景的 diff 视图(GitHub/diffview 式)。整行整宽染色,等宽字体,逐行可选。
/// 跨行连续选择会被逐行容器打断(取舍:行级背景 > 跨行选择;单行仍可选 + 复制按钮在外层给全文)。
///
/// `wrap`(默认 true):折行;false = 不折行(`DetailContentView` 不换行模式外套横向滚动时用)。
/// 详情统一渲染入口在 `DetailContentView`(diff→本视图,其余→`MarkdownTextView`)。
struct DiffView: View {
    let text: String
    var wrap: Bool = true

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let kind = DiffLineKind(line)
                Text(line.isEmpty ? " " : String(line))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(kind.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: !wrap, vertical: true)
                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1.5)
                    .background(kind.background)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(ChatCardTheme.hairline, lineWidth: 0.5)
        )
    }

    /// 判定整块是否该走 diff 渲染:含 `@@` hunk 头(git diff),或**每条非空行都 `+`/`-` 开头**(Edit 工具 old/new 块)。
    /// 不会把偶然含一两行 `- ` 的命令/日志误判成 diff。
    static func looksLikeDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        if lines.contains(where: { $0.hasPrefix("@@") }) { return true }
        let pm = lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.count
        return pm == lines.count
    }
}

/// diff 行类型 → 前景/背景色(配暖奶油卡片调过,不刺眼)。
@MainActor
private enum DiffLineKind {
    case added, removed, hunk, meta, context

    init(_ line: Substring) {
        if line.hasPrefix("@@") { self = .hunk }
        else if line.hasPrefix("+++") || line.hasPrefix("---")
                || line.hasPrefix("diff ") || line.hasPrefix("index ") { self = .meta }
        else if line.hasPrefix("+") { self = .added }
        else if line.hasPrefix("-") { self = .removed }
        else { self = .context }
    }

    var background: Color {
        switch self {
        case .added:   return DiffText.added.opacity(0.14)
        case .removed: return DiffText.removed.opacity(0.13)
        case .hunk:    return ChatCardTheme.accent.opacity(0.10)
        case .meta, .context: return .clear
        }
    }

    var foreground: Color {
        switch self {
        case .added:   return DiffText.added
        case .removed: return DiffText.removed
        case .hunk:    return ChatCardTheme.accent.opacity(0.85)
        case .meta:    return ChatCardTheme.textPrimary.opacity(0.45)
        case .context: return ChatCardTheme.textPrimary.opacity(0.8)
        }
    }
}
