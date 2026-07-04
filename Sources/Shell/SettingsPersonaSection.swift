import SwiftUI

/// 设置 → 人格 section。SOUL.md 编辑(pet 人格,云后端注入 system message)。
///
/// textarea 改 + 保存(写文件,下次 reply 读新 SOUL.md 即时生效)+ 「在 Finder 显示」(外部编辑)。
/// `PersonaConfig` 在 App,Shell 不直接调 —— 经 viewModel callback(controller 注入 writeSoul/reveal)。
@MainActor
struct SettingsPersonaSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("SOUL.md · pet 人格(云后端注入 system message;openclaw 自管不注入)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.soulText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
                HStack {
                    Button("在 Finder 显示") { viewModel.revealSoulInFinder() }
                    Spacer()
                    Button("保存") { viewModel.saveSoul() }
                        .disabled(viewModel.soulText.isEmpty)
                }
            }
            .padding(8)
        }
    }
}
