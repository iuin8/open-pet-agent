import Context
import Foundation

/// 把 `DesktopSnapshot` 的可见窗口（含标题）格式化成注入 LLM 系统提示的「桌面窗口」上下文行。
///
/// 纯函数、带预算（防 token 膨胀）：保留 CGWindowList 的前→后 z-order（前台窗口在最前），
/// 截断过长标题，封顶窗口数，其余折叠成「另有 K 个」。只用窗口标题（`kCGWindowName`），
/// 不读任何正文/选中内容——感知加深的「标题层」边界。
public enum DesktopContextFormatter {
    /// 产出「桌面窗口」上下文行（无可见窗口时返回空数组，调用方据此决定是否追加）。
    /// - Parameters:
    ///   - snapshot: 桌面快照。
    ///   - selfApplicationName: OpenPetAgent 自身应用名——按名再兜一层过滤（provider 已按 PID 过滤）。
    ///   - maxWindows: 最多逐条列出几个窗口；其余折叠成「另有 K 个窗口」。
    ///   - maxTitleLength: 单个标题最大字符数，超出截断加省略号。
    public static func windowContextLines(
        snapshot: DesktopSnapshot,
        selfApplicationName: String? = nil,
        maxWindows: Int = 6,
        maxTitleLength: Int = 60
    ) -> [String] {
        let windows = snapshot.visibleWindows.filter { $0.ownerName != selfApplicationName }
        guard !windows.isEmpty else { return [] }

        var lines: [String] = ["- 桌面窗口（前台在最前）："]
        for window in windows.prefix(max(0, maxWindows)) {
            if let title = window.title, !title.isEmpty {
                lines.append("  · \(window.ownerName) — \(truncate(title, max: maxTitleLength))")
            } else {
                lines.append("  · \(window.ownerName)")
            }
        }
        let overflow = windows.count - max(0, maxWindows)
        if overflow > 0 {
            lines.append("  （另有 \(overflow) 个窗口）")
        }
        return lines
    }

    /// 截断字符串到 `max` 个字符（超出时末尾加省略号）。
    static func truncate(_ string: String, max: Int) -> String {
        guard max >= 1, string.count > max else { return string }
        return String(string.prefix(max - 1)) + "…"
    }
}
