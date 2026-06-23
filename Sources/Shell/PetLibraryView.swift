import SwiftUI
import Rendering
import UniformTypeIdentifiers

/// 桌宠缩略图(sprite idle 首帧;无则按 category 占位符)。当前宠卡片 + 库网格共用。
@MainActor
struct PetThumbnailView: View {
    let item: PetPickerItem
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.none)            // 像素感(sprite)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.category.fallbackSymbol)
                    .font(.system(size: size * 0.56))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 「桌宠库」overlay 卡片 —— **横排分类 tab + 矩形网格 + 即时生效(modeless)**。
/// 从设置「桌宠」section 的「管理桌宠库…」按钮以 overlay 形式弹出(`SettingsRootView` 顶层 ZStack)。
/// 退出:**点暗背景空白处** / Esc(无「完成」按钮,modeless)。选宠 / 同屏 / 删除全部即时生效。
/// 设计见 pet-library-and-multipet-design.md §4.3(2026-06-11 横排 tab + 网格重构)。
@MainActor
struct PetLibraryView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Binding var isPresented: Bool

    @State private var dropTargeted = false
    @State private var showingCommunity = false
    @State private var pendingDelete: PetPickerItem?
    /// 当前选中的分类 tab。首次出现 / 列表变化时跟到主宠所在分类。
    @State private var selectedCategory: PetCategory = .builtin
    @State private var didSyncCategory = false

    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            toolbar
            petSearchField.padding(.horizontal, 14).padding(.bottom, 8)
            categoryTabs
            Divider()
            petGrid
            Divider()
            footer
        }
        .frame(width: 580, height: 460)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .background(dropHighlight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
        .onExitCommand { isPresented = false }
        .onAppear { syncCategoryToPrimary() }
        .onChange(of: viewModel.petPlugins.count) { _ in syncCategoryToPrimary(force: true) }
        .sheet(isPresented: $showingCommunity) {
            CommunityPetsSheet(viewModel: viewModel, onInstalled: { viewModel.rebuildPetList() })
        }
        .confirmationDialog(
            pendingDelete.map { "删除「\($0.displayName)」?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { viewModel.deletePet(item.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将从磁盘移除这只桌宠的包文件,此操作不可撤销。")
        }
    }

    // MARK: - 头 / 工具栏 / 搜索

    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("桌宠库").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("点空白处或 Esc 关闭").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { showingCommunity = true } label: {
                Label("获取社区桌宠…", systemImage: "square.grid.2x2")
            }
            Button { pickPack(.shimeji) } label: {
                Label("导入 Shimeji", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.importInProgress)
            Button { pickPack(.live2d) } label: {
                Label("导入 Live2D", systemImage: "person.crop.square.badge.video")
            }
            .disabled(viewModel.importInProgress)
            if viewModel.importInProgress { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var petSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("搜索桌宠…", text: $viewModel.petSearchQuery)
                .textFieldStyle(.plain).font(.system(size: 12))
            if !viewModel.petSearchQuery.isEmpty {
                Button { viewModel.petSearchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - 横排分类 tab

    /// 非空分类列表(按 sortOrder,不受搜索影响)。
    private var availableCategories: [PetCategory] {
        viewModel.groupedPlugins.map(\.category)
    }

    private func categoryCount(_ cat: PetCategory) -> Int {
        viewModel.groupedPlugins.first { $0.category == cat }?.items.count ?? 0
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableCategories, id: \.self) { cat in
                    let active = selectedCategory == cat
                    Button { selectedCategory = cat } label: {
                        HStack(spacing: 5) {
                            Image(systemName: cat.fallbackSymbol).font(.system(size: 10))
                            Text(cat.displayName).font(.system(size: 12, weight: .medium))
                            Text("\(categoryCount(cat))")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary.opacity(0.7))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.12)))
                        .foregroundStyle(active ? .white : .primary)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    // MARK: - 网格(当前分类,二级包成子区)

    /// 当前分类内、按搜索过滤后的包组。
    private var packsForSelected: [SettingsViewModel.PetPackGroup] {
        viewModel.groupedByPack.first { $0.category == selectedCategory }?.packs ?? []
    }

    @ViewBuilder
    private var petGrid: some View {
        let packs = packsForSelected
        let solos = packs.filter { !$0.showsPackHeader }.flatMap(\.items)
        let multiPacks = packs.filter { $0.showsPackHeader }
        if viewModel.petPlugins.isEmpty {
            emptyState("尚未注册桌宠 plugin")
        } else if packs.isEmpty {
            emptyState(viewModel.petSearchQuery.isEmpty ? "该分类暂无桌宠" : "无匹配的桌宠")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !solos.isEmpty {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(solos) { petTile($0) }
                        }
                    }
                    ForEach(multiPacks) { pack in
                        VStack(alignment: .leading, spacing: 8) {
                            packHeader(pack)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(pack.items) { petTile($0) }
                            }
                            .padding(.leading, 6)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 多角色包头:包名 + 成员数 + 「全部同屏」批量 toggle(S5)。
    @ViewBuilder
    private func packHeader(_ pack: SettingsViewModel.PetPackGroup) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "shippingbox").font(.system(size: 10))
            Text(pack.packName ?? "包").font(.system(size: 11, weight: .semibold))
            Text("(\(pack.items.count))").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if let state = viewModel.packDecorativeState(pack) {
                packAllToggle(pack, state)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 网格 tile

    /// 单只桌宠 tile:缩略图(主宠高亮环 + checkmark)+ 名 + 右下「同屏」徽标(可点)+ 右键菜单。
    /// 点 tile 即时切主宠(modeless);点同屏徽标切装饰伙伴。
    @ViewBuilder
    private func petTile(_ item: PetPickerItem) -> some View {
        let isPrimary = item.id == viewModel.selectedPetPluginID
        let isDecorative = viewModel.activeDecorativeIDs.contains(item.id)
        VStack(spacing: 5) {
            Button { viewModel.selectPetPlugin(item.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isPrimary ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isPrimary ? Color.accentColor : Color.clear, lineWidth: 2)
                    PetThumbnailView(item: item, size: 46)
                    if isPrimary {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14)).foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.background))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(5)
                    }
                }
                .frame(width: 84, height: 70)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomTrailing) {
                if viewModel.canBeDecorative(item) {
                    Button { viewModel.toggleDecorativePet(item.id) } label: {
                        Image(systemName: isDecorative ? "person.2.fill" : "person.2")
                            .font(.system(size: 9))
                            .padding(4)
                            .background(Circle().fill(isDecorative ? Color.accentColor : Color(nsColor: .windowBackgroundColor)))
                            .foregroundStyle(isDecorative ? .white : .secondary)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(isDecorative ? "从同屏移除" : "让这只也同屏(装饰物理伙伴)")
                    .offset(x: 3, y: 3)
                }
            }

            Text(item.displayName)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(isPrimary ? Color.accentColor : .primary)
                .frame(maxWidth: 88)
        }
        .contextMenu { tileContextMenu(item) }
    }

    @ViewBuilder
    private func tileContextMenu(_ item: PetPickerItem) -> some View {
        if item.id != viewModel.selectedPetPluginID {
            Button("设为主宠") { viewModel.selectPetPlugin(item.id) }
        }
        if viewModel.canBeDecorative(item) {
            let active = viewModel.activeDecorativeIDs.contains(item.id)
            Button(active ? "从同屏移除" : "让它同屏") { viewModel.toggleDecorativePet(item.id) }
        }
        if item.canDelete {
            Divider()
            Button("删除「\(item.displayName)」", role: .destructive) { pendingDelete = item }
        }
    }

    /// 「全部同屏」整包批量 toggle(S5)—— 三态:all=accent 填充 / partial=accent 淡底 / empty=灰底。
    @ViewBuilder
    private func packAllToggle(_ pack: SettingsViewModel.PetPackGroup,
                               _ state: SettingsViewModel.PackDecorativeState) -> some View {
        let fill: Color = state == .all ? Color.accentColor.opacity(0.85)
            : (state == .partial ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
        let fg: Color = state == .all ? .white : (state == .partial ? Color.accentColor : .secondary)
        Button { viewModel.toggleWholePack(pack) } label: {
            HStack(spacing: 3) {
                Image(systemName: state == .all ? "person.3.fill" : "person.3").font(.system(size: 9))
                Text("全部同屏").font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(fill))
            .foregroundStyle(fg)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state == .all ? "把整包角色从同屏全部移除" : "让整包角色都同屏(装饰物理伙伴)")
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底:兼容目录开关 + 错误

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Toggle("加载 Codex 生态目录", isOn: Binding(
                    get: { viewModel.loadCompatLibrary }, set: { viewModel.setLoadCompatLibrary($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                Toggle("装宠同写生态目录", isOn: Binding(
                    get: { viewModel.dualWriteCompat }, set: { viewModel.setDualWriteCompat($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer(minLength: 0)
            }
            if let err = viewModel.importError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { viewModel.importError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            } else {
                Text("拖入 Shimeji 的 .zip / img 文件夹或 Live2D 模型即可导入。仅本机使用,遵守原作者授权。")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
            .opacity(dropTargeted ? 1 : 0)
    }

    // MARK: - 分类同步

    /// 让选中 tab 跟到当前主宠所在分类(首次出现 + 列表变化时)。`force` 用于刷新后重对齐。
    private func syncCategoryToPrimary(force: Bool = false) {
        guard force || !didSyncCategory else { return }
        didSyncCategory = true
        let cats = availableCategories
        guard !cats.isEmpty else { return }
        if let primary = viewModel.selectedPetItem, cats.contains(primary.category) {
            selectedCategory = primary.category
        } else if !cats.contains(selectedCategory) {
            selectedCategory = cats[0]
        }
    }

    // MARK: - 导入

    private enum ImportKind { case shimeji, live2d }

    private func pickPack(_ kind: ImportKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = kind == .shimeji
            ? "选择 Shimeji 包(.zip 或含 shimeN.png 的 img 文件夹)"
            : "选择 Live2D 模型包(.zip 或含 *.model3.json 的文件夹)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch kind {
        case .shimeji: viewModel.importShimeji(from: url)
        case .live2d: viewModel.importLive2DModel(from: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !viewModel.importInProgress,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) })
        else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
            Task { @MainActor in
                if let url = obj as? URL {
                    viewModel.importDropped(from: url)
                } else {
                    viewModel.importError = "无法读取拖入的文件(仅支持 .zip 或文件夹)"
                }
            }
        }
        return true
    }
}
