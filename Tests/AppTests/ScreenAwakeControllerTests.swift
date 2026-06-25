import Testing
@testable import App

// MARK: - Mock

/// 注入 ScreenAwakeController / LidCloseSleepDisabler 的假提权执行器 —— 不弹密码框,记录调用。
final class MockSleepDisableExecutor: SleepDisableExecuting {
    var setCalls: [Bool] = []
    var setResult = true
    var readValue: Bool? = false

    func setSleepDisabled(_ on: Bool) async -> Bool {
        setCalls.append(on)
        if setResult { readValue = on }   // 成功的 set 翻转读回状态(模拟真实 pmset 生效)
        return setResult
    }
    func readSleepDisabled() -> Bool? { readValue }
}

// MARK: - 枚举

@Suite("ScreenAwakeMode / AutoOff")
struct ScreenAwakeModeTests {
    @Test("旧布尔迁移:true→displayAwake / false→off")
    func migrate() {
        #expect(ScreenAwakeMode.migrating(legacyKeepScreenAwake: true) == .displayAwake)
        #expect(ScreenAwakeMode.migrating(legacyKeepScreenAwake: false) == .off)
    }

    @Test("仅 lidClosedAwake 需特权全局改动")
    func privileged() {
        #expect(ScreenAwakeMode.lidClosedAwake.requiresPrivilegedGlobalChange)
        #expect(!ScreenAwakeMode.displayAwake.requiresPrivilegedGlobalChange)
        #expect(!ScreenAwakeMode.systemAwake.requiresPrivilegedGlobalChange)
        #expect(!ScreenAwakeMode.off.requiresPrivilegedGlobalChange)
    }

    @Test("AutoOff 秒数 + lid 默认 8h")
    func autoOffSeconds() {
        #expect(ScreenAwakeAutoOff.never.seconds == nil)
        #expect(ScreenAwakeAutoOff.min30.seconds == 1800)
        #expect(ScreenAwakeAutoOff.hour1.seconds == 3600)
        #expect(ScreenAwakeAutoOff.hour8.seconds == 28800)
        #expect(ScreenAwakeAutoOff.lidClosedDefault == .hour8)
    }
}

// MARK: - pmset -g 解析

@Suite("parseSleepDisabled")
struct ParseSleepDisabledTests {
    @Test("解析 SleepDisabled 行 1 / 0 / 缺失")
    func parses() {
        let on = " SleepDisabled  1\n Sleep On Power Button 1\n sleep 0\n"
        #expect(OSAScriptSleepDisableExecutor.parseSleepDisabled(from: on) == true)
        #expect(OSAScriptSleepDisableExecutor.parseSleepDisabled(from: " SleepDisabled  0\n") == false)
        #expect(OSAScriptSleepDisableExecutor.parseSleepDisabled(from: "no such field\n") == nil)
    }
}

// MARK: - LidCloseSleepDisabler

@MainActor
@Suite("LidCloseSleepDisabler")
struct LidCloseSleepDisablerTests {
    @Test("enable / disable 透传到执行器")
    func enableDisable() async {
        let mock = MockSleepDisableExecutor()
        let disabler = LidCloseSleepDisabler(executor: mock)
        _ = await disabler.enable()
        _ = await disabler.disable()
        #expect(mock.setCalls == [true, false])
    }

    @Test("selfHeal:残留=1 且本次不该开 → 复位")
    func selfHealResets() async {
        let mock = MockSleepDisableExecutor()
        mock.readValue = true
        let disabler = LidCloseSleepDisabler(executor: mock)
        let did = await disabler.selfHealIfOrphaned(shouldBeActive: false)
        #expect(did == true)
        #expect(mock.setCalls == [false])
    }

    @Test("selfHeal:本次该开 → 不复位")
    func selfHealSkipsWhenShouldBeActive() async {
        let mock = MockSleepDisableExecutor()
        mock.readValue = true
        let disabler = LidCloseSleepDisabler(executor: mock)
        let did = await disabler.selfHealIfOrphaned(shouldBeActive: true)
        #expect(did == false)
        #expect(mock.setCalls.isEmpty)
    }
}

// MARK: - ScreenAwakeController 状态机

@MainActor
@Suite("ScreenAwakeController")
struct ScreenAwakeControllerTests {
    private func make(ac: Bool = true, setResult: Bool = true, read: Bool? = false)
        -> (ScreenAwakeController, MockSleepDisableExecutor) {
        let mock = MockSleepDisableExecutor()
        mock.setResult = setResult
        mock.readValue = read
        let disabler = LidCloseSleepDisabler(executor: mock)
        // lowPowerProvider { false } 让测试不受运行机器真实低电量态影响(post-verify 会查它)。
        let monitor = PowerStateMonitor(acPowerProvider: { ac }, lowPowerProvider: { false })
        return (ScreenAwakeController(lidDisabler: disabler, powerMonitor: monitor), mock)
    }

    @Test("displayAwake / systemAwake 不碰 lid 提权")
    func nonLidNoPrivilege() async {
        let (controller, mock) = make()
        _ = await controller.apply(mode: .displayAwake, autoOff: .never)
        #expect(controller.mode == .displayAwake)
        _ = await controller.apply(mode: .systemAwake, autoOff: .never)
        #expect(controller.mode == .systemAwake)
        #expect(mock.setCalls.isEmpty)
    }

    @Test("lidClosedAwake 接电源 → 提权 enable + mode=lid")
    func lidOnAC() async {
        let (controller, mock) = make(ac: true)
        let final = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        #expect(final == .lidClosedAwake)
        #expect(controller.mode == .lidClosedAwake)
        #expect(mock.setCalls == [true])
    }

    @Test("lidClosedAwake 电池下拒开 → mode=off + onAutoChange,不提权")
    func lidOnBatteryRefused() async {
        let (controller, mock) = make(ac: false)
        var captured: ScreenAwakeMode?
        controller.onAutoChange = { mode, _ in captured = mode }
        let final = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        #expect(final == .off)
        #expect(mock.setCalls.isEmpty)
        #expect(captured == .off)
    }

    @Test("lidClosedAwake 提权被取消 → mode=off")
    func lidPrivilegeCancelled() async {
        let (controller, mock) = make(ac: true, setResult: false)
        let final = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        #expect(final == .off)
        #expect(mock.setCalls == [true])
    }

    @Test("离开 lidClosedAwake → 提权复位 disablesleep=0")
    func leaveLidResets() async {
        let (controller, mock) = make(ac: true)
        _ = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        mock.setCalls.removeAll()
        let final = await controller.apply(mode: .off, autoOff: .never)
        #expect(final == .off)
        #expect(mock.setCalls == [false])
    }

    @Test("离开 lid 复位被取消 → 维持 lid + onAutoChange")
    func leaveLidResetCancelled() async {
        let (controller, mock) = make(ac: true)
        _ = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        mock.setResult = false
        mock.setCalls.removeAll()
        var captured: ScreenAwakeMode?
        controller.onAutoChange = { mode, _ in captured = mode }
        let final = await controller.apply(mode: .off, autoOff: .never)
        #expect(final == .lidClosedAwake)
        #expect(controller.mode == .lidClosedAwake)
        #expect(captured == .lidClosedAwake)
    }

    @Test("拔电自动关 lidClosedAwake")
    func batteryAutoOff() async {
        let (controller, mock) = make(ac: true)
        _ = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        mock.setCalls.removeAll()
        await controller.batteryAutoOff()
        #expect(controller.mode == .off)
        #expect(mock.setCalls == [false])
    }

    @Test("拔电不影响 displayAwake(仅作用于 lid)")
    func batteryIgnoresDisplayMode() async {
        let (controller, _) = make()
        _ = await controller.apply(mode: .displayAwake, autoOff: .never)
        await controller.batteryAutoOff()
        #expect(controller.mode == .displayAwake)
    }

    @Test("低电量自动关(开关开)")
    func lowPowerAutoOff() async {
        let (controller, _) = make()
        _ = await controller.apply(mode: .displayAwake, autoOff: .never)
        controller.disableOnLowPower = true
        await controller.lowPowerAutoOff()
        #expect(controller.mode == .off)
    }

    @Test("低电量自动关(开关关 → 不动)")
    func lowPowerGuardOff() async {
        let (controller, _) = make()
        _ = await controller.apply(mode: .displayAwake, autoOff: .never)
        controller.disableOnLowPower = false
        await controller.lowPowerAutoOff()
        #expect(controller.mode == .displayAwake)
    }

    @Test("selfHeal:残留=1 且本次非 lid → 复位")
    func selfHealResets() async {
        let (controller, mock) = make(read: true)
        await controller.selfHeal(intendedMode: .off)
        #expect(mock.setCalls == [false])
    }

    @Test("selfHeal:本次是 lid → 不复位")
    func selfHealSkipsWhenLid() async {
        let (controller, mock) = make(read: true)
        await controller.selfHeal(intendedMode: .lidClosedAwake)
        #expect(mock.setCalls.isEmpty)
    }

    @Test("提权期间拔电 → post-verify 复位关掉(安全-M4 / 代码-M1 配套)")
    func lidPowerChangeDuringPrivilege() async {
        let mock = MockSleepDisableExecutor()
        var acCalls = 0
        // 第 1 次(入口)接电源,第 2 次(post-verify)已拔电。
        let monitor = PowerStateMonitor(acPowerProvider: { acCalls += 1; return acCalls == 1 },
                                        lowPowerProvider: { false })
        let controller = ScreenAwakeController(lidDisabler: LidCloseSleepDisabler(executor: mock),
                                               powerMonitor: monitor)
        var captured: ScreenAwakeMode?
        controller.onAutoChange = { mode, _ in captured = mode }
        let final = await controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        #expect(final == .off)
        #expect(captured == .off)
        #expect(mock.setCalls == [true, false])   // enable 后 post-verify 又 disable
    }

    @Test("apply 重入闸:提权 await 期间第二次 apply 被拒,不撕裂状态(代码-M1)")
    func applyReentrancyGuard() async {
        let gated = GatedSleepDisableExecutor()
        let monitor = PowerStateMonitor(acPowerProvider: { true }, lowPowerProvider: { false })
        let controller = ScreenAwakeController(lidDisabler: LidCloseSleepDisabler(executor: gated),
                                               powerMonitor: monitor)
        // 启动 lid 提权 —— 会在 setSleepDisabled 挂起(mode 已被设为 lid)。
        async let first = controller.apply(mode: .lidClosedAwake, autoOff: .hour8)
        await Task.yield()
        // 重入:第二次 apply 被闸拒绝,返回当前 in-flight mode,且不触发任何 set。
        let second = await controller.apply(mode: .off, autoOff: .never)
        #expect(second == .lidClosedAwake)
        #expect(gated.setCalls == [true])
        // 放行第一次完成。
        gated.release()
        let firstResult = await first
        #expect(firstResult == .lidClosedAwake)
        #expect(controller.mode == .lidClosedAwake)
    }
}

/// 可控挂起的执行器 —— `setSleepDisabled` 挂起直到 `release()`,用于测试 apply 重入闸。
@MainActor
final class GatedSleepDisableExecutor: SleepDisableExecuting {
    var setCalls: [Bool] = []
    private var readValue: Bool? = false
    private var gate: CheckedContinuation<Void, Never>?

    func setSleepDisabled(_ on: Bool) async -> Bool {
        setCalls.append(on)
        await withCheckedContinuation { gate = $0 }
        readValue = on
        return true
    }
    func readSleepDisabled() -> Bool? { readValue }
    func release() { gate?.resume(); gate = nil }
}
