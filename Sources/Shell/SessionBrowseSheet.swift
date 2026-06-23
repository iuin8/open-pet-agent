import AgentSensing
import SwiftUI

/// 访达选目录后的会话浏览 sheet(spec §1):头(目录) + 会话卡列表(`SessionRowCard`,同 picker) + 每行 📌/复制 + 点行加载。
///
/// **钉住单一真相**:`@ObservedObject pinnedStore` —— 直接观察持久化源,不再用本地 `@State` 快照。
/// 在 sheet 里点 📌 → 经 `onTogglePin`→App→`store.togglePin`→`pinnedStore.pin/unpin` 发 `objectWillChange`
/// → sheet 与 picker 同步刷新(根治「历史列表与内建列表钉住不同步」)。
public struct SessionBrowseSheet: View {
    let dirLabel: String
    /// 据此拼复制命令 + 查钉住态(`pinnedStore.isPinned(agent:sessionId:)`)。
    let agent: AgentKind
    @ObservedObject var pinnedStore: PinnedSessionStore
    let sessions: [BrowsedSession]
    let onLoad: (BrowsedSession) -> Void
    let onTogglePin: (BrowsedSession) -> Void
    let onClose: () -> Void
    /// 窗口**置顶**(default off):新值回调给 App 设窗口层级 + dismiss 豁免(与列容器同一 `CardPinButton`)。
    let onTogglePinWindow: (Bool) -> Void
    /// 本卡置顶态(@State 即时翻按钮 + 经回调驱动 App 应用窗口层级/dismiss 豁免)。
    @State private var windowPinned = false

    public init(dirLabel: String, agent: AgentKind, pinnedStore: PinnedSessionStore,
                sessions: [BrowsedSession],
                onLoad: @escaping (BrowsedSession) -> Void, onTogglePin: @escaping (BrowsedSession) -> Void,
                onClose: @escaping () -> Void, onTogglePinWindow: @escaping (Bool) -> Void) {
        self.dirLabel = dirLabel; self.agent = agent; self.pinnedStore = pinnedStore
        self.sessions = sessions
        self.onLoad = onLoad; self.onTogglePin = onTogglePin; self.onClose = onClose
        self.onTogglePinWindow = onTogglePinWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5)
            if sessions.isEmpty {
                Text("该目录无会话历史")
                    .font(ChatCardTheme.body)
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 4) { ForEach(sessions) { row(for: $0) } }.padding(8) }
            }
        }
        .frame(width: 420, height: 460)
        .background(ChatCardTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ChatCardTheme.cardRadius, style: .continuous))   // 无原生标题栏 → 自身圆角卡(窗口 hasShadow 沿此 alpha 描边)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(ChatCardTheme.accent)
            Text(dirLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.85))   // 必 pin 卡墨色:默认 .primary 在暗色模式=白=隐形
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(sessions.count) 个会话")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
            CardPinButton(isPinned: windowPinned) { windowPinned.toggle(); onTogglePinWindow(windowPinned) }  // 置顶(同主卡/列容器)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5)).frame(width: 22, height: 22)
            }.buttonStyle(.plain)
        }
        .padding(12)
    }

    /// 一张会话卡(同 picker 的 `SessionRowCard`):点卡加载;📌 切钉住;复制按钮拷续聊命令。
    /// 钉住态实时读自 `pinnedStore`(浏览来的会话非「选中」,故 `isSelected: false`)。
    private func row(for b: BrowsedSession) -> some View {
        SessionRowCard(
            summary: b.summary,
            isSelected: false,
            isPinned: pinnedStore.isPinned(agent: agent, sessionId: b.id),
            copyCommand: SessionResumeCommand.command(agent: agent, sessionId: b.id),
            onTap: { onLoad(b) },
            onTogglePin: { onTogglePin(b) }
        )
    }
}
