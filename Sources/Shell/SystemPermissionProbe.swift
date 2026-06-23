import Foundation

/// 系统权限状态查询 + 申请的**唯一入口**。系统 API 全经注入闭包(App 层喂真实现:
/// AccessibilityBridge / CGScreenCaptureAccess / CoreLocation 适配器 / 系统设置深链),
/// 默认值供测试/无害兜底 → 纯值类型、可无头测。
@MainActor
public struct SystemPermissionProbe {
    private let accessibilityStatus: () -> PermissionStatus
    private let requestAccessibility: () -> Void
    private let screenRecordingStatus: () -> PermissionStatus
    private let requestScreenRecording: () -> Void
    private let locationStatus: () -> PermissionStatus
    private let requestLocation: () -> Void
    private let openSettings: (SystemPermission) -> Void

    public init(
        accessibilityStatus: @escaping () -> PermissionStatus = { .notDetermined },
        requestAccessibility: @escaping () -> Void = {},
        screenRecordingStatus: @escaping () -> PermissionStatus = { .notDetermined },
        requestScreenRecording: @escaping () -> Void = {},
        locationStatus: @escaping () -> PermissionStatus = { .notDetermined },
        requestLocation: @escaping () -> Void = {},
        openSettings: @escaping (SystemPermission) -> Void = { _ in }
    ) {
        self.accessibilityStatus = accessibilityStatus
        self.requestAccessibility = requestAccessibility
        self.screenRecordingStatus = screenRecordingStatus
        self.requestScreenRecording = requestScreenRecording
        self.locationStatus = locationStatus
        self.requestLocation = requestLocation
        self.openSettings = openSettings
    }

    public func status(for permission: SystemPermission) -> PermissionStatus {
        switch permission {
        case .accessibility:   return accessibilityStatus()
        case .screenRecording: return screenRecordingStatus()
        case .location:        return locationStatus()
        case .appleEvents:     return .reserved
        }
    }

    /// 按当前态分流:未决定→弹系统授权框;已拒绝→开系统设置(弹框不会再出);已授权/保留→no-op。
    public func request(_ permission: SystemPermission) {
        guard permission.isActionable else { return }
        switch status(for: permission) {
        case .notDetermined:
            switch permission {
            case .accessibility:   requestAccessibility()
            case .screenRecording: requestScreenRecording()
            case .location:        requestLocation()
            case .appleEvents:     break   // 不可达:上方 guard `isActionable` 已拦下 appleEvents,此 case 仅供 switch 穷举
            }
        case .denied:
            openSettings(permission)
        case .granted, .reserved:
            break
        }
    }
}
