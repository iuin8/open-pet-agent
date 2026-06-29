import SwiftUI

/// 设置面板「外部 Agent 模式」section — 让 pet 把整轮外包给外部编码 agent 子进程
/// (Claude Code / Codex)执行。toggle + engine kind picker + 当前 engine CLI 路径行。
/// 注意:这与灵魂层的「工具调用」(`chatWithTools`)是两回事 —— 那是 pet 自己的大脑
/// 进程内调工具;这里是把整段 prompt 丢给外部 agent CLI 跑(无 pet 人格)。
@MainActor
struct SettingsAgentSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("外部 Agent 模式")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "启用外部 Agent(把任务交给 Claude Code / Codex 子进程,实验)",
                        isOn: $viewModel.agentModeEnabled
                    )
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.agentModeEnabled) { newValue in
                        viewModel.onCommitAgentMode(newValue)
                    }

                    Divider()

                    HStack(alignment: .top, spacing: 10) {
                        Text("Engine")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 96, alignment: .trailing)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 4) {
                            Picker(selection: $viewModel.agentEngineKind) {
                                ForEach(viewModel.agentEngineKinds, id: \.id) { kind in
                                    Text(kind.displayName).tag(kind.id)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .onChange(of: viewModel.agentEngineKind) { newValue in
                                viewModel.onCommitAgentEngine(newValue)
                            }

                            Text(viewModel.agentEngineCLIDisplay)
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
