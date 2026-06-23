import Foundation

/// 全应用唯一的天气状态源,负责:
/// 1. 启动时立刻拉一次 snapshot,把 `currentSnapshot` 从 nil 填上;
/// 2. 每 `refreshInterval` 秒(默认 15min)再拉一次;
/// 3. provider 报错时降级:保留上一次 snapshot,**继续**下一个 Timer cycle,
///    永远不让 manager 进入死状态;
/// 4. 每次成功更新,把新 snapshot 通过 `onUpdate` 回调给观察者(MinimalAppDelegate
///    会在此回调里把风/温写进 `GPUSnowCoordinator`)。
///
/// `@MainActor` 锁主线程: Timer.scheduledTimer 触发的 closure 默认就在
/// main RunLoop, 把整个 manager 钉在 MainActor 上避免任何 isolation 误用。
/// `onUpdate` 也声明为 `@MainActor`, GPUSnowCoordinator 在 MainActor 上写
/// `pileAmbientTemperature` / `externalBaseWindX` 无需额外 hop。
@MainActor
public final class WeatherStateManager {
    public typealias UpdateHandler = @MainActor (WeatherSnapshot) -> Void

    private let provider: any WeatherDataProvider
    /// 当前查询坐标。`var` 让 Settings 城市 picker 能运行时切换 — 切完
    /// 调用 `updateLocation(_:)` 立刻 fetch 一次, 不等下个 15min cycle。
    public private(set) var location: LocationCoordinate
    private let refreshInterval: TimeInterval
    private var timer: Timer?

    /// 最近一次成功拉到的 snapshot。第一次 `start` 之前为 nil;
    /// 第一次 fetch 失败 + 没有缓存时,会用 `SimulatedWeatherService` 同步
    /// 兜底(保证后续观察者总能拿到合理数据)。
    public private(set) var currentSnapshot: WeatherSnapshot?

    /// 每次成功更新触发的回调。MinimalAppDelegate 在此 closure 内做实际 wire。
    public var onUpdate: UpdateHandler?

    /// 用户在 Settings 强制覆盖的 condition。nil = 跟随真实天气(默认)。
    /// 设值后立刻 re-emit 一次当前 snapshot 让物理沙盒立即响应,不等下个
    /// 15min cycle 才生效。
    public private(set) var forcedCondition: WeatherConditionKind?

    public init(
        provider: any WeatherDataProvider = SimulatedWeatherService(),
        location: LocationCoordinate = .beijing,
        refreshInterval: TimeInterval = 15 * 60
    ) {
        self.provider = provider
        self.location = location
        self.refreshInterval = refreshInterval
    }

    /// 启动:立刻 fetch 一次(await 完成才返回),然后按 `refreshInterval`
    /// 周期复 fetch。重复调用安全 — 旧 timer 先 invalidate, 不会泄漏。
    ///
    /// async 设计:让 caller (生产: MinimalAppDelegate; 测试: WeatherStateManagerTests)
    /// 都能确定性等首次 fetch 完成,不再依赖 Task.sleep 等 race。生产端
    /// 用 `Task { await manager.start() }` wrap 即可。
    public func start() async {
        timer?.invalidate()
        let scheduled = Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        // 跟 IdleStateTracker / BondedBubbleChain 同款: common 模式让 Timer
        // 在 modal / tracking RunLoop 也跑, 否则用户拖窗口/打开菜单时会停 tick。
        RunLoop.main.add(scheduled, forMode: .common)
        self.timer = scheduled

        // 立刻 fetch 一次, await 完成才返回。让 GPUSnowCoordinator 启动后
        // 第一帧就能拿到真实风/温度,而不是先用 init-time 常量跑 15 分钟。
        await refresh()
    }

    /// 切换查询城市。立刻触发一次 fetch,不等下个 15min cycle —— 让 Settings
    /// "保存" 后用户立即看到新城市天气驱动雪 simulation。
    public func updateLocation(_ newLocation: LocationCoordinate) async {
        guard newLocation != location else { return }
        location = newLocation
        await refresh()
    }

    /// 设置 / 清除强制 condition。设置后立刻 re-emit 当前 snapshot,让物理
    /// 沙盒立即按新 condition 走(无需等下次 refresh)。
    public func updateForcedCondition(_ kind: WeatherConditionKind?) {
        forcedCondition = kind
        if let snap = currentSnapshot {
            // currentSnapshot 已经是 effective(refresh 时应用过 forced),
            // 这里需要从"原始" 重建。简化:直接用原 temperature/wind +
            // 新 forced condition 重新 emit。
            let newSnap = WeatherSnapshot(
                // 强制条件→自洽代表温度（强制雪用冷温，雪落地不立即融成水平铺滑走）；
                // 清除强制（kind=nil）→ 回落原温度，下次 refresh 再用真实值校准。
                temperature: kind?.representativeTemperatureC ?? snap.temperature,
                windSpeed: snap.windSpeed,
                windDirection: snap.windDirection,
                condition: kind ?? snap.condition,
                timestamp: snap.timestamp
            )
            currentSnapshot = newSnap
            onUpdate?(newSnap)
        }
    }

    /// 停止:invalidate timer。currentSnapshot 保留,便于 stop/start 复用。
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 单次刷新。私有,但暴露给测试通过 `await manager.refreshForTest()` 触发
    /// (`@_spi` 后续再加, 当前测试通过 closure 注入 provider 然后调 start 验证)。
    internal func refresh() async {
        do {
            let rawSnapshot = try await provider.currentWeather(at: location)
            let snapshot = applyForcedCondition(to: rawSnapshot)
            currentSnapshot = snapshot
            onUpdate?(snapshot)
        } catch {
            // provider 失败的两种情况:
            // 1. 已有缓存 — 保持不动, 下个 cycle 再试。物理沙盒继续用上次的数据。
            // 2. 首次拉失败且无缓存 — 用 simulated 同步兜底, 让观察者不会卡在 nil。
            if currentSnapshot == nil {
                let fallback = SimulatedWeatherService()
                if let rawSnapshot = try? await fallback.currentWeather(at: location) {
                    let snapshot = applyForcedCondition(to: rawSnapshot)
                    currentSnapshot = snapshot
                    onUpdate?(snapshot)
                }
            }
        }
    }

    /// 如果设置了 forcedCondition,把 raw snapshot 的 condition 覆盖掉。
    private func applyForcedCondition(to raw: WeatherSnapshot) -> WeatherSnapshot {
        guard let forced = forcedCondition else { return raw }
        return WeatherSnapshot(
            // 温度也跟随强制条件（强制雪→冷，否则夏季真实气温会把雪立即融成水）。
            temperature: forced.representativeTemperatureC,
            windSpeed: raw.windSpeed,
            windDirection: raw.windDirection,
            condition: forced,
            timestamp: raw.timestamp
        )
    }
}
