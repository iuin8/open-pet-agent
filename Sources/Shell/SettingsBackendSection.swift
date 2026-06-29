import SwiftUI

/// 设置面板「AI 后端」section — provider picker / API Key / Base URL /
/// Model + OpenClaw 本地 gateway 状态卡。
///
/// 视觉对齐 macOS Sonoma 系统设置: GroupBox 分组 + Form-like row,字段标签
/// 左对齐 + 输入框撑满剩余宽度。
@MainActor
struct SettingsBackendSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // LLM 提供商 + key/URL/model
            GroupBox(label: sectionLabel("LLM 提供商")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(selection: $viewModel.selectedProviderIndex) {
                        ForEach(viewModel.soulBackends.indices, id: \.self) { idx in
                            Text(viewModel.soulBackends[idx].displayName).tag(idx)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: viewModel.selectedProviderIndex) { _ in
                        viewModel.onCommitLLM()   // modeless:切 provider 即时提交(空配置不触发)
                    }

                    if viewModel.selectedBackendManaged {
                        // 自动管理后端(openclaw):不显示手填字段,只说明它由本地网关托管。
                        Text(viewModel.selectedBackendManagedNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // 云后端:API Key / Base URL / Model 三行手填。
                        // API Key 行: secure/text + 眼睛 toggle
                        fieldRow(label: viewModel.apiKeyLabel) {
                            HStack(spacing: 6) {
                                Group {
                                    if showKey {
                                        TextField(
                                            viewModel.apiKeyPlaceholder,
                                            text: $viewModel.apiKey
                                        )
                                    } else {
                                        SecureField(
                                            viewModel.apiKeyPlaceholder,
                                            text: $viewModel.apiKey
                                        )
                                    }
                                }
                                .textFieldStyle(.roundedBorder)

                                Button {
                                    showKey.toggle()
                                } label: {
                                    Image(systemName: showKey ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(showKey ? "隐藏" : "显示")
                            }
                        }

                        // Base URL 行
                        fieldRow(label: "Base URL") {
                            VStack(alignment: .leading, spacing: 3) {
                                TextField(
                                    viewModel.baseURLPlaceholder,
                                    text: $viewModel.baseURL
                                )
                                .textFieldStyle(.roundedBorder)
                                Text(viewModel.baseURLHint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Model 行
                        fieldRow(label: "Model") {
                            VStack(alignment: .leading, spacing: 3) {
                                TextField(
                                    viewModel.modelPlaceholder,
                                    text: $viewModel.model
                                )
                                .textFieldStyle(.roundedBorder)
                                Text(viewModel.modelHint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                // modeless:文本框回车即时提交;没回车直接关窗也会 flush(controller windowWillClose)。
                .onSubmit { viewModel.onCommitLLM() }
            }

            // OpenClaw 本地 gateway 状态卡
            GroupBox(label: sectionLabel("OpenClaw 本地 gateway")) {
                Text(viewModel.openClawStatusDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
    }

    /// GroupBox label — 小号 semibold,跟 macOS Sonoma 设置面板对齐。
    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    /// 表单 row — label 固定 ~96pt 宽 + 内容撑满剩余宽。
    /// 注:这里没用 Form{} 因为 Form 的 LabeledContent 在 macOS 13 行为不稳。
    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 96, alignment: .trailing)
                .padding(.top, 5)  // 跟 TextField roundedBorder 视觉对齐
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
