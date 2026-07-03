import SwiftUI

/// 设置面板「外部 Agent 模式」section — 当前 engine 状态 + CLI 路径(只读)。
/// engine 切换在聊天面板 Composer 上方 segmented(直觉可用性,不藏设置深处);
/// 本 section 只显示当前选中 engine + CLI 路径(高级信息)。
/// 注意:这与灵魂层的「工具调用」(`chatWithTools`)是两回事 —— 那是 pet 自己的大脑
/// 进程内调工具;这里是把整段 prompt 丢给外部 agent CLI 跑(无 pet 人格)。
@MainActor
struct SettingsAgentSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("外部 Agent 模式")) {
                VStack(alignment: .leading, spacing: 10) {
                    // 提示:聊天面板切换(直觉可用性 —— engine 切换在聊天面板 segmented,不藏设置深处)
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("在聊天面板切换回复来源:🐾 灵魂层 / ⚡ Claude / ⚡ Codex / ⚡ opencode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // 当前 engine + CLI 路径(只读,高级信息)
                    HStack(alignment: .top, spacing: 10) {
                        Text("Engine")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 96, alignment: .trailing)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentEngineDisplayName)
                                .font(.system(size: 13))
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

    /// 当前 engine 的展示名(只读;切换在聊天面板 segmented)。
    private var currentEngineDisplayName: String {
        viewModel.agentEngineKinds.first { $0.id == viewModel.agentEngineKind }?.displayName
            ?? viewModel.agentEngineKind
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
