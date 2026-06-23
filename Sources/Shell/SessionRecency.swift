import Foundation

/// 会话 picker 的时间呈现纯函数 —— 相对时间短格式 + 「是否仍活跃」判定。
///
/// 抽成可注入 `now` 的纯函数(视图里传 `Date()`)→ 无头确定性单测,不靠截图验时间文案。
public enum SessionRecency {

    /// 紧凑相对时间:`<1m → 刚刚`、`<1h → Nm`、`<1d → Nh`、否则 `Nd`(仿 claude-devtools `formatShortTime`)。
    public static func shortRelative(from date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60:    return "刚刚"
        case ..<3600:  return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        default:       return "\(Int(s / 86_400))d"
        }
    }

    /// 会话是否仍活跃 = 文件在 `window` 秒内被改过(picker 绿点)。无 `lastModified` → false。
    public static func isOngoing(lastModified: Date?, now: Date, window: TimeInterval = 30) -> Bool {
        guard let lastModified else { return false }
        return now.timeIntervalSince(lastModified) < window
    }
}
