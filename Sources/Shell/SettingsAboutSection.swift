import SwiftUI

/// 设置面板「关于」section — 版本号 + GitHub 链接。
@MainActor
struct SettingsAboutSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("关于")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.aboutVersion)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    Text("GitHub: https://github.com/iuin8/open-pet-agent")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
