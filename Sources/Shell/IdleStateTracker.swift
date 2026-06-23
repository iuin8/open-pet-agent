import AppKit
import CoreGraphics

/// 系统空闲检测 —— 用 `CGEventSource.secondsSinceLastEventType` 看用户多久没动
/// 鼠标/键盘了。超过阈值(默认 3 分钟)→ `isSleeping = true`,用户重新动 →
/// 立即恢复 `isSleeping = false`。
///
/// 工作机制:每 `tickInterval` 秒(默认 15s)tick 一次,状态变化时调
/// `onSleepingChanged` callback。
///
/// 与 HermesPet (https://github.com/basionwang-bot/HermesPet) `IdleStateTracker` 的区别:
/// - 走 closure callback 而非 NotificationCenter(OpenPetAgent 全项目 callback 风格)
/// - 阈值与 tick 间隔可注入 → 单测可用短间隔验证状态切换
/// - 时钟源可注入 → 测试用 fixture 模拟时间流逝
@MainActor
public final class IdleStateTracker {

    // MARK: - Public

    /// `isSleeping` 翻转时调用。`true` = 用户已经超过阈值无输入;`false` = 用户回来了。
    public var onSleepingChanged: ((Bool) -> Void)?

    /// 当前是否处于 sleeping 态(测试访问器)。
    public private(set) var isSleeping = false

    /// 是否已 `start()`。
    public var isRunning: Bool { timer != nil }

    // MARK: - Stored

    private var timer: Timer?
    private let sleepThresholdSeconds: TimeInterval
    private let tickInterval: TimeInterval
    private let idleSecondsProvider: @MainActor () -> TimeInterval

    // MARK: - Init

    /// - Parameters:
    ///   - sleepThresholdSeconds: 多久无输入算 sleeping。默认 3 分钟。
    ///   - tickInterval: 检查频率。默认 15 秒。
    ///   - idleSecondsProvider: 时钟源,返回"用户最后一次活跃距今的秒数"。
    ///     默认走 `CGEventSource.secondsSinceLastEventType` 取键鼠最近输入的 min。
    ///     测试用可注入 fixture 控制时间流逝。
    public init(
        sleepThresholdSeconds: TimeInterval = 180,
        tickInterval: TimeInterval = 15,
        idleSecondsProvider: @escaping @MainActor () -> TimeInterval = {
            let m = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            let k = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            return min(m, k)
        }
    ) {
        self.sleepThresholdSeconds = sleepThresholdSeconds
        self.tickInterval = tickInterval
        self.idleSecondsProvider = idleSecondsProvider
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// 启动定时检查。已 start 时再调先 invalidate 旧 timer(支持热重启)。
    /// 启动后立刻先 tick 一次,不等首个 interval。
    public func start() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // common modes 让 timer 在 tracking / modal 期间也跑(跟 BondedBubbleChain 同款配置)。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// 停止定时检查。`isSleeping` 状态保留,不重置。
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Internal (test hook)

    /// 测试用:手动触发一次评估。生产代码由 timer 周期调同一路径。
    internal func tick() {
        let idle = idleSecondsProvider()
        let newSleeping = idle >= sleepThresholdSeconds
        guard newSleeping != isSleeping else { return }
        isSleeping = newSleeping
        onSleepingChanged?(newSleeping)
    }
}
