import AppKit
import SwiftUI

/// 锚定式多轮对话卡片控制器（替代 Spotlight 式单轮 `QuickAskWindowController`）。
///
/// - 双击 pet / ⌥Space / ⌘⇧Space / 灵动岛点击 → `toggle()` 把卡片**弹到 pet 旁**
///   （`ChatCardAnchor.place` 选边 + clamp，spring 从锚点放大进场）。
/// - 多轮：每轮经注入的 `streamProvider`（= orchestrator `replyStream`，**读写
///   ConversationStore** 拼历史上下文）流式；开卡片用 `historyProvider` 从 store 恢复历史。
/// - 卡片**固定尺寸** + 内部 ScrollView 滚动 → 绕开 `NSHostingView(sizingOptions=[])`
///   的动态高坑（lessons-learned §3.2）。
///
/// 设计参照 AccountyCat (https://github.com/strjonas/AccountyCat) 的 WindowCoordinator（锚定 popover）+ 沿用 QuickAsk 的
/// NSPanel / 32ms 流式节流 / canBecomeKey 模式。
@MainActor
public final class ChatCardWindowController {

    // MARK: - Types

    /// 多轮流式 provider。注入自 App：内部走 `replyStream`（写 ConversationStore + 拼历史）。
    public typealias StreamProvider = @MainActor (String) -> AsyncThrowingStream<String, Error>
    /// 历史快照 provider。注入自 App：读 `ConversationStore.messages()` 映射成 `[ChatCardRow]`。
    public typealias HistoryProvider = @MainActor () async -> [ChatCardRow]

    // MARK: - Public surface

    /// 测试访问器：窗口实例（首次 show 前 nil）。
    public var window: NSPanel? { panel }
    /// 测试 / wiring 访问器：卡片状态。
    public var cardState: ChatCardState { state }
    /// wiring 访问器：外部会话流 store（Claude Code / Codex tab 渲染源）。
    /// App 接线层往里喂实时 events（`appendLive`）+ 卡片弹出时回填历史（`setHistory`）。
    public var agentSessionStore: AgentSessionStore { sessionStore }

    /// App 注入：pet 锚矩形（屏幕坐标）。缺席/拿不到时回退 `.zero` → 卡片落屏幕左下角边距处。
    public var anchorRectProvider: (@MainActor () -> NSRect)?
    /// App 注入：屏幕可见区。缺席回退主屏 visibleFrame。
    public var screenFrameProvider: (@MainActor () -> NSRect)?
    /// App 注入：开卡片时恢复历史。缺席则不恢复（空卡片）。
    public var historyProvider: HistoryProvider?
    /// App 注入：「清空对话」点击 → app 弹确认框 → 清 `ConversationStore` + `clearMessages()`。
    /// 仅 Pet Chat tab + 有消息时卡片才露出清空按钮（`ChatCardView` 控制可见性）。
    public var onClearConversation: (@MainActor () -> Void)?
    /// App 注入：开卡片时回填外部会话历史到 `sessionStore`（读活跃 transcript 尾部）。
    /// 在卡片**弹出之后**异步调（reader 文件读在后台，store 更新驱动 tab 视图，不阻塞进场）。
    public var sessionHistoryLoader: (@MainActor () async -> Void)?

    /// App 注入：回复来源配置 provider（当前 target + 可选项）。每次开卡调，从 UserDefaults
    /// 派生最新值刷进 state → 驱动 `ReplySourceBar`（同步设置面板的改动，两处写同一份 UD）。
    /// nil → 不显示回复来源选择器。
    public var replyConfigurationProvider: (@MainActor () -> (target: ReplyTarget, options: [ReplyOption]))?
    /// App 注入：用户切回复来源 → 写 UserDefaults + `router.setEngine` 即时生效。
    public var onCommitReplyTarget: (@MainActor (ReplyTarget) -> Void)?

    /// App 注入:项目配置 provider(当前 project + 可选项)。每次开卡调,从 `ProjectStore` 派生
    /// 最新值刷进 state → 驱动 `ProjectMenu`。nil → 不显示项目选择器。mirror `replyConfigurationProvider`。
    public var projectProvider: (@MainActor () -> (current: ProjectOption, projects: [ProjectOption]))?
    /// App 注入:用户切项目 → 写 UD `tool.project.id` + `applySelectedAgentEngine` 重 apply 即时生效。
    public var onCommitProject: (@MainActor (String) -> Void)?
    /// App 注入:用户点「新建项目」→ 弹 NSAlert 收名字 + `ProjectStore.create` + 刷新。
    public var onRequestCreateProject: (@MainActor () -> Void)?
    /// App 注入:用户点「添加外部项目」→ NSOpenPanel 选目录 + `ProjectStore.createExternal` + 刷新。
    public var onRequestCreateExternal: (@MainActor () -> Void)?
    /// App 注入:用户点「重命名当前项目」→ NSAlert 收新名 + `ProjectStore.rename` + 刷新。
    public var onRequestRenameCurrent: (@MainActor () -> Void)?
    /// App 注入:用户点「删除当前项目」→ NSAlert 确认 + `ProjectStore.delete` + setCurrent(default) + 刷新。
    public var onRequestDeleteCurrent: (@MainActor () -> Void)?
    /// App 注入:用户点「同步 Codex 配置」→ 显式 materialize 当前项目的 Codex projection。
    public var onRequestSyncCodexProjection: (@MainActor () -> Void)?

    // MARK: - Init

    public init(streamProvider: @escaping StreamProvider) {
        self.streamProvider = streamProvider
    }

    // MARK: - 入口

    /// 双击 pet / ⌥Space / 灵动岛点击：已显示 → 隐藏；未显示 → 弹出。
    public func toggle() {
        if let panel, panel.isVisible { hide() } else { show(prefill: nil) }
    }

    /// ⌘⇧Space：有选中文本则预填 composer（**不自动发送**，HermesPet 决策 #17）。
    public func toggleWithSelectedText(_ text: String?) {
        if let panel, panel.isVisible { hide(); return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        show(prefill: (trimmed?.isEmpty == false) ? trimmed : nil)
    }

    /// ChoiceCard 点击：填到 composer，不自动发送。
    public func toggleWithText(_ text: String) {
        if let panel, panel.isVisible { state.draft = text } else { show(prefill: text) }
    }

    /// 清空对话：重置 Pet Chat 卡片视图态（`ConversationStore` 已由 caller 清空）。
    /// 取消在途流式 + 清消息/草稿；下次开卡从已清空的 store 恢复（即空历史）。
    public func clearMessages() {
        state.cancelStreaming()
        state.messages = []
        state.draft = ""
    }

    /// 程序化弹卡到指定 tab（权限/问题来了自动弹 + 切到 Claude Code tab）。
    /// 已可见 → 只切 tab（不重播进场）；未可见 → 切 tab 后弹出。
    public func presentOnTab(_ tab: CompanionTab) {
        state.selectedTab = tab
        if panel == nil || panel?.isVisible == false { show(prefill: nil) }
    }

    /// 隐藏 + 取消 in-flight stream（保留 messages，重开仍在）。
    public func hide() {
        state.cancelStreaming()
        state.isShown = false
        panel?.orderOut(nil)
    }

    /// 主卡当前钉住态(列容器据此同步层级:容器与主卡作一组,层级须一致)。
    public var isPinned: Bool { state.isPinned }
    /// 主卡钉住态切换回调(App 接到 → 同步列容器层级)。
    public var onPinChanged: ((Bool) -> Void)?

    /// #3 切换主卡钉住:钉住=floating+1+.stationary 常驻浮顶;取消=.normal+.transient 可被盖(标准切应用)。
    public func togglePin() {
        state.isPinned.toggle()
        WindowPinState.apply(panel, pinned: state.isPinned)
        onPinChanged?(state.isPinned)   // 列容器同步层级(否则主卡浮顶、容器 .normal 切 Space 消失)
    }

    // MARK: - 发送（乐观追加 + 流式 32ms 节流）。internal 供单测直调。

    func handleSend(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !state.isSending else { return }
        state.draft = ""
        let assistantID = state.appendExchangePlaceholder(userText: trimmed)
        state.isSending = true
        let provider = streamProvider
        state.streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = provider(trimmed)
                var full = ""
                var lastUpdateAt = Date.distantPast
                for try await delta in stream {
                    try Task.checkCancellation()
                    state.isThinking = false   // message 来,清思考中(ACP thought UI)
                    full += delta
                    let now = Date()
                    if now.timeIntervalSince(lastUpdateAt) >= 0.032 {
                        // 逐次清洗：剥推理泄漏（纯推理阶段返回 "" → 显示打点，不流式英文推理）。
                        self.state.updateAssistant(id: assistantID, text: ChatReplyCleaner.clean(full))
                        lastUpdateAt = now
                    }
                }
                // 终态：清洗；若清洗后为空（极端：整段是推理没出答案）回退原文，不丢内容。
                let cleaned = ChatReplyCleaner.clean(full)
                self.state.updateAssistant(id: assistantID, text: cleaned.isEmpty ? (full.isEmpty ? "（没有回应）" : full) : cleaned)
            } catch is CancellationError {
                // 用户主动取消 — silent
            } catch {
                self.state.updateAssistant(id: assistantID, text: "❌ \(error.localizedDescription)")
            }
            self.state.isSending = false
        }
    }

    // MARK: - 私有

    private func show(prefill: String?) {
        if panel == nil { createPanel() }
        syncReplyConfiguration()   // 开卡时从 UD 刷回复来源 segmented（同步设置面板的改动）
        syncProjectConfiguration()  // 开卡时从 ProjectStore 刷项目 Menu（同步外部改动）
        if let prefill, !prefill.isEmpty { state.draft = prefill }
        // 先从 store 恢复历史（仅本会话尚无消息时），再定位 + spring 进场 → 卡片弹出即满载，
        // 不会"开卡时内容一闪而入"。历史读是 actor 快照（亚毫秒级），不会明显拖慢弹出。
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.state.messages.isEmpty, let historyProvider = self.historyProvider {
                self.state.load(history: await historyProvider())
            }
            self.positionAndPresent()
            // 外部会话历史在弹出后台补（文件读在 loader 内部 off-main，store 更新驱动 tab 视图）。
            await self.sessionHistoryLoader?()
        }
    }

    /// 从 App 注入的 provider 刷新回复来源配置到 state（开卡时同步设置面板改动）+ 透传 onCommit。
    private func syncReplyConfiguration() {
        if let cfg = replyConfigurationProvider?() {
            state.replyTarget = cfg.target
            state.replyOptions = cfg.options
        }
        state.onCommitReplyTarget = onCommitReplyTarget
    }

    /// 从 App 注入的 provider 刷新项目配置到 state(开卡时 + 创建项目后调)+ 透传回调。
    /// mirror `syncReplyConfiguration`。
    private func syncProjectConfiguration() {
        if let cfg = projectProvider?() {
            state.currentProject = cfg.current
            state.projects = cfg.projects
        }
        state.onCommitProject = onCommitProject
        state.onRequestCreateProject = onRequestCreateProject
        state.onRequestCreateExternal = onRequestCreateExternal
        state.onRequestRenameCurrent = onRequestRenameCurrent
        state.onRequestDeleteCurrent = onRequestDeleteCurrent
        state.onRequestSyncCodexProjection = onRequestSyncCodexProjection
    }

    /// 刷新项目配置(public,App 创建项目后调,驱动 `ProjectMenu` 更新列表)。
    @MainActor public func refreshProjectConfiguration() {
        syncProjectConfiguration()
    }

    /// 锚定定位 + 弹出 + spring 进场。固定尺寸，不依赖历史。
    private func positionAndPresent() {
        guard let panel else { return }
        applyPlacement(to: panel)
        state.isShown = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 下一拍 spring 放大（先渲染缩小态一帧，进场才有"弹"的观感）。
        DispatchQueue.main.async { [weak self] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                self?.state.isShown = true
            }
        }
    }

    /// 跟随 pet：卡片可见时按 pet 实时位置重算锚定 + 尖角（**不重播 spring**）。
    /// 由 App 监听 pet 窗口 `didMove` 调用。带位移阈值（3pt）过滤物理微抖，避免 setFrame 抖动 + 毛玻璃反复重绘。
    public func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        let petRect = anchorRectProvider?() ?? .zero
        if let last = lastAnchorMid, abs(last.x - petRect.midX) < 3, abs(last.y - petRect.midY) < 3 { return }
        applyPlacement(to: panel)
    }

    /// 算锚定（origin + 边）→ 设 frame + 驱动尖角朝向/位置 + 记录 pet 锚点（供位移阈值判定）。
    private func applyPlacement(to panel: NSPanel) {
        let petRect = anchorRectProvider?() ?? .zero
        let visible = screenFrameProvider?() ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: ChatCardTheme.cardWidth, height: ChatCardTheme.cardHeight)
        let placement = ChatCardAnchor.place(anchor: petRect, in: visible, cardSize: size)
        state.entranceEdge = placement.edge
        state.tailSide = ChatCardAnchor.tailSide(for: placement.edge)
        state.tailPercent = ChatCardAnchor.tailPercent(
            edge: placement.edge, petRect: petRect, cardOrigin: placement.origin, cardSize: size
        )
        panel.setFrame(NSRect(origin: placement.origin, size: size), display: true)
        lastAnchorMid = NSPoint(x: petRect.midX, y: petRect.midY)
    }

    private func createPanel() {
        let size = NSSize(width: ChatCardTheme.cardWidth, height: ChatCardTheme.cardHeight)
        let p = ChatCardPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        // #3 主卡钉住态:默认钉住=floating+1+.stationary(压过 pet/灵动岛/普通窗,低于 menubar;跨 Space 常驻)。
        // 取消钉住 → .normal+.transient 可被其他 app 盖住(标准切应用)。level + collectionBehavior 经 applyPinState 同步切
        //(顺带修主卡原 .transient bug:钉住卡切 Space/Mission Control 被系统自动隐藏)。
        WindowPinState.apply(p, pinned: state.isPinned)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true                              // 系统按 alpha mask 沿圆角精确绘制阴影
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let host = NSHostingView(rootView: ChatCardView(
            state: state,
            sessionStore: sessionStore,
            onSend: { [weak self] text in self?.handleSend(text) },
            onClose: { [weak self] in self?.hide() },
            onTogglePin: { [weak self] in self?.togglePin() },
            onClearConversation: { [weak self] in self?.onClearConversation?() }
        ))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        // 卡片是固定浅色卡，强制 .aqua → 语义色按浅色渲染成深色字，避免系统暗色模式下
        // markdown 正文 / 代码块（走 .primary）变白 → 浅底白字看不清。
        host.appearance = NSAppearance(named: .aqua)
        if #available(macOS 13.0, *) {
            host.sizingOptions = []  // 防 SwiftUI 反推 setFrame（HermesPet 决策 #6 / §3.2）
        }
        p.contentView = host

        self.panel = p
        self.hostingView = host
    }

    // MARK: - Stored

    private let streamProvider: StreamProvider
    private let state = ChatCardState()
    private let sessionStore = AgentSessionStore()
    private var panel: ChatCardPanel?
    private var hostingView: NSHostingView<ChatCardView>?
    /// 上次定位时的 pet 中心，跟随时用位移阈值过滤微抖。
    private var lastAnchorMid: NSPoint?
}

// MARK: - ChatCardPanel

/// 需 `canBecomeKey = true` 才能让 composer 的 NSTextField 接键盘焦点
/// （.nonactivatingPanel + .borderless 默认不接 key，必须 override）。
final class ChatCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
