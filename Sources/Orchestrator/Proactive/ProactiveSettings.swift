// Sources/Orchestrator/Proactive/ProactiveSettings.swift
import Foundation

/// 主动协助全部可调参数的单一真相源（Codable 持久化，照 FallingSandTuning 范式）。
///
/// 设计：节流参数（最小间隔 / 每小时上限 / ignore-decay）做成**只读计算属性**，
/// 从 `level` 查表得出，不单独存储——级别一变全套节流自动跟着变。
/// `dwellThresholdSeconds` 是独立存储的用户可调字段（设置页滑块），默认 600s。
public struct ProactiveSettings: Codable, Sendable, Equatable {
    /// 主动性级别。`.off` = 全关。
    public var level: ProactivityLevel
    /// 场景 A：切换上下文（切到新 app）。
    public var triggerAppSwitch: Bool
    /// 场景 B：idle 回来（离开 >3min 后回来）。
    public var triggerIdleReturn: Bool
    /// 场景 C：卡同一窗口很久（dwell）。默认关——信号最模糊，最易误打扰。
    public var triggerDwell: Bool
    /// 场景 D：深夜关怀。
    public var triggerLateNight: Bool
    /// dwell 判定阈值（秒）。用户可调（设置页滑块 120–900）。默认 600（10min）。
    /// 注：dwell 阈值不随 level 联动，由用户独立控制；设计 §6 表中的 per-level 数值仅为推荐出厂默认，运行时以本字段为准。
    public var dwellThresholdSeconds: TimeInterval
    /// 第 1 层：生命感「碎碎念」预设短语（无 LLM）。默认开——低风险、零成本。
    public var chatterEnabled: Bool
    /// 第 2 层：LLM 自主闲聊（场景 E）。默认关——更费 token / 更易烦，opt-in。
    public var triggerAutonomous: Bool

    public init(
        level: ProactivityLevel = .moderate,
        triggerAppSwitch: Bool = true,
        triggerIdleReturn: Bool = true,
        triggerDwell: Bool = false,
        triggerLateNight: Bool = true,
        dwellThresholdSeconds: TimeInterval = 600,
        chatterEnabled: Bool = true,
        triggerAutonomous: Bool = false
    ) {
        self.level = level
        self.triggerAppSwitch = triggerAppSwitch
        self.triggerIdleReturn = triggerIdleReturn
        self.triggerDwell = triggerDwell
        self.triggerLateNight = triggerLateNight
        self.dwellThresholdSeconds = dwellThresholdSeconds
        self.chatterEnabled = chatterEnabled
        self.triggerAutonomous = triggerAutonomous
    }

    /// 工厂默认：适度·察言观色，A/B/D 开、C 关、dwell 10min；碎碎念开、自主闲聊关。
    public static let `default` = ProactiveSettings()

    // MARK: - Codable 迁移保护

    private enum CodingKeys: String, CodingKey {
        case level, triggerAppSwitch, triggerIdleReturn, triggerDwell, triggerLateNight
        case dwellThresholdSeconds, chatterEnabled, triggerAutonomous
    }

    /// 韧性解码：缺任一字段时回落该字段默认值——上线后加字段不会清空用户既有配置。
    /// （合成 `encode(to:)` 仍可用，无需手写。）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.level = try c.decodeIfPresent(ProactivityLevel.self, forKey: .level) ?? .moderate
        self.triggerAppSwitch = try c.decodeIfPresent(Bool.self, forKey: .triggerAppSwitch) ?? true
        self.triggerIdleReturn = try c.decodeIfPresent(Bool.self, forKey: .triggerIdleReturn) ?? true
        self.triggerDwell = try c.decodeIfPresent(Bool.self, forKey: .triggerDwell) ?? false
        self.triggerLateNight = try c.decodeIfPresent(Bool.self, forKey: .triggerLateNight) ?? true
        self.dwellThresholdSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .dwellThresholdSeconds) ?? 600
        self.chatterEnabled = try c.decodeIfPresent(Bool.self, forKey: .chatterEnabled) ?? true
        self.triggerAutonomous = try c.decodeIfPresent(Bool.self, forKey: .triggerAutonomous) ?? false
    }

    // MARK: - 节流参数（从 level 查表，只读）

    /// 最小触发间隔（秒）。`.off` = ∞（不触发）。
    public var minIntervalSeconds: TimeInterval {
        switch level {
        case .off:        return .infinity
        case .restrained: return 1800
        case .moderate:   return 600
        case .active:     return 180
        }
    }

    /// 每小时触发条数上限。`.off` = 0。
    public var maxPerHour: Int {
        switch level {
        case .off:        return 0
        case .restrained: return 2
        case .moderate:   return 4
        case .active:     return 8
        }
    }

    /// 每攒满几次连续忽略，冷却乘 multiplier 一次。
    public var ignoreDecayThreshold: Int {
        switch level {
        case .off:        return 1
        case .restrained: return 2
        case .moderate:   return 3
        case .active:     return 5
        }
    }

    /// ignore-decay 冷却乘数。
    public var ignoreDecayMultiplier: Double {
        switch level {
        case .off:        return 1.0
        case .restrained: return 2.0
        case .moderate:   return 1.5
        case .active:     return 1.2
        }
    }

    // MARK: - 自主节奏间隔（从 level 查表，nil = 该级别不触发该层）

    /// 第 1 层碎碎念触发间隔区间（秒）。off/restrained 不触发（nil）。
    public var chatterIntervalRange: ClosedRange<TimeInterval>? {
        switch level {
        case .off, .restrained: return nil
        case .moderate:         return 300...600   // 5–10 min
        case .active:           return 120...300   // 2–5 min
        }
    }

    /// 第 2 层 LLM 自主闲聊触发间隔区间（秒）。仅 active 开（默认还需 triggerAutonomous=true）。
    public var autonomousIntervalRange: ClosedRange<TimeInterval>? {
        switch level {
        case .off, .restrained, .moderate: return nil
        case .active:                      return 600...1200  // 10–20 min
        }
    }
}
