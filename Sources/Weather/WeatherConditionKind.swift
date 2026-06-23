import Foundation

/// 天气状态的离散分类。覆盖物理沙盒目前消费的五种基本条件:
///
/// - `.sunny` / `.cloudy` 不触发降水
/// - `.rainy` / `.snowy` 触发对应粒子系统
/// - `.windy` 提示外部风速基线更高
///
/// 后续接入真实 WeatherKit 时, `WeatherCondition` 会被映射到这个收敛的枚举,
/// 让 Rendering 侧只面对一份稳定的语义。
public enum WeatherConditionKind: String, Sendable, CaseIterable, Codable {
    case sunny
    case cloudy
    case rainy
    case snowy
    case windy

    /// 强制该天气条件时使用的代表气温(°C)。让「强制天气」自洽:强制雪→冷(雪落地
    /// 不立即融成水平铺滑走)、强制雨→温(雨保持液态不冻成冰)。真实(auto)天气不走
    /// 这里。归一化映射见 fallingSandAmbientTemperature:(°C+20)/60;物理阈值
    /// melt=0.50≈10°C、freeze=0.42≈5°C。
    public var representativeTemperatureC: Double {
        switch self {
        case .snowy:  return -5   // 归一 0.25:远低于 melt(0.50) → 雪堆积不融
        case .rainy:  return 12   // 归一 0.53:高于 freeze(0.42) → 雨保持液态
        case .cloudy: return 15
        case .windy:  return 14
        case .sunny:  return 26
        }
    }
}
