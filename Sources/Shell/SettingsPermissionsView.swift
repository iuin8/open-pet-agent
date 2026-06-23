import SwiftUI

/// 权限状态 → 徽章/按钮的纯映射(可无头测)。
public enum PermissionBadge {
    /// 显示文案。
    public static func text(for status: PermissionStatus) -> String {
        switch status {
        case .granted:                  return "已授权"
        case .denied, .notDetermined:   return "未授权"
        case .reserved:                 return "未使用"
        }
    }

    /// SF Symbol 名称。
    public static func symbol(for status: PermissionStatus) -> String {
        switch status {
        case .granted:                  return "checkmark.circle.fill"
        case .denied, .notDetermined:   return "exclamationmark.triangle.fill"
        case .reserved:                 return "minus.circle"
        }
    }

    /// 徽章前景色。
    public static func tint(for status: PermissionStatus) -> Color {
        switch status {
        case .granted:                  return .green
        case .denied, .notDetermined:   return .orange
        case .reserved:                 return Color.secondary
        }
    }

    /// 是否显示动作按钮(「授权」或「打开系统设置」)。
    public static func showsActionButton(for status: PermissionStatus) -> Bool {
        status == .notDetermined || status == .denied
    }

    /// 动作按钮标题。仅当 `showsActionButton` 为 true 时有意义。
    public static func actionTitle(for status: PermissionStatus) -> String {
        status == .denied ? "打开系统设置" : "授权"
    }
}

// MARK: - 权限 GroupBox 视图

/// 设置「系统」section 内的「系统权限」GroupBox。
/// 列出四项权限当前状态,可一键发起授权或跳转系统设置。
@MainActor
struct SettingsPermissionsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        GroupBox(label: groupBoxLabel) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SystemPermission.allCases, id: \.self) { perm in
                    permissionRow(perm)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { viewModel.onRefreshPermissions() }
    }

    // MARK: - Private helpers

    private var groupBoxLabel: some View {
        Text("系统权限")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func permissionRow(_ perm: SystemPermission) -> some View {
        let status = viewModel.permissionStatuses[perm] ?? .notDetermined
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: perm.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(perm.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(perm.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 屏幕录制未授权时额外提示(重启生效)
                if perm == .screenRecording && status != .granted {
                    Text("授权后需重启 OpenPetAgent 生效")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Label(
                PermissionBadge.text(for: status),
                systemImage: PermissionBadge.symbol(for: status)
            )
            .font(.caption)
            .foregroundStyle(PermissionBadge.tint(for: status))

            if PermissionBadge.showsActionButton(for: status) {
                Button(PermissionBadge.actionTitle(for: status)) {
                    viewModel.onRequestPermission(perm)
                }
                .controlSize(.small)
            }
        }
    }
}
