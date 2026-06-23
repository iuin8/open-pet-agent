import Foundation
import Testing
@testable import Weather

// MARK: - Test doubles

/// 永远成功的 provider, 返回固定 snapshot。
private struct StubSuccessProvider: WeatherDataProvider {
    let snapshot: WeatherSnapshot
    func currentWeather(at location: LocationCoordinate) async throws -> WeatherSnapshot {
        snapshot
    }
}

/// 永远报错的 provider, 用于验证降级路径。
private struct StubFailingProvider: WeatherDataProvider {
    struct StubError: Error {}
    func currentWeather(at location: LocationCoordinate) async throws -> WeatherSnapshot {
        throw StubError()
    }
}

/// 一个 actor 容器, 让测试在多个 Task 闭包之间共享可变状态而不踩 Swift 6
/// strict concurrency 红线。`onUpdate` 闭包是 `@MainActor`, 但测试断言
/// 在 `@Test` 函数体里跑 —— 用 actor 做 cross-isolation handoff。
@MainActor
private final class CaptureBox {
    var snapshots: [WeatherSnapshot] = []
    func append(_ snapshot: WeatherSnapshot) { snapshots.append(snapshot) }
}

// MARK: - Tests

@Suite("WeatherStateManager")
@MainActor
struct WeatherStateManagerTests {
    @Test("start 立刻 fetch 一次, currentSnapshot 不为 nil")
    func startTriggersImmediateFetch() async throws {
        let expected = WeatherSnapshot(
            temperature: 3.0,
            windSpeed: 2.0,
            windDirection: 45,
            condition: .snowy
        )
        let box = CaptureBox()
        let manager = WeatherStateManager(
            provider: StubSuccessProvider(snapshot: expected),
            refreshInterval: 60
        )
        manager.onUpdate = { snap in
            box.append(snap)
        }
        await manager.start()
        manager.stop()

        #expect(manager.currentSnapshot == expected)
        #expect(box.snapshots.contains(expected))
    }

    @Test("provider 失败且无缓存时, 用 SimulatedWeatherService 兜底")
    func failureFallsBackToSimulatedWhenNoCache() async throws {
        let box = CaptureBox()
        let manager = WeatherStateManager(
            provider: StubFailingProvider(),
            refreshInterval: 60
        )
        manager.onUpdate = { snap in
            box.append(snap)
        }
        await manager.start()
        manager.stop()

        // 兜底逻辑触发, currentSnapshot 至少不为 nil。
        #expect(manager.currentSnapshot != nil)
        #expect(!box.snapshots.isEmpty)
    }

    @Test("provider 失败但已有缓存时, currentSnapshot 不被清空")
    func failureKeepsExistingSnapshot() async throws {
        let cached = WeatherSnapshot(
            temperature: -2.0,
            windSpeed: 1.5,
            windDirection: 180,
            condition: .cloudy
        )
        // 第一次成功填上缓存, 第二次开始 fail。
        actor SwitchingProvider: WeatherDataProvider {
            let first: WeatherSnapshot
            private var callCount = 0
            init(first: WeatherSnapshot) { self.first = first }
            func currentWeather(at location: LocationCoordinate) async throws -> WeatherSnapshot {
                callCount += 1
                if callCount == 1 {
                    return first
                }
                throw StubFailingProvider.StubError()
            }
        }
        let manager = WeatherStateManager(
            provider: SwitchingProvider(first: cached),
            refreshInterval: 60
        )
        await manager.start()
        // 第一次成功后, 手动触发 refresh 让它走失败路径。
        await manager.refresh()
        manager.stop()

        #expect(manager.currentSnapshot == cached)
    }

    @Test("stop 之后 currentSnapshot 保持不变")
    func stopPreservesLastSnapshot() async throws {
        let expected = WeatherSnapshot(
            temperature: 0,
            windSpeed: 4,
            windDirection: 270,
            condition: .windy
        )
        let manager = WeatherStateManager(
            provider: StubSuccessProvider(snapshot: expected),
            refreshInterval: 60
        )
        await manager.start()
        manager.stop()
        let after = manager.currentSnapshot
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(manager.currentSnapshot == after)
    }

    @Test("强制 snowy 时温度也强制为冷（雪不被夏季真实气温融成水）")
    func forcedSnowyOverridesTemperatureToCold() async throws {
        // 真实天气是夏季 30°C（归一化 0.83 >> melt 0.50）。
        let summer = WeatherSnapshot(
            temperature: 30.0,
            windSpeed: 2.0,
            windDirection: 0,
            condition: .sunny
        )
        let manager = WeatherStateManager(
            provider: StubSuccessProvider(snapshot: summer),
            refreshInterval: 60
        )
        await manager.start()
        manager.updateForcedCondition(.snowy)
        manager.stop()
        // 强制 snowy → condition=snowy 且温度=代表冷温（-5°C），不再是 30°C。
        #expect(manager.currentSnapshot?.condition == .snowy)
        #expect(manager.currentSnapshot?.temperature == WeatherConditionKind.snowy.representativeTemperatureC)
        #expect((manager.currentSnapshot?.temperature ?? 99) < 10)   // 低于 melt 阈值对应温度
    }

    @Test("重复 start 不泄漏旧 timer, currentSnapshot 仍能更新")
    func restartIsSafe() async throws {
        let snap = WeatherSnapshot(
            temperature: 6,
            windSpeed: 2,
            windDirection: 0,
            condition: .sunny
        )
        let manager = WeatherStateManager(
            provider: StubSuccessProvider(snapshot: snap),
            refreshInterval: 60
        )
        await manager.start()
        await manager.start()  // 第二次启动, 旧 timer 应该被 invalidate
        manager.stop()
        #expect(manager.currentSnapshot == snap)
    }
}
