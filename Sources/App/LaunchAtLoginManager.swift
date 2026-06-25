import Foundation
import ServiceManagement
import os

private let launchAtLoginLog = Logger(subsystem: "io.openpetagent", category: "LaunchAtLogin")

/// 开机自启管理协议 —— 抽出来是为了**可注入 mock 单测**(真实现走 `SMAppService`,
/// 触碰系统登录项注册表,测试不能真注册)。
protocol LaunchAtLoginManaging {
    /// 当前是否已启用(系统登录项已注册并生效)。
    var isEnabled: Bool { get }
    /// 是否「已请求但待系统设置批准」(用户曾在 系统设置›登录项 手动关过 → 需重新允许)。
    var requiresApproval: Bool { get }
    /// 注册 / 注销开机自启。失败抛错(调用方据此回退 UI)。
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp` 实现 —— macOS 13+ 官方登录项 API,注册 app 自身随登录启动。
/// 无需 helper bundle / 特权,只要 app 是已签名的正常 bundle(本仓 /Applications 下 Apple Dev 签名)。
/// `status` 是权威源(OS 持久化、用户可在 系统设置›登录项 改),故不另存 UserDefaults。
struct SMAppServiceLaunchAtLogin: LaunchAtLoginManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLoginLog.info("launch at login set=\(enabled, privacy: .public) status=\(SMAppService.mainApp.status.rawValue, privacy: .public)")
    }
}
