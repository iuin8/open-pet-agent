// Sources/Orchestrator/Proactive/ProactiveThrottleState.swift
import Foundation

/// 防打扰节流核（immutable 值类型，纯函数，Date 全注入 → 确定性单测）。
///
/// 三道闸（`decide`）：off → 冷却内（含 ignore-decay 衰减，硬 cap 4×base 防永久静默）
/// → 近 1h 配额满。`record*` 返回**新 state**（不就地改）。
public struct ProactiveThrottleState: Equatable, Sendable {
    /// 上次触发时间（nil = 从未触发）。
    public var lastFiredAt: Date?
    /// 近 60min 触发时间滑窗（decide 时 evict 过期）。
    public var recentFiredTimes: [Date]
    /// 连续被忽略次数（decay 用；engaged 归零）。
    public var consecutiveIgnoreCount: Int

    public init(
        lastFiredAt: Date? = nil,
        recentFiredTimes: [Date] = [],
        consecutiveIgnoreCount: Int = 0
    ) {
        self.lastFiredAt = lastFiredAt
        self.recentFiredTimes = recentFiredTimes
        self.consecutiveIgnoreCount = consecutiveIgnoreCount
    }

    /// 三道闸顺序：off → 冷却（含 decay）→ 每小时配额。
    public func decide(settings: ProactiveSettings, now: Date) -> Bool {
        guard settings.level != .off else { return false }

        if let last = lastFiredAt {
            let steps = settings.ignoreDecayThreshold > 0
                ? consecutiveIgnoreCount / settings.ignoreDecayThreshold
                : 0
            let multiplier = pow(settings.ignoreDecayMultiplier, Double(steps))
            let effective = min(
                settings.minIntervalSeconds * multiplier,
                4 * settings.minIntervalSeconds
            )
            if now.timeIntervalSince(last) < effective { return false }
        }

        let recentCount = recentFiredTimes.filter { now.timeIntervalSince($0) < 3600 }.count
        if recentCount >= settings.maxPerHour { return false }

        return true
    }

    /// 记一次触发：set lastFiredAt + append 滑窗（顺带 evict 过期）。不动 ignoreCount。
    public func recordFired(now: Date) -> ProactiveThrottleState {
        var copy = self
        copy.lastFiredAt = now
        copy.recentFiredTimes = (recentFiredTimes + [now]).filter { now.timeIntervalSince($0) < 3600 }
        return copy
    }

    /// 记一次被忽略（气泡超时归零且用户未互动）。
    public func recordIgnored() -> ProactiveThrottleState {
        var copy = self
        copy.consecutiveIgnoreCount += 1
        return copy
    }

    /// 记一次被采纳（用户因建议召唤 chat）→ 归零 decay 恢复节奏。
    public func recordEngaged() -> ProactiveThrottleState {
        var copy = self
        copy.consecutiveIgnoreCount = 0
        return copy
    }
}
