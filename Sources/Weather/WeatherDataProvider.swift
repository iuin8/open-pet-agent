import Foundation

/// 经纬度坐标。**不依赖 CoreLocation**(SwiftPM CLI app 没法弹 TCC 权限,
/// 真接 CoreLocation 反而招致系统 dialog 莫名其妙就拦截了启动)。后续若
/// 真接 CoreLocation,会在 App 层包装一个 `CoreLocationCoordinateAdapter`,
/// 把 `CLLocationCoordinate2D` 映射到这个值类型。
public struct LocationCoordinate: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 默认硬编码城市。北京冬季典型可触发 snowy / windy 条件,便于
    /// 物理沙盒在没有真实 WeatherKit 的开发阶段产生足够"有变化"的输入。
    public static let beijing = LocationCoordinate(latitude: 39.9042, longitude: 116.4074)
}

/// 天气数据 provider 协议。生产路径用 `SimulatedWeatherService`,
/// 后续接 WeatherKit 时实现一个 `WeatherKitService` 注入即可,
/// `WeatherStateManager` 与 `GPUSnowCoordinator` 都不需要修改。
public protocol WeatherDataProvider: Sendable {
    /// 拉一次该坐标的当前天气。失败时抛错,由 manager 决定降级策略。
    func currentWeather(at location: LocationCoordinate) async throws -> WeatherSnapshot
}
