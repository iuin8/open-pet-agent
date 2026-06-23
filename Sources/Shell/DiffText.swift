import SwiftUI

/// 把工具详情文本渲染成可选 diff 着色的 `AttributedString`(P3.8 G1)。
///
/// 当整块**每条非空行都以 `- ` 或 `+ ` 开头**(= `ClaudeTranscriptParser` 给 Edit 工具构造的
/// old/new 前后对照)时,按行染红(删)/绿(增);否则原样(纯等宽)。只在「整块都是 diff 行」才着色
/// → 不会误染普通命令/JSON/输出里偶然 `- `/`+ ` 开头的行。
///
/// 用单个 `Text(AttributedString)` 渲染(而非 VStack 多 `Text`)→ 跨行文本选择不被打断。
enum DiffText {
    /// 删行红 / 增行绿 —— 配暖奶油卡片调过,不刺眼。
    static let removed = Color(red: 0.74, green: 0.23, blue: 0.19)
    static let added = Color(red: 0.17, green: 0.52, blue: 0.31)

    /// 整块是否是 diff:每条非空行都 `- `/`+ ` 开头,且至少有一条。
    static func isDiff(_ text: String) -> Bool {
        var any = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            if line.hasPrefix("- ") || line.hasPrefix("+ ") { any = true } else { return false }
        }
        return any
    }

    /// 按 diff 行着色;非 diff → 整块 `base` 色。
    static func attributed(_ text: String, base: Color) -> AttributedString {
        guard isDiff(text) else {
            var whole = AttributedString(text)
            whole.foregroundColor = base
            return whole
        }
        var result = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            var seg = AttributedString(String(line))
            if line.hasPrefix("- ") { seg.foregroundColor = removed }
            else if line.hasPrefix("+ ") { seg.foregroundColor = added }
            else { seg.foregroundColor = base }
            result += seg
            if i < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
