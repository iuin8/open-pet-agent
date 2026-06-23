import Foundation

/// 不依赖外部网络的假天气 provider。基于本地时间小时数 + 简单数学函数,
/// 周期性切换 condition,让物理沙盒在没有 WeatherKit entitlement 的开发
/// 阶段也能看到"温度变化驱动融雪"、"风速变化驱动雪粒漂移"的真实效果。
///
/// 设计目标:
/// - 取值范围合理(温度 -10...10°C, 风速 1...8 m/s)
/// - 一天内有可观察的渐变,不是一个常数
/// - 周期内必经过所有 `WeatherConditionKind` 至少一次,便于联调
public struct SimulatedWeatherService: WeatherDataProvider {
    /// 注入时钟,测试里可以用固定 Date 让结果可复现。
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func currentWeather(at location: LocationCoordinate) async throws -> WeatherSnapshot {
        let date = now()
        let cal = Calendar(identifier: .gregorian)
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        // 把"小时 + 分钟"折算成 [0, 24) 的连续相位,让 condition 与
        // 温度在一天内平滑过渡而不是只在整点跳变。
        let phase = Double(hour) + Double(minute) / 60.0

        // 温度: 以 0°C 为基线 + 8°C 振幅的正弦波,低谷在凌晨 4 点附近,
        // 峰值在下午 4 点附近 — 模拟现实昼夜温差。值域大致 -8...8°C。
        let tempPhase = (phase - 4.0) / 24.0 * 2.0 * .pi
        let temperature = 0.0 + 8.0 * sin(tempPhase)

        // 风速: 4 小时为一周期, 1...8 m/s 振荡, 让 windy condition 周期性出现。
        let windPhase = phase / 4.0 * 2.0 * .pi
        let windSpeed = 4.5 + 3.5 * sin(windPhase)

        // 风向: 每小时旋转 15°, 24 小时正好转 360°。
        let windDirection = (phase * 15.0).truncatingRemainder(dividingBy: 360)

        // condition: 按 hour % 5 切换, 覆盖五种状态。冬季夜里偏向 snowy,
        // 中午偏向 sunny — 让 simulated 数据看起来"像那么回事"。
        let condition: WeatherConditionKind = {
            switch hour % 5 {
            case 0: return .snowy
            case 1: return .cloudy
            case 2: return .sunny
            case 3: return .windy
            default: return .rainy
            }
        }()

        return WeatherSnapshot(
            temperature: temperature,
            windSpeed: windSpeed,
            windDirection: windDirection,
            condition: condition,
            timestamp: date
        )
    }
}
