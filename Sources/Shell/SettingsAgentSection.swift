import SwiftUI

/// 设置面板「外部 Agent 引擎」section — 当前钉住 engine 状态 + CLI 路径(只读)。
/// P6 起引擎选择收敛到聊天 composer:@ 点名(一次性)/ chip 菜单钉住(粘性默认),
/// 本 section 只显示当前钉住的 engine + CLI 路径(高级信息)。
/// 注意:这与灵魂层的「工具调用」(`chatWithTools`)是两回事 —— 那是 pet 自己的大脑
/// 进程内调工具;这里是把整段 prompt 丢给外部 agent CLI 跑(无 pet 人格)。
@MainActor
struct SettingsAgentSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("外部 Agent 引擎")) {
                VStack(alignment: .leading, spacing: 10) {
                    // 提示:pin 语义(聊天输入框 @ 点名 / 钉住,不藏设置深处)
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("在聊天输入框用 @ 点名引擎;钉住后每条消息默认走该引擎,取消钉住回灵魂层")
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

    /// 当前钉住 engine 的展示名(只读;钉住/取消在聊天 composer 的 chip 菜单)。
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
