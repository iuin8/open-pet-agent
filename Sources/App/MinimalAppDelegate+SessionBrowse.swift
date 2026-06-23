import AgentSensing
import AppKit
import Shell
import SwiftUI

/// 会话历史浏览 + 钉住接线(spec 2026-06-20)。picker 📌 / 「浏览历史…」回调 → 这里:
/// NSOpenPanel 选目录 → `SessionDirectoryBrowser` 扫会话 → 异步补元数据 → `SessionBrowseSheet`;
/// 钉住经 `PinnedSessionStore` 持久化;启动加载钉住会话进列表 + `loadedSessionURLs`(加载用)。
extension MinimalAppDelegate {

    /// 在 `setupAgentSensing` 末尾调:注入钉住 store + 接 picker 回调 + 启动加载钉住。
    @MainActor
    func wireSessionBrowseAndPin() {
        guard let store = chatCardWindowController?.agentSessionStore else { return }
        store.setPinnedStore(pinnedSessionStore)
        store.onTogglePinRequested = { [weak self] agent, sid in self?.togglePinForSession(agent: agent, sessionId: sid) }
        store.onBrowseHistory = { [weak self] agent in self?.presentSessionBrowse(agent: agent) }
        // 互斥:开列容器侧卡前关浏览 sheet(同时只一张侧卡)。
        columnContainerWindowController.onWillOpen = { [weak self] in self?.closeBrowseSheet() }
        loadPinnedSessions(agent: .claudeCode)
        loadPinnedSessions(agent: .codex)
        debugPinTestIfRequested()
        debugSessionCardIfRequested()
    }

    /// 点主卡任意位置 → 关**未置顶**的侧卡(列容器 + 浏览 sheet)。置顶的卡豁免(由 `onBackgroundClick` 调)。
    @MainActor
    func dismissSideCards() {
        if !columnContainerWindowController.isPinned { columnContainerWindowController.close() }
        if !browseSheetPinned { closeBrowseSheet() }
    }

    /// 调试钩子(env `PETAGENT_DEBUG_SESSIONCARD`):用合成会话弹**真** `SessionBrowseSheet` →
    /// 截图确定性验共享卡片(`SessionRowCard`,picker/sheet 同款):卡片化 + 复制按钮 + 钉住态 + 活跃绿点 + 副行。
    /// 用一次性 UserDefaults 域(`debug-sessioncard`)托钉住,不污染真实偏好;onTogglePin 直接驱动它 →
    /// 点 📌 即时翻(实证 `@ObservedObject pinnedStore` 重渲)。
    @MainActor
    func debugSessionCardIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_SESSIONCARD"] else { return }
        let now = Date()
        func browsed(_ sid: String, title: String?, branch: String?, count: Int?, ageSec: TimeInterval,
                     url: URL? = nil) -> BrowsedSession {
            let s = AgentSessionSummary(id: sid, label: "pet-agent", lastActivity: now.addingTimeInterval(-ageSec),
                                        isSelected: false, title: title, messageCount: count, contextTokens: nil,
                                        gitBranch: branch, lastModified: now.addingTimeInterval(-ageSec))
            return BrowsedSession(ref: AgentSessionRef(agent: .claudeCode, sessionId: sid,
                                                       url: url ?? URL(fileURLWithPath: "/tmp/\(sid).jsonl")), summary: s)
        }
        let sessions = [
            browsed("live01", title: "重构会话流卡片", branch: "feature/proactive", count: 142, ageSec: 5),    // 活跃绿点
            browsed("pin02", title: "雪物理调参", branch: "main", count: 88, ageSec: 7200),                    // 已钉住
            browsed("norm03", title: nil, branch: nil, count: 12, ageSec: 86400),                              // 标题回退项目名
        ]
        let store = PinnedSessionStore(defaults: UserDefaults(suiteName: "debug-sessioncard")!)
        for p in store.pinned(for: .claudeCode) { store.unpin(agent: .claudeCode, sessionId: p.sessionId) }   // 清旧
        store.pin(PinnedSessionRef(agent: .claudeCode, sessionId: "pin02", filePath: "/tmp/pin02.jsonl",
                                   title: "雪物理调参", gitBranch: "main", pinnedAt: now))
        let sheet = SessionBrowseSheet(
            dirLabel: "DEBUG · pet-agent 历史", agent: .claudeCode, pinnedStore: store, sessions: sessions,
            onLoad: { b in NSLog("[SESSIONCARD] onLoad sid=\(b.id)") },
            onTogglePin: { b in
                if store.isPinned(agent: .claudeCode, sessionId: b.id) {
                    store.unpin(agent: .claudeCode, sessionId: b.id)
                } else {
                    store.pin(PinnedSessionRef(agent: .claudeCode, sessionId: b.id, filePath: b.ref.url.path,
                                               title: b.summary.title, gitBranch: b.summary.gitBranch, pinnedAt: Date()))
                }
                NSLog("[SESSIONCARD] toggled pin sid=\(b.id) → \(store.isPinned(agent: .claudeCode, sessionId: b.id))")
            },
            onClose: { [weak self] in self?.closeBrowseSheet() },
            onTogglePinWindow: { [weak self] pinned in
                self?.browseSheetPinned = pinned
                WindowPinState.apply(self?.sessionBrowsePanel, pinned: pinned)
            }
        )
        // `=beside`:先开陪伴卡 → `makeBrowseCardPanel` 据 mainCardFrame 把 sheet 贴卡侧(验 #1 不被遮挡定位)。
        if mode == "beside" { chatCardWindowController?.presentOnTab(.claudeCode) }
        let panel = makeBrowseCardPanel(hosting: sheet)          // 无边框圆角卡 + 贴主卡侧定位
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        sessionBrowsePanel = panel
        NSLog("[SESSIONCARD] presented sheet \(mode == "beside" ? "beside card" : "standalone"), frame=\(NSStringFromRect(panel.frame))")
        // `=beside` 跟随测:+1s 移动 pet(触发 didMove 观察 → 卡 + sheet 重定位)→ 量 sheet 是否一起走。
        if mode == "beside" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                let before = self.sessionBrowsePanel?.frame.minX ?? 0
                if let pet = self.shellController?.windowSet.petWindow {
                    pet.setFrameOrigin(NSPoint(x: pet.frame.minX + 180, y: pet.frame.minY))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let after = self.sessionBrowsePanel?.frame.minX ?? 0
                    NSLog("[SESSIONCARD] follow-test sheet.minX \(before) → \(after) (movedX=\(after - before))")
                }
            }
        }
    }

    /// 调试钩子(env `PETAGENT_DEBUG_PINTEST`):自动化验「钉住 → 重启仍在」。三模式 + NSLog[PINTEST] grep:
    /// - `pin`：找一个真实 Claude 会话文件 → 走真实 `PinnedSessionStore.pin` 钉住 + 打 sid/path(然后退出重启)。
    /// - `verify`：重启后 `wireSessionBrowseAndPin` 已 `loadPinnedSessions` → +1s 核每个持久化 pin 是否在合成列表 + isPinned(PASS/FAIL)。
    /// - `clean`：清掉所有钉住(测试后复原,别留永久钉)。用法:`=pin` 跑→pkill→`=verify` 跑→grep PINTEST。
    @MainActor
    func debugPinTestIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_PINTEST"] else { return }
        switch mode {
        case "pin":
            guard let url = Self.findAnyClaudeSessionFile() else { NSLog("[PINTEST] FAIL: 找不到真实 Claude 会话文件"); return }
            let sid = url.deletingPathExtension().lastPathComponent
            pinnedSessionStore.pin(PinnedSessionRef(agent: .claudeCode, sessionId: sid, filePath: url.path,
                                                    title: "PINTEST-\(sid.prefix(6))", gitBranch: nil, pinnedAt: Date()))
            NSLog("[PINTEST] pinned sid=\(sid) path=\(url.path) persistCount=\(pinnedSessionStore.pinned(for: .claudeCode).count)")
        case "verify":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let store = self.chatCardWindowController?.agentSessionStore else { return }
                let pins = self.pinnedSessionStore.pinned(for: .claudeCode)
                guard !pins.isEmpty else { NSLog("[PINTEST] FAIL: 重启后无持久化钉住(UserDefaults 没存住)"); return }
                for p in pins {
                    let row = store.sessions(for: .claudeCode).first { $0.id == p.sessionId }
                    let ok = row != nil && row?.isPinned == true
                    NSLog("[PINTEST] \(ok ? "PASS" : "FAIL"): sid=\(p.sessionId) inList=\(row != nil) isPinned=\(row?.isPinned ?? false) unavailable=\(row?.isUnavailable ?? false) title=\(row?.title ?? "nil")")
                }
            }
        case "clean":
            for ag in [AgentKind.claudeCode, .codex] {
                for p in pinnedSessionStore.pinned(for: ag) { pinnedSessionStore.unpin(agent: ag, sessionId: p.sessionId) }
            }
            NSLog("[PINTEST] cleaned all pins")
        default: break
        }
    }

    /// 扫 `~/.claude/projects/*/` 找任意一个真实会话 `*.jsonl`(给 PINTEST 用)。
    nonisolated static func findAnyClaudeSessionFile() -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projDirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for proj in projDirs {
            if let files = try? FileManager.default.contentsOfDirectory(at: proj, includingPropertiesForKeys: nil),
               let jsonl = files.first(where: { $0.pathExtension == "jsonl" }) {
                return jsonl
            }
        }
        return nil
    }

    /// 启动加载钉住会话:文件存在 → 进 `loadedSessionURLs`(加载用)+ 异步扫元数据补 `noteLoadedSession`(行渲染);
    /// 文件没了 → 跳过(行靠钉住缓存 title 显)。
    @MainActor
    private func loadPinnedSessions(agent: AgentKind) {
        guard let store = chatCardWindowController?.agentSessionStore else { return }
        for ref in pinnedSessionStore.pinned(for: agent) where FileManager.default.fileExists(atPath: ref.filePath) {
            let url = URL(fileURLWithPath: ref.filePath)
            loadedSessionURLs[agent, default: [:]][ref.sessionId] = url
            Task { @MainActor in
                // 文件在就**一定**注入元数据(扫到用扫的,扫不到用钉缓存兜底)→ m≠nil → 不被判 isUnavailable 灰显
                // (#2:钉住但元数据扫空的会话在 picker 点不了;文件真没了的会话在上面 `where fileExists` 已被跳过)。
                let m = await agentSessionMetadataScanner.metadata(for: url, agent: agent)
                    ?? SessionMetadata(title: ref.title, projectName: ref.title ?? String(ref.sessionId.prefix(8)),
                                       startTime: nil, gitBranch: ref.gitBranch, messageCount: nil,
                                       contextTokens: nil, lastModified: ref.pinnedAt)
                store.noteLoadedSession(agent: agent, sessionId: ref.sessionId, meta: m)
            }
        }
        store.refreshPinned(agent)
    }

    /// 点 picker 行 📌:据当前 summary + 文件 URL(已加载 / 活跃)构 `PinnedSessionRef` → `togglePin`。
    /// `recentSessions()` 是 actor 隔离 → 包进 Task await(取活跃会话 URL 兜底,已加载的优先同步取)。
    @MainActor
    private func togglePinForSession(agent: AgentKind, sessionId sid: String) {
        Task { @MainActor in
            guard let store = chatCardWindowController?.agentSessionStore else { return }
            let summary = store.sessions(for: agent).first { $0.id == sid }
            var url = loadedSessionURLs[agent]?[sid]
            if url == nil {
                url = (await agentSensingService?.recentSessions())?.first { $0.agent == agent && $0.sessionId == sid }?.url
            }
            // C1:要 pin(当前未钉)却取不到文件 URL → **不钉**(避免空 filePath 持久化后重启不可加载);unpin 不需 URL。
            let alreadyPinned = pinnedSessionStore.isPinned(agent: agent, sessionId: sid)
            guard alreadyPinned || url != nil else { return }
            let ref = PinnedSessionRef(agent: agent, sessionId: sid, filePath: url?.path ?? "",
                                       title: summary?.title, gitBranch: summary?.gitBranch, pinnedAt: Date())
            store.togglePin(agent: agent, sessionId: sid, ref: ref)
        }
    }

    // MARK: - 浏览历史

    /// 点「浏览历史…」:NSOpenPanel 选目录 → 扫会话 → 异步补元数据 → 弹 sheet。
    @MainActor
    private func presentSessionBrowse(agent: AgentKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选项目目录(自动解析)或 ~/.claude/projects 下的会话目录 → 浏览其历史会话"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let refs = SessionDirectoryBrowser.sessions(picked: dir, agent: agent)
        let dirLabel = dir.lastPathComponent
        Task { @MainActor in
            var browsed: [BrowsedSession] = []
            for ref in refs {
                let meta = await agentSessionMetadataScanner.metadata(for: ref.url, agent: agent)
                let summary = AgentSessionSummary(
                    id: ref.sessionId,
                    label: meta?.projectName ?? String(ref.sessionId.prefix(8)),
                    lastActivity: meta?.lastModified ?? .distantPast,
                    isSelected: false,
                    title: meta?.title, messageCount: meta?.messageCount,
                    contextTokens: meta?.contextTokens, gitBranch: meta?.gitBranch,
                    lastModified: meta?.lastModified
                )
                browsed.append(BrowsedSession(ref: ref, summary: summary))
            }
            browsed.sort { ($0.summary.lastModified ?? .distantPast) > ($1.summary.lastModified ?? .distantPast) }
            self.showBrowseSheet(agent: agent, dirLabel: dirLabel, sessions: browsed)
        }
    }

    @MainActor
    private func showBrowseSheet(agent: AgentKind, dirLabel: String, sessions: [BrowsedSession]) {
        closeBrowseSheet()   // I2:关掉旧 panel,防连续浏览产生僵尸窗
        columnContainerWindowController.close()   // 互斥:开浏览 sheet → 关列容器(同时只一张侧卡)
        let sheet = SessionBrowseSheet(
            dirLabel: dirLabel,
            agent: agent,
            pinnedStore: pinnedSessionStore,   // 单一钉住真相:sheet 观察它 → 与 picker 同步
            sessions: sessions,
            onLoad: { [weak self] b in self?.loadBrowsedSession(agent: agent, b); self?.closeBrowseSheet() },
            onTogglePin: { [weak self] b in self?.togglePinForBrowsed(agent: agent, b) },
            onClose: { [weak self] in self?.closeBrowseSheet() },
            onTogglePinWindow: { [weak self] pinned in
                self?.browseSheetPinned = pinned
                WindowPinState.apply(self?.sessionBrowsePanel, pinned: pinned)   // 置顶=常驻浮顶;取消=可被盖+点主卡可关
            }
        )
        let panel = makeBrowseCardPanel(hosting: sheet)   // 无原生标题栏的圆角卡(去掉红绿灯 + 标题,内容自带头)
        panel.makeKeyAndOrderFront(nil)
        sessionBrowsePanel = panel
    }

    /// 承载浏览 sheet 的**无边框圆角卡面板**(同列容器/陪伴卡审美):去掉 macOS 原生标题栏 + 红绿灯,
    /// 内容自带头(文件夹 + 会话数 + ✕)。`hasShadow` 沿 sheet 内 `.clipShape` 圆角 alpha 描边;
    /// `.nonactivatingPanel` 不抢焦也能点行/📌/复制(同 `ColumnContainerWindowController` 证)。
    @MainActor
    private func makeBrowseCardPanel(hosting sheet: SessionBrowseSheet) -> NSPanel {
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 460)
        host.appearance = NSAppearance(named: .aqua)   // 卡底固定浅色 → 强制浅色外观,免暗色模式下默认色反相(同列容器)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        positionBesideMain(panel, size: Self.browseSheetSize)   // 贴主卡侧(侧卡式),免被陪伴卡遮挡(#1)
        return panel
    }

    /// 浏览 sheet 固定尺寸。
    static let browseSheetSize = NSSize(width: 420, height: 460)

    /// 把浏览 sheet 贴**主陪伴卡空白侧**(走 `BesideMainLayout` 单一真相,与列容器同源)→ 不被陪伴卡遮挡(#1)。
    /// 无主卡(frame 为零)→ 居中兜底。
    @MainActor
    private func positionBesideMain(_ panel: NSPanel, size: NSSize) {
        let mainFrame = mainCardFrame(), screen = currentScreenFrame()
        guard mainFrame != .zero, screen != .zero else { panel.center(); return }
        panel.setFrame(BesideMainLayout.frame(maxSize: size, mainFrame: mainFrame, screen: screen), display: false)
    }

    /// 浏览 sheet 跟随主卡移动(与列容器一致,经同一 pet `didMove` 观察触发)→ 「侧卡跟主卡走」逻辑统一。
    @MainActor
    func repositionBrowseSheetIfVisible() {
        guard let panel = sessionBrowsePanel, panel.isVisible else { return }
        positionBesideMain(panel, size: Self.browseSheetSize)
    }

    /// 点浏览历史里的某会话 → 注入元数据 + 载入主卡当前 tab(浏览从当前 tab 触发,无需切 tab)。
    @MainActor
    private func loadBrowsedSession(agent: AgentKind, _ b: BrowsedSession) {
        guard let store = chatCardWindowController?.agentSessionStore else { return }
        loadedSessionURLs[agent, default: [:]][b.ref.sessionId] = b.ref.url
        let s = b.summary
        let meta = SessionMetadata(title: s.title, projectName: s.label, startTime: nil,
                                   gitBranch: s.gitBranch, messageCount: s.messageCount,
                                   contextTokens: s.contextTokens, lastModified: s.lastModified ?? Date())
        store.noteLoadedSession(agent: agent, sessionId: b.ref.sessionId, meta: meta)
        store.selectSession(agent: agent, sessionId: b.ref.sessionId)
    }

    @MainActor
    private func togglePinForBrowsed(agent: AgentKind, _ b: BrowsedSession) {
        guard let store = chatCardWindowController?.agentSessionStore else { return }
        let s = b.summary
        // 钉住(非取消)→ 注入元数据 + 记 URL → 该会话在内建 picker **立即可点**(否则只钉不载 m==nil → isUnavailable 灰显点不了,#2)。
        if !pinnedSessionStore.isPinned(agent: agent, sessionId: b.ref.sessionId) {
            loadedSessionURLs[agent, default: [:]][b.ref.sessionId] = b.ref.url
            store.noteLoadedSession(agent: agent, sessionId: b.ref.sessionId,
                meta: SessionMetadata(title: s.title, projectName: s.label, startTime: nil,
                                      gitBranch: s.gitBranch, messageCount: s.messageCount,
                                      contextTokens: s.contextTokens, lastModified: s.lastModified ?? Date()))
        }
        let ref = PinnedSessionRef(agent: agent, sessionId: b.ref.sessionId, filePath: b.ref.url.path,
                                   title: s.title, gitBranch: s.gitBranch, pinnedAt: Date())
        store.togglePin(agent: agent, sessionId: b.ref.sessionId, ref: ref)
    }

    @MainActor
    private func closeBrowseSheet() {
        sessionBrowsePanel?.orderOut(nil)
        sessionBrowsePanel = nil
        browseSheetPinned = false   // 关了就复位置顶态(下次开默认不置顶)
    }
}
