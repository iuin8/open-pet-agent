import SwiftUI
import Rendering

/// 设置面板「桌宠」section —— **精简版**:当前桌宠卡片 + 「管理桌宠库…」按钮 + 灵动岛 toggle。
///
/// 库的全量管理(横排分类 tab + 网格 + 同屏 + 删除 / 导入 / 浏览社区)在独立 overlay 卡片 `PetLibraryView`,
/// 点「管理桌宠库…」由 `SettingsRootView` 顶层 ZStack 弹出(点空白处 / Esc 关)。设置页只留「看当前是谁
/// + 大小滑杆 + 一键进库」。设计见 pet-library-and-multipet-design.md §4.3。
@MainActor
struct SettingsPetSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// 由 `SettingsRootView` 顶层持有 —— 点「管理桌宠库…」置 true,顶层 ZStack 弹出 overlay 卡片。
    @Binding var showingLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: sectionLabel("桌宠形象")) {
                VStack(alignment: .leading, spacing: 10) {
                    currentPetCard
                    petScaleSlider
                    Button {
                        showingLibrary = true
                    } label: {
                        Label("管理桌宠库…", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    if viewModel.importInProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("导入处理中…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: sectionLabel("灵动岛")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(viewModel.islandToggleTitle, isOn: $viewModel.islandEnabled)
                        .disabled(!viewModel.notchAvailable)
                        .toggleStyle(.checkbox)
                        .onChange(of: viewModel.islandEnabled) { _ in
                            viewModel.onCommitIsland(viewModel.effectiveIslandOn)
                        }
                    Toggle(viewModel.islandHidePetTitle, isOn: $viewModel.islandHidePetOnSwitch)
                        .disabled(!viewModel.notchAvailable)
                        .toggleStyle(.checkbox)
                        .onChange(of: viewModel.islandHidePetOnSwitch) { newValue in
                            viewModel.onCommitIslandHidePet(newValue)
                        }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 桌宠大小滑杆(PF6,0.5–2.0)。拖动即时预览(onChange → preview,不写 UD;保存才持久化)。
    @ViewBuilder
    private var petScaleSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(value: $viewModel.petScale, in: 0.5...2.0, step: 0.1)
                .onChange(of: viewModel.petScale) { newValue in
                    viewModel.onPetScalePreview(newValue)
                }
            Text("\(Int((viewModel.petScale * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// 当前桌宠卡片:缩略图 + 名称 + 来源分类。
    @ViewBuilder
    private var currentPetCard: some View {
        HStack(spacing: 12) {
            if let item = viewModel.selectedPetItem {
                PetThumbnailView(item: item, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.system(size: 14, weight: .medium))
                    Text(item.category.displayName).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "pawprint.circle")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                Text("未选择桌宠").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
