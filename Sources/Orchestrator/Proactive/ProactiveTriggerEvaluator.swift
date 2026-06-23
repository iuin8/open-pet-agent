// Sources/Orchestrator/Proactive/ProactiveTriggerEvaluator.swift
import Foundation

/// 纯函数判定器：给定一个候选信号 + 设置 + 当前小时/睡眠态，判断是否构成有效触发。
/// 零副作用零 IO，确定性单测无 mock。多场景同 tick 的优先级（dwell > lateNight）
/// 由 `ProactiveSuggestionEngine.tick` 的调用顺序保证，本层只做单信号的开关 + 条件 gate。
public enum ProactiveTriggerEvaluator {
    /// 深夜窗口：23:00–04:59。
    // 深夜窗口 23:00–04:59 为产品决策，固定不可由用户配置（见设计 §12 openQuestion 2）。
    private static func isLateNight(hour: Int) -> Bool { hour >= 23 || hour < 5 }

    public static func evaluate(
        signal: ProactiveSignal,
        settings: ProactiveSettings,
        hour: Int,
        isSleeping: Bool
    ) -> TriggerKind? {
        guard settings.level != .off else { return nil }
        switch signal.kind {
        case .appSwitch:
            let hasApp = (signal.appName?.isEmpty == false)
            return (settings.triggerAppSwitch && hasApp) ? .appSwitch : nil
        case .idleReturn:
            let away = signal.awaySeconds ?? 0
            return (settings.triggerIdleReturn && away >= 180) ? .idleReturn : nil
        case .dwell:
            let dwell = signal.dwellSeconds ?? 0
            return (settings.triggerDwell && !isSleeping && dwell >= settings.dwellThresholdSeconds) ? .dwell : nil
        case .lateNight:
            return (settings.triggerLateNight && !isSleeping && isLateNight(hour: hour)) ? .lateNight : nil
        case .autonomous:
            // 场景 E：开关开 + 非睡眠即构成候选；时段节奏由引擎 autonomousIntervalRange 控制，本层不管间隔。
            return (settings.triggerAutonomous && !isSleeping) ? .autonomous : nil
        case .chatter:
            // 碎碎念是预设短语，不走判定器（引擎直接 sink，见 ProactiveSuggestionEngine.tick）。
            return nil
        }
    }
}
