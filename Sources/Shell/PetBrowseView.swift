import SwiftUI
import PetCatalog

// MARK: - PetBrowseContent

/// Codex 在线桌宠浏览内容视图(无 sheet chrome)。供嵌入 `CommunityPetsSheet` 的 Codex tab，
/// 或独立使用。保留完整「装≠选」三态 + 缩略图 + 下载失败 banner 逻辑。
/// **不含「完成」按钮**——由外层 sheet 提供。
@MainActor
struct PetBrowseContent: View {
    @ObservedObject var model: PetBrowseModel
    @StateObject private var thumbs = RemoteThumbnailLoader()

    var body: some View {
        VStack(spacing: 0) {
            searchAndFilter
            listContent
        }
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: 搜索栏 + 分类段

    private var searchAndFilter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称…", text: $model.query).textFieldStyle(.roundedBorder)
            }
            Picker("", selection: $model.category) {
                ForEach(PetCatalogKind.segments, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: 列表内容

    @ViewBuilder
    private var listContent: some View {
        if let err = model.downloadError {
            downloadBanner(err) { model.downloadError = nil }
        }
        if model.isLoading {
            Spacer(); ProgressView("加载桌宠库…"); Spacer()
        } else if let loadErr = model.loadError, model.pets.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(loadErr).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { model.loadError = nil; model.loadIfNeeded() }
            }.padding()
            Spacer()
        } else if model.results.isEmpty {
            Spacer(); Text("没有匹配的桌宠").foregroundStyle(.secondary); Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { pet in
                        petRow(pet)
                        Divider()
                    }
                }
            }
        }
    }

    private func petRow(_ pet: RemotePet) -> some View {
        HStack(spacing: 10) {
            thumbnail(pet)
                .frame(width: 32, height: 32)
                .task { thumbs.load(pet.spritesheetUrl) }
            VStack(alignment: .leading, spacing: 2) {
                Text(pet.name).font(.system(size: 13, weight: .medium))
                Text("by \(pet.author)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            actionButton(pet)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func actionButton(_ pet: RemotePet) -> some View {
        if model.installed.contains(pet.slug) {
            Label("已装", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
        } else if model.downloading.contains(pet.slug) {
            ProgressView().controlSize(.small)
        } else {
            Button("获取") { model.download(pet) }.controlSize(.small)
        }
    }

    private func downloadBanner(_ text: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    /// 真实缩略图(idle 首帧)加载完显示;未完/失败显 kind 占位图标。
    @ViewBuilder
    private func thumbnail(_ pet: RemotePet) -> some View {
        if let img = thumbs.thumbnail(for: pet.spritesheetUrl) {
            Image(nsImage: img)
                .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: kindSymbol(pet.kind))
                .font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    private func kindSymbol(_ kind: String?) -> String {
        switch kind {
        case "character": return "person.fill"
        case "creature": return "pawprint.fill"
        case "object": return "cube.fill"
        default: return "sparkles"
        }
    }
}

