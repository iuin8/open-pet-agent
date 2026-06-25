import Foundation

/// 「防休眠」模式 —— 四态互斥。前三态是进程内 `ProcessInfo` 断言(轻、退出自动释放);
/// `lidClosedAwake` 是全局系统改动(`pmset disablesleep`),需管理员权限、有散热风险。
enum ScreenAwakeMode: String, CaseIterable {
    /// 正常:不持任何断言,系统按设置正常变暗 / 息屏 / 休眠。
    case off
    /// 保持屏幕常亮:阻止显示器因 idle 休眠(屏幕不变暗)。`.idleDisplaySleepDisabled`。
    case displayAwake
    /// 仅防系统休眠:屏幕可正常息屏但系统不睡(CPU 跑 + 网络保持)。`.idleSystemSleepDisabled`。
    case systemAwake
    /// 合盖也不睡(无需外接显示器)—— 靠全局 `sudo pmset -a disablesleep 1`。
    /// **需管理员密码 + 仅接电源时维持 + 散热风险**,见 ScreenAwakeController 安全模型。
    case lidClosedAwake

    /// 旧布尔 key `keepScreenAwake` 迁移:true → displayAwake / false → off。
    static func migrating(legacyKeepScreenAwake on: Bool) -> ScreenAwakeMode {
        on ? .displayAwake : .off
    }

    /// 是否需要管理员权限的全局系统改动(仅 `lidClosedAwake`)。
    var requiresPrivilegedGlobalChange: Bool { self == .lidClosedAwake }
}

/// 防休眠「定时自动关」时长 —— 到点把模式复位为 `off`,防「开了忘关」无限期。
enum ScreenAwakeAutoOff: String, CaseIterable {
    case never
    case min30
    case hour1
    case hour2
    case hour4
    case hour8

    /// 秒数;`never` = nil(不自动关)。
    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .min30: return 30 * 60
        case .hour1: return 60 * 60
        case .hour2: return 2 * 60 * 60
        case .hour4: return 4 * 60 * 60
        case .hour8: return 8 * 60 * 60
        }
    }

    /// 启用 `lidClosedAwake` 时若当前为 `never`,默认置此值(过夜友好但有界)。
    static let lidClosedDefault: ScreenAwakeAutoOff = .hour8
}
