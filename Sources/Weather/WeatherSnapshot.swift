import Foundation

/// 一次天气采样的不可变快照。所有字段使用 SI / 国际气象惯例单位,跨边界
/// (Weather → App → Rendering) 不再二次换算,直到 wire 到 GPU 才统一以
/// `Float` 做单位映射(m/s → px/s 等)。
///
/// `Sendable + Equatable` 让 snapshot 能安全跨 actor / isolation 边界传递,
/// 也方便测试用 `#expect(snap == expected)` 比对。
public struct WeatherSnapshot: Sendable, Equatable {
    /// 摄氏度 (°C)。冬日参考范围 -20...10, 夏日 15...40。
    public let temperature: Double
    /// 风速 (m/s),> 0。常态 0...8;极端天气 ≥ 12。
    public let windSpeed: Double
    /// 风向方位角 (度),0 = 正北,顺时针递增。值域 [0, 360)。
    public let windDirection: Double
    /// 收敛后的离散天气状态(便于物理/视觉直接 switch)。
    public let condition: WeatherConditionKind
    /// 采样时间。用于 staleness 判定与 UI"x 分钟前更新"展示。
    public let timestamp: Date

    public init(
        temperature: Double,
        windSpeed: Double,
        windDirection: Double,
        condition: WeatherConditionKind,
        timestamp: Date = Date()
    ) {
        self.temperature = temperature
        self.windSpeed = max(0, windSpeed)
        // 归一到 [0, 360),负值或 > 360 都包裹回正确扇区。
        let wrapped = windDirection.truncatingRemainder(dividingBy: 360)
        self.windDirection = wrapped < 0 ? wrapped + 360 : wrapped
        self.condition = condition
        self.timestamp = timestamp
    }
}
