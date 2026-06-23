/// 把单一 `IdleStateTracker.onSleepingChanged`（单 var callback，不可链式）扇出给多订阅者。
/// App 在 wire 时把现有 idle 省电（alpha/Hz）逻辑 + 主动引擎都 register，再把聚合闭包
/// 赋给 `idleStateTracker.onSleepingChanged`。零改 IdleStateTracker。
@MainActor
final class IdleSleepingFanout {
    private var subscribers: [(Bool) -> Void] = []

    /// 注册一个 sleeping 翻转订阅者。
    func subscribe(_ handler: @escaping (Bool) -> Void) {
        subscribers.append(handler)
    }

    /// 扇出一次翻转。赋给 `idleStateTracker.onSleepingChanged` 的聚合闭包调它。
    func emit(_ isSleeping: Bool) {
        for handler in subscribers { handler(isSleeping) }
    }
}
