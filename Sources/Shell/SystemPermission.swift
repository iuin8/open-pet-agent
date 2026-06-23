import Foundation

/// app 真正会用到的系统级权限。每项都有真功能在后面(Apple Events 例外:已声明保留给未来)。
public enum SystemPermission: String, CaseIterable, Sendable {
    case accessibility, screenRecording, location, appleEvents

    public var displayName: String {
        switch self {
        case .accessibility:   return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .location:        return "位置"
        case .appleEvents:     return "Apple Events"
        }
    }

    public var purpose: String {
        switch self {
        case .accessibility:   return "全局快捷键 + 读取窗口位置(桌宠漫步 / 爬墙)"
        case .screenRecording: return "读取窗口标题,用于桌面感知与 AI 上下文"
        case .location:        return "自动跟随当前位置获取真实天气"
        case .appleEvents:     return "已声明保留(未来读桌面图标位置驱动积雪遮挡),当前未使用"
        }
    }

    public var symbolName: String {
        switch self {
        case .accessibility:   return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .location:        return "location.fill"
        case .appleEvents:     return "applescript"
        }
    }

    /// 是否可在面板内检查/申请。Apple Events 当前无功能,只读展示「已声明·未使用」。
    public var isActionable: Bool { self != .appleEvents }
}

/// 单项权限的授权状态。
public enum PermissionStatus: Sendable, Equatable {
    case granted        // ✅ 已授权
    case denied         // ⚠️ 已拒绝(需去系统设置开)
    case notDetermined  // 未决定(可弹框申请)
    case reserved       // ⚪ 已声明·未使用(Apple Events)
}
