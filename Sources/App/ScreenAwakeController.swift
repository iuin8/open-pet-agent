import Foundation

/// 「防休眠」执行器 / 编排器 —— 统一管理四态模式、定时自动关、电源安全闸。
///
/// **两套机制**:
/// - `displayAwake` / `systemAwake` → 进程内 `ProcessInfo.beginActivity` 活动 token(轻、退出自动释放)。
/// - `lidClosedAwake` → 全局 `pmset disablesleep`(经 `LidCloseSleepDisabler` 提权,需密码)。
///
/// **`lidClosedAwake` 安全模型**(防「开了忘关」+ 散热/掉电):
/// 1. 切走 / 关闭 → 提权复位 `disablesleep=0`(可能再弹密码)。
/// 2. 启动自愈(`selfHeal`)→ 残留 `SleepDisabled=1` 强制复位。
/// 3. 定时自动关(`autoOff`,默认 lid 用 8h)→ 到点复位。
/// 4. 电源硬规则:仅接电源维持;拔电(转电池)→ 自动关。
/// 5. 低电量模式开 + `disableOnLowPower` → 自动关。
///
/// 自动(非用户主动)改模式时经 `onAutoChange(mode, 原因)` 通知 App 持久化 + 刷新 UI + 弹提示。
@MainActor
final class ScreenAwakeController {
    private(set) var mode: ScreenAwakeMode = .off
    private(set) var autoOff: ScreenAwakeAutoOff = .never
    /// 低电量模式时是否自动关闭防休眠(默认开)。
    var disableOnLowPower = true

    private var activityToken: NSObjectProtocol?
    private let lidDisabler: LidCloseSleepDisabler
    private let powerMonitor: PowerStateMonitor
    private var autoOffWorkItem: DispatchWorkItem?
    /// 重入闸:`apply` 在 lid 提权 `await` 期间(密码框可挂很久)可能被定时器/电源事件重入,
    /// 撕裂 `mode` 字段。busy 时新调用直接返回当前 mode;提权期间的电源变化由 lid 分支末尾 post-verify 兜底。
    private var isApplying = false

    /// 模式被「非用户主动」改变(定时到点 / 低电量 / 拔电 / 提权失败回退)时回调:
    /// `(最终模式, 给用户看的原因文案)`。App 据此持久化 UD + 刷新 Settings Picker + 弹通知。
    var onAutoChange: (ScreenAwakeMode, String) -> Void = { _, _ in }

    /// 默认参数用 nil(默认表达式在非隔离上下文求值,不能直接 new @MainActor 类型);
    /// 实际实例在 init 体内构造(init 本身是 MainActor 上下文)。测试可注入 mock。
    init(lidDisabler: LidCloseSleepDisabler? = nil,
         powerMonitor: PowerStateMonitor? = nil) {
        self.lidDisabler = lidDisabler ?? LidCloseSleepDisabler()
        self.powerMonitor = powerMonitor ?? PowerStateMonitor()
    }

    /// 订阅电源事件并接好安全闸回调(App 启动时调一次)。测试不调 → 不碰 IOKit。
    func startPowerMonitoring() {
        powerMonitor.onLowPowerModeEnabled = { [weak self] in self?.handleLowPowerModeEnabled() }
        powerMonitor.onSwitchedToBattery = { [weak self] in self?.handleSwitchedToBattery() }
        powerMonitor.start()
    }

    func stopPowerMonitoring() { powerMonitor.stop() }

    /// 用户主动设模式 + 自动关时长。返回**最终生效**模式(lid 提权取消 → `.off`;复位取消 → 维持 `.lidClosedAwake`)。
    /// `lidClosedAwake` 走异步提权,故整体 async。
    @discardableResult
    func apply(mode newMode: ScreenAwakeMode, autoOff newAutoOff: ScreenAwakeAutoOff) async -> ScreenAwakeMode {
        guard !isApplying else { return mode }   // 重入闸:提权 await 期间拒绝插入,防状态撕裂
        isApplying = true
        defer { isApplying = false }
        autoOff = newAutoOff

        // 离开 lidClosedAwake → 先提权复位 disablesleep。复位被取消 → 维持 lid 模式(UI 与系统一致)。
        if mode == .lidClosedAwake, newMode != .lidClosedAwake {
            let reset = await lidDisabler.disable()
            guard reset else {
                onAutoChange(.lidClosedAwake, "复位需要管理员密码,已保持「合盖防休眠」。可稍后再关。")
                scheduleAutoOff()
                return .lidClosedAwake
            }
        }

        releaseToken()
        mode = newMode

        switch newMode {
        case .off:
            cancelAutoOff()
            return .off
        case .displayAwake:
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled], reason: "用户开启了「保持屏幕常亮」")
        case .systemAwake:
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "用户开启了「仅防系统休眠(屏幕可息屏)」")
        case .lidClosedAwake:
            // 电源硬规则:电池下拒开(合盖+电池=过热/掉电)。
            guard powerMonitor.isOnACPower() else {
                mode = .off
                cancelAutoOff()
                onAutoChange(.off, "未接电源,「合盖防休眠」未开启(电池下合盖易过热/掉电)。")
                return .off
            }
            let enabled = await lidDisabler.enable()
            guard enabled else {
                mode = .off
                cancelAutoOff()
                return .off   // 提权取消 → 保持关闭
            }
            // post-verify:提权框可能挂很久,期间可能拔电 / 进低电量 → 立刻复位关掉,防 lid 在危险态残留。
            if !powerMonitor.isOnACPower() || (disableOnLowPower && powerMonitor.isLowPowerModeEnabled) {
                _ = await lidDisabler.disable()
                mode = .off
                cancelAutoOff()
                onAutoChange(.off, "提权期间电源状态变化,「合盖防休眠」未维持。")
                return .off
            }
        }
        scheduleAutoOff()
        return mode
    }

    /// 系统是否残留 `disablesleep=1`(启动自愈判断用,不需权限)。
    func hasOrphanedSleepResidue() -> Bool {
        lidDisabler.isSystemSleepDisabled() == true
    }

    /// 只改「自动关」时长(模式不变),重排定时器。
    func setAutoOff(_ newAutoOff: ScreenAwakeAutoOff) {
        autoOff = newAutoOff
        scheduleAutoOff()
    }

    /// 启动自愈:残留 `disablesleep` 复位(本次 intendedMode 非 lid 时)。App 启动时调。
    func selfHeal(intendedMode: ScreenAwakeMode) async {
        await lidDisabler.selfHealIfOrphaned(shouldBeActive: intendedMode == .lidClosedAwake)
    }

    // MARK: - 安全闸 handlers(同步 handler 由系统事件触发 → spawn Task 调可 await 核心;
    // 可 await 的 `*AutoOff` core 供单测确定性验证)

    func handleLowPowerModeEnabled() {
        Task { @MainActor [weak self] in await self?.lowPowerAutoOff() }
    }

    /// 低电量自动关核心(可 await 测试)。
    func lowPowerAutoOff() async {
        guard disableOnLowPower, mode != .off else { return }
        await autoTurnOffCore(reason: "进入低电量模式,防休眠已自动关闭。")
    }

    func handleSwitchedToBattery() {
        Task { @MainActor [weak self] in await self?.batteryAutoOff() }
    }

    /// 拔电自动关 lidClosedAwake 核心(可 await 测试)。
    func batteryAutoOff() async {
        guard mode == .lidClosedAwake else { return }
        await autoTurnOffCore(reason: "已拔电(转电池),「合盖防休眠」已自动关闭。")
    }

    // MARK: - 私有

    /// 自动关核心:置 off + 若确实从非 off 关掉则发 onAutoChange 通知。
    func autoTurnOffCore(reason: String) async {
        let previous = mode
        let final = await apply(mode: .off, autoOff: autoOff)
        if previous != .off, final == .off { onAutoChange(.off, reason) }
    }

    private func scheduleAutoOff() {
        cancelAutoOff()
        guard mode != .off, let seconds = autoOff.seconds else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in await self?.autoTurnOffCore(reason: "防休眠定时到点,已自动关闭。") }
        }
        autoOffWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelAutoOff() {
        autoOffWorkItem?.cancel()
        autoOffWorkItem = nil
    }

    private func releaseToken() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
