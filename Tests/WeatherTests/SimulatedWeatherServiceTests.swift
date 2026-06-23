import Foundation
import Testing
@testable import Weather

@Suite("SimulatedWeatherService")
struct SimulatedWeatherServiceTests {
    /// 用固定 Date 注入 service, 让 condition / 温度 / 风速可复现。
    private func service(at iso8601: String) -> SimulatedWeatherService {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let date = fmt.date(from: iso8601) ?? Date(timeIntervalSince1970: 0)
        return SimulatedWeatherService(now: { date })
    }

    @Test("温度落在合理量级 [-10, 10] °C 之内")
    func temperatureInReasonableRange() async throws {
        // 取 24 个小时各采一次,验证全天没有飞出区间的异常值。
        for hour in 0..<24 {
            let svc = service(at: String(format: "2026-01-15T%02d:00:00Z", hour))
            let snap = try await svc.currentWeather(at: .beijing)
            #expect(snap.temperature >= -10 && snap.temperature <= 10)
        }
    }

    @Test("风速恒为非负且不超过 10 m/s")
    func windSpeedInReasonableRange() async throws {
        for hour in 0..<24 {
            let svc = service(at: String(format: "2026-03-10T%02d:00:00Z", hour))
            let snap = try await svc.currentWeather(at: .beijing)
            #expect(snap.windSpeed >= 0 && snap.windSpeed <= 10)
        }
    }

    @Test("不同小时返回不同的 snapshot(不是常量)")
    func differentHoursYieldDifferentSnapshots() async throws {
        let morning = try await service(at: "2026-02-01T03:00:00Z")
            .currentWeather(at: .beijing)
        let afternoon = try await service(at: "2026-02-01T15:00:00Z")
            .currentWeather(at: .beijing)
        // 温度、condition 至少有一项不同。
        #expect(morning.temperature != afternoon.temperature || morning.condition != afternoon.condition)
    }

    @Test("24 小时内 condition 覆盖全部 5 种状态")
    func conditionCoversAllKindsWithinADay() async throws {
        var seen = Set<WeatherConditionKind>()
        for hour in 0..<24 {
            let svc = service(at: String(format: "2026-01-01T%02d:00:00Z", hour))
            let snap = try await svc.currentWeather(at: .beijing)
            seen.insert(snap.condition)
        }
        #expect(seen.count == WeatherConditionKind.allCases.count)
    }

    @Test("windDirection 落在 [0, 360)")
    func windDirectionInValidRange() async throws {
        let svc = service(at: "2026-01-15T12:00:00Z")
        let snap = try await svc.currentWeather(at: .beijing)
        #expect(snap.windDirection >= 0 && snap.windDirection < 360)
    }
}
