import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PetCatalog

// MARK: - CommunityTab

/// 社区桌宠弹窗的 tab 类型。
public enum CommunityTab: String, CaseIterable {
    case codex = "Codex"
    case shimeji = "Shimeji"
}

// MARK: - CommunityPetsSheet

/// 社区桌宠统一弹窗：Codex tab（petdex 在线库一键装）+ Shimeji tab（深链+拖入导入）。
/// 取代散落的 Codex 独立 sheet 与「获取皮肤」独立链接（内嵌抽出的 `PetBrowseContent`），提供单一社区获取入口。
@MainActor
public struct CommunityPetsSheet: View {
    @StateObject private var browseModel: PetBrowseModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var tab: CommunityTab
    @State private var shimejiDropTargeted = false
    @Environment(\.dismiss) private var dismiss
    /// 关闭回调。NSPanel 托管路径(onboarding)必须传 —— 此时 `@Environment(\.dismiss)` 不被 SwiftUI
    /// 桥接进 `NSHostingView` 是 no-op;`.sheet()` 托管路径(库 overlay)留 nil 走 `dismiss` 即可。
    private let onClose: (() -> Void)?

    /// - Parameters:
    ///   - initialTab: 打开时默认选中的 tab，默认 `.codex`。
    ///   - viewModel: 提供 importShimeji / importDropped / importInProgress / importError。
    ///   - onClose: NSPanel 托管时的关闭回调(关面板);`.sheet` 托管留 nil 走 `dismiss`。
    ///   - onInstalled: 每次成功安装后回调（设置面板据此热刷新 picker）。
    init(
        initialTab: CommunityTab = .codex,
        viewModel: SettingsViewModel,
        onClose: (() -> Void)? = nil,
        onInstalled: @escaping @MainActor () -> Void
    ) {
        _browseModel = StateObject(wrappedValue: PetBrowseModel(onInstalled: onInstalled))
        _tab = State(initialValue: initialTab)
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabContent
        }
        .frame(width: 480, height: 580)
    }

    // MARK: 顶部标题 + tab 切换 + 完成

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("社区桌宠").font(.headline)
                Spacer()
                Button("完成") { if let onClose { onClose() } else { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
            Picker("", selection: $tab) {
                ForEach(CommunityTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    // MARK: Tab 内容分发

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .codex:
            codexTab
        case .shimeji:
            shimejiTab
        }
    }

    // MARK: Codex tab

    private var codexTab: some View {
        VStack(spacing: 0) {
            PetBrowseContent(model: browseModel)
            Divider()
            // 底部「前往 petdex 社区」快捷链接
            HStack {
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: CommunityURLs.codexCommunity)!)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("前往 petdex 社区 (codex-pets.net)")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Shimeji tab

    /// Shimeji 获取 tab：深链到火柴人推荐页 + 本地拖入/选择导入 + 合规说明。
    /// 合规红线：只 NSWorkspace.open 深链 + 本地导入，绝不抓 shimeji.org API / 不嵌 WKWebView。
    private var shimejiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ── 推荐位 ──────────────────────────────────────────────────
                recommendedSection
                Divider()
                // ── 拖入导入区 ───────────────────────────────────────────────
                dropZone
                // ── 错误 banner ──────────────────────────────────────────────
                if let err = viewModel.importError {
                    errorBanner(err)
                }
                // ── 浏览社区链接 ─────────────────────────────────────────────
                communityLink
                // ── 合规说明 footnote ────────────────────────────────────────
                complianceFootnote
            }
            .padding(16)
        }
    }

    /// 推荐位：火柴人（Alan Becker）+ 前往下载页按钮。
    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("推荐皮肤").font(.subheadline).fontWeight(.semibold)
            HStack(spacing: 10) {
                // 火柴人缩略图占位符
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 48, height: 48)
                    .overlay(Text("⭐").font(.title2))
                VStack(alignment: .leading, spacing: 3) {
                    Text("火柴人 (Alan Becker)")
                        .font(.system(size: 13, weight: .medium))
                    Text("经典火柴人桌宠，社区热门皮肤")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    // 深链到推荐页，在系统浏览器中打开，不抓任何 API
                    NSWorkspace.shared.open(URL(string: CommunityURLs.shimejiStickman)!)
                } label: {
                    HStack(spacing: 4) {
                        Text("前往下载页")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        }
    }

    /// 拖入区：虚线框 + 说明文案 + 「选择文件…」按钮 + 进度指示。
    private var dropZone: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        shimejiDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(shimejiDropTargeted
                                  ? Color.accentColor.opacity(0.06)
                                  : Color.secondary.opacity(0.04))
                    )
                VStack(spacing: 8) {
                    if viewModel.importInProgress {
                        ProgressView().controlSize(.regular)
                        Text("导入中…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("把下载好的 .zip / img 文件夹拖到这里导入")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("选择文件…") { pickShimeji() }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.importInProgress)
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 140)
            .onDrop(of: [.fileURL], isTargeted: $shimejiDropTargeted) { handleDrop($0) }
        }
    }

    /// 错误 banner（照搬 PetLibraryView footer 的 error 样式）。
    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(err).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { viewModel.importError = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    /// 「浏览 shimeji.org 社区」链接。
    private var communityLink: some View {
        HStack {
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(string: CommunityURLs.shimejiCommunity)!)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("浏览 shimeji.org 社区")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// 合规说明 footnote。
    private var complianceFootnote: some View {
        Text("shimeji.org 是非官方社区站，皮肤版权归原作者；下载自负风险，仅本机使用")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: 导入逻辑（照搬 PetLibraryView）

    /// 「选择文件…」按钮 → NSOpenPanel，仅支持 .zip / 文件夹（照搬 PetLibraryView.pickPack(.shimeji)）。
    private func pickShimeji() {
        let panel = CommunityPetsSheet.makeShimejiImportPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.importShimeji(from: url)
    }

    /// 拖入处理（照搬 PetLibraryView.handleDrop）。
    @discardableResult
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !viewModel.importInProgress,
              let provider = CommunityPetsSheet.firstFileURLProvider(providers)
        else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
            Task { @MainActor in
                if let url = obj as? URL {
                    viewModel.importDropped(from: url)
                } else {
                    viewModel.importError = "无法读取拖入的文件（仅支持 .zip 或文件夹）"
                }
            }
        }
        return true
    }
}

// MARK: - 可无头测试的纯函数

extension CommunityPetsSheet {

    /// 从拖入的 providers 里找第一个能加载文件 URL 的条目（可无头测试）。
    /// - Parameter providers: 拖放操作提供的 `NSItemProvider` 列表。
    /// - Returns: 首个 `canLoadObject(ofClass: NSURL.self)` 为 true 的 provider；全不满足则返回 nil。
    static func firstFileURLProvider(_ providers: [NSItemProvider]) -> NSItemProvider? {
        providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) })
    }

    /// 构造并返回配好的 Shimeji 导入 NSOpenPanel（可无头测试面板属性）。
    /// 调用方只需 `runModal()` + 读取 `panel.url`，不含任何 UI 副作用。
    static func makeShimejiImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "选择 Shimeji 包（.zip 或含 shimeN.png 的 img 文件夹）"
        return panel
    }
}

// MARK: - 社区 URL 常量

/// 社区相关 URL 常量，集中管理便于测试与维护。
enum CommunityURLs {
    /// petdex 官方社区站
    static let codexCommunity = "https://codex-pets.net"
    /// Shimeji 社区站（Task 2 使用）
    static let shimejiCommunity = "https://shimeji.org"
    /// 推荐火柴人皮肤页（Task 2 使用）
    static let shimejiStickman = "https://shimeji.org/u/5stf0k0c"
}
