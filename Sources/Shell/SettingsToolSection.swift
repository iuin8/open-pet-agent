import SwiftUI

/// 设置面板「工具模式」section — Tool Mode toggle + engine kind picker +
/// 当前 engine CLI 路径行。
@MainActor
struct SettingsToolSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("工具模式")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "启用 Claude Code 工具模式(实验)",
                        isOn: $viewModel.toolModeEnabled
                    )
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.toolModeEnabled) { newValue in
                        viewModel.onCommitToolMode(newValue)
                    }

                    Divider()

                    HStack(alignment: .top, spacing: 10) {
                        Text("Engine")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 96, alignment: .trailing)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 4) {
                            Picker(selection: $viewModel.toolEngineKind) {
                                ForEach(viewModel.toolEngineKinds, id: \.id) { kind in
                                    Text(kind.displayName).tag(kind.id)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .onChange(of: viewModel.toolEngineKind) { newValue in
                                viewModel.onCommitToolEngine(newValue)
                            }

                            Text(viewModel.toolEngineCLIDisplay)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
