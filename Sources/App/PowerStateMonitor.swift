import Foundation
import IOKit.ps

/// 电源状态监听 —— 观察「低电量模式开关」+「AC ↔ 电池切换」,供 ScreenAwakeController
/// 做安全闸:进低电量 → 自动关防休眠;拔电(转电池)→ 自动关 `lidClosedAwake`(合盖+电池最危险)。
///
/// AC 判定可注入(`acPowerProvider`)→ 单测不碰 IOKit。`start()` 才订阅系统事件,
/// 测试不调 `start()` 即可纯逻辑验证。
@MainActor
final class PowerStateMonitor {
    /// 进入低电量模式时触发。
    var onLowPowerModeEnabled: @MainActor () -> Void = {}
    /// 切到电池供电(拔电)时触发。
    var onSwitchedToBattery: @MainActor () -> Void = {}

    private let acPowerProvider: (() -> Bool)?
    private let lowPowerProvider: (() -> Bool)?
    private var lowPowerObserver: NSObjectProtocol?
    private var powerSourceRunLoopSource: CFRunLoopSource?

    /// `acPowerProvider` / `lowPowerProvider` 非 nil 时用它们判定(测试注入);否则查系统。
    init(acPowerProvider: (() -> Bool)? = nil, lowPowerProvider: (() -> Bool)? = nil) {
        self.acPowerProvider = acPowerProvider
        self.lowPowerProvider = lowPowerProvider
    }

    /// 当前是否低电量模式。
    var isLowPowerModeEnabled: Bool { lowPowerProvider?() ?? ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// 当前是否接电源(AC)。读取失败时保守返回 true(避免误判断电触发自动关)。
    func isOnACPower() -> Bool {
        if let provider = acPowerProvider { return provider() }
        return Self.queryIOKitOnAC()
    }

    /// 订阅系统电源事件(App 启动时调;测试不调)。
    /// **不变量**:两个回调都必须在 main 线程触发,下面的 `MainActor.assumeIsolated` 才不会 fatalError ——
    /// observer 显式 `queue: .main`,IOPS source 加到 `CFRunLoopGetMain()`(main run loop 跑在 main 线程)。
    /// 若日后把 source 改挂到别的 run loop,assumeIsolated 会崩,需改用 `Task { @MainActor in }`。
    func start() {
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLowPowerModeEnabled else { return }
                self.onLowPowerModeEnabled()
            }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(rawContext).takeUnretainedValue()
            MainActor.assumeIsolated {
                if !monitor.isOnACPower() { monitor.onSwitchedToBattery() }
            }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = source
        }
    }

    /// 取消订阅(App 退出时调)。
    func stop() {
        if let observer = lowPowerObserver {
            NotificationCenter.default.removeObserver(observer)
            lowPowerObserver = nil
        }
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    /// 查 IOKit 电源源,判断当前是否 AC 供电。无法判定时保守返回 true。
    private static func queryIOKitOnAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPSACPowerValue
    }
}
