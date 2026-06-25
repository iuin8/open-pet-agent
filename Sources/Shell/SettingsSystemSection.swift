import SwiftUI

/// 设置面板「系统」section — OpenClaw 自动启动 + chatCompletions
/// 自动 enable 两个 toggle。
@MainActor
struct SettingsSystemSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("OpenClaw 守护进程")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "启动时自动检测并拉起 OpenClaw daemon",
                        isOn: $viewModel.openClawAutoStart
                    )
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.openClawAutoStart) { newValue in
                        viewModel.onCommitOpenClawAutoStart(newValue)
                    }

                    Toggle(
                        "允许自动启用 chatCompletions endpoint",
                        isOn: $viewModel.openClawAllowEndpointEnable
                    )
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.openClawAllowEndpointEnable) { newValue in
                        viewModel.onCommitOpenClawAllowEndpoint(newValue)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: sectionLabel("防休眠")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("模式", selection: $viewModel.screenAwakeModeRaw) {
                        ForEach(viewModel.screenAwakeModeOptions, id: \.id) { opt in
                            Text(opt.displayName).tag(opt.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.screenAwakeModeRaw) { newRaw in
                        viewModel.onCommitScreenAwakeMode(newRaw)
                    }

                    Picker("自动关闭", selection: $viewModel.screenAwakeAutoOffRaw) {
                        ForEach(viewModel.screenAwakeAutoOffOptions, id: \.id) { opt in
                            Text(opt.displayName).tag(opt.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.screenAwakeAutoOffRaw) { newRaw in
                        viewModel.onCommitScreenAwakeAutoOff(newRaw)
                    }

                    Toggle("低电量模式时自动关闭防休眠", isOn: $viewModel.screenAwakeDisableOnLowPower)
                        .toggleStyle(.checkbox)
                        .onChange(of: viewModel.screenAwakeDisableOnLowPower) { newValue in
                            viewModel.onCommitScreenAwakeDisableOnLowPower(newValue)
                        }

                    Text("「保持屏幕常亮」= 屏幕不变暗;「仅防系统休眠」= 屏幕可息屏但系统不睡(CPU 跑、网络保持),适合挂 Claude 联网开发。「合盖也保持唤醒」= 改系统全局开关、可合盖挂机无需外接屏 —— ⚠️ 需管理员密码、仅接电源时维持(拔电自动关)、合盖跑负载有散热风险,务必设个「自动关闭」时长兜底。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsPermissionsView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
