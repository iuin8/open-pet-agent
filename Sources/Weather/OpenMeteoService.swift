import Foundation

/// Open-Meteo 真实天气 provider。
///
/// 选 Open-Meteo 而非 Apple WeatherKit 的原因:
/// - 完全免费,**不需 API key**,**不需 com.apple.developer.weatherkit
///   entitlement**(后者需要 Apple Developer Program 付费账号 + 签名 bundle)
/// - 文档 https://open-meteo.com/en/docs,Apache 2 许可
/// - JSON 直接对应 `WeatherSnapshot` 各字段,无适配层
///
/// 网络失败由 `WeatherStateManager.refresh()` 已有的失败降级路径接住
/// (自动 fallback 到 `SimulatedWeatherService`),所以这里只需要简单 throw。
public struct OpenMeteoService: WeatherDataProvider {
    /// 注入式 URLSession,生产用 `.shared`,测试用 stub。
    public let session: URLSession
    /// 注入式 JSONDecoder,便于测试预配置策略。
    public let decoder: JSONDecoder

    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.session = session
        self.decoder = decoder
    }

    public func currentWeather(at location: LocationCoordinate) async throws -> WeatherSnapshot {
        let url = Self.buildURL(for: location)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenMeteoError.badResponse(response)
        }
        let payload = try decoder.decode(OpenMeteoResponse.self, from: data)
        return payload.current.toSnapshot()
    }

    /// 构造 forecast endpoint URL,固定查询当前的 4 个字段。
    /// `current=temperature_2m,wind_speed_10m,wind_direction_10m,weather_code`
    /// 是 Open-Meteo v1 推荐的"实时"参数组。
    internal static func buildURL(for location: LocationCoordinate) -> URL {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,wind_speed_10m,wind_direction_10m,weather_code"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return comps.url!
    }
}

// MARK: - Errors

public enum OpenMeteoError: Error, CustomStringConvertible {
    case badResponse(URLResponse)

    public var description: String {
        switch self {
        case .badResponse(let r):
            return "OpenMeteo bad response: \(r)"
        }
    }
}

// MARK: - Wire types

/// Open-Meteo `/v1/forecast` 的 current 子对象。字段名跟 API 一一对应。
internal struct OpenMeteoResponse: Decodable {
    let current: Current

    struct Current: Decodable {
        let time: String
        let temperature_2m: Double
        let wind_speed_10m: Double
        let wind_direction_10m: Double
        let weather_code: Int

        /// 把 Open-Meteo 字段映射到 `WeatherSnapshot`。temperature 已经是 °C,
        /// wind_speed 因为我们传了 `wind_speed_unit=ms` 已经是 m/s。
        func toSnapshot() -> WeatherSnapshot {
            WeatherSnapshot(
                temperature: temperature_2m,
                windSpeed: wind_speed_10m,
                windDirection: wind_direction_10m,
                condition: Self.mapWMO(code: weather_code),
                timestamp: Date()
            )
        }

        /// WMO 天气代码 → `WeatherConditionKind`。覆盖 Open-Meteo 实际下发
        /// 的代码段(https://open-meteo.com/en/docs)。未识别代码统一归
        /// cloudy(物理沙盒安全 fallback)。
        static func mapWMO(code: Int) -> WeatherConditionKind {
            switch code {
            case 0: return .sunny
            case 1, 2, 3, 45, 48: return .cloudy
            case 51...67, 80...82, 95...99: return .rainy
            case 71...77, 85, 86: return .snowy
            default: return .cloudy
            }
        }
    }
}
