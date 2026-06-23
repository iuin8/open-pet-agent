import Foundation

/// 「温度模式」覆盖档 —— 从状态栏菜单迁移到 设置 → 天气 tab。
///
/// 物理沙盒的环境温度默认由天气系统驱动（真实 / 强制天气 → 归一化 ambient）。
/// 本枚举提供一个**手动覆盖**：
///   - `auto`  = 跟随天气（不覆盖，ambient 由 WeatherStateManager 写）
///   - 具体档  = 用该档固定 ambient 覆盖 `fallingSandAmbientTemperature`，无视天气，
///              直到切回 auto。
///
/// ambient 归一化约定 (°C+20)/60；`FallingSandRules.meltThreshold = 0.50 ≈ 10°C`：
/// winter 远低于阈值 → 雪不融；spring 近阈值 → 光标扫过 / 局部融；sauna 高于 → 全场融。
/// 旧 `MenuBarController.ThermalMode` 的三档 ambient 值（0.05 / 0.22 / 0.55）原样迁移。
public enum ThermalOverrideMode: String, CaseIterable, Sendable {
    case auto
    case winter
    case spring
    case sauna

    /// 覆盖用的归一化 ambient 温度；`auto` 返回 nil（跟随天气，不覆盖）。
    public var ambientTemperature: Float? {
        switch self {
        case .auto:   return nil
        case .winter: return 0.05
        case .spring: return 0.22
        case .sauna:  return 0.55
        }
    }

    /// Picker / 菜单显示名。
    public var displayName: String {
        switch self {
        case .auto:   return "跟随天气"
        case .winter: return "❄️ 雪天（不融化）"
        case .spring: return "🌤️ 早春（光标融化）"
        case .sauna:  return "🔥 烤箱（全场融化）"
        }
    }

    /// 从 UD raw 还原，未知值回落 `auto`。
    public static func from(raw: String) -> ThermalOverrideMode {
        ThermalOverrideMode(rawValue: raw) ?? .auto
    }

    /// SwiftUI Picker 用的选项列表（auto 在最前，与 forcedCondition 列表风格一致）。
    public static let options: [(id: String, displayName: String)] =
        ThermalOverrideMode.allCases.map { ($0.rawValue, $0.displayName) }
}
