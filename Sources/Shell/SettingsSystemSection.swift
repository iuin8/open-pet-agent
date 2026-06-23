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
