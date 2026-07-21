import Foundation
import AgentMode
import Shell

// ACP-4 会话管理(P2)接线:当前会话指针持久化 + 开卡恢复 + 会话列表/切换/新建。
//
// 数据流:
// - engine `onSessionIdChanged`(首建/恢复/新建)→ `ACPSessionStore` 持久化指针
//   (key = engineKind|cwd;transcript 权威在 agent 侧,本地只存指针)。
// - 开卡 `acpSessionRestoreHook`:能力探测(loadSession + list → UI 开关)→ 时间线空且
//   有持久指针 → `session/load` 回放重建消息列表;指针失效(agent 侧已清)→ 清除回退。
// - 会话选择器回调:select(loadSession 回放)/ new(newSession + 清时间线)/ refresh(session/list)。
// 非 ACP engine(Claude/Codex 本地子进程)→ 全部 no-op(cast 失败)。

extension MinimalAppDelegate {

    // MARK: - 一次性接线(setupChatCardAndHotkeys 调)

    /// 把会话选择器回调 + 开卡恢复 hook 接到卡片;并触发 store 读盘。
    @MainActor
    func wireACPSessionUI(to cardCtrl: ChatCardWindowController) {
        let state = cardCtrl.cardState
        Task { await acpSessionStore.load() }
        cardCtrl.acpSessionRestoreHook = { [weak self] in
            await self?.restoreACPSessionIfNeeded()
        }
        state.onSelectACPSession = { [weak self] sid in
            Task { @MainActor [weak self] in await self?.selectACPSession(sid) }
        }
        state.onRequestNewACPSession = { [weak self] in
            Task { @MainActor [weak self] in await self?.newACPSession() }
        }
        state.onRefreshACPSessions = { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshACPSessionList() }
        }
    }

    /// engine 切换后重置会话 UI 态(新 engine 能力未探测,列表/开关随旧 engine 失效)。
    /// 在 `wireACPPermissionHandler` 里随 onUsage 同点调。
    @MainActor
    func resetACPSessionUI() {
        guard let state = chatCardWindowController?.cardState else { return }
        state.acpSessionUIEnabled = false
        state.acpSessions = []
        state.isLoadingACPSessions = false
    }

    // MARK: - 指针持久化(onSessionIdChanged → store)

    /// engine 报新 sessionId → 持久化当前会话指针(@MainActor hop 后 async 落盘)。
    @MainActor
    func persistACPSessionPointer(_ sid: String) {
        let key = Self.acpSessionPointerKey(defaults: userDefaults)
        Task { await acpSessionStore.set(sessionId: sid, forKey: key) }
    }

    // MARK: - 开卡恢复

    /// 能力探测 → UI 开关;时间线空且有持久指针 → loadSession 回放重建。
    /// 每次开卡都跑(ChatCardWindowController 弹出后异步):冷启动首调 ~2-3s,后续复用连接。
    @MainActor
    func restoreACPSessionIfNeeded() async {
        guard let engine = agentModeRouter?.currentEngine as? ACPAgentEngine,
              let state = chatCardWindowController?.cardState else { return }
        guard let caps = try? await engine.ensureReady() else { return }   // agent 不可用 → 会话 UI 保持关,不影响聊天
        state.acpSessionUIEnabled = caps.loadSession && caps.sessionCapabilities.contains(.list)
        guard caps.loadSession else { return }

        let key = Self.acpSessionPointerKey(defaults: userDefaults)
        if state.messages.isEmpty,
           let sid = await acpSessionStore.sessionId(forKey: key),
           sid != engine.currentSessionId {
            state.isLoadingACPSessions = true
            do {
                let turns = try await engine.loadSession(sid)
                if !turns.isEmpty { state.load(history: Self.rows(from: turns)) }
            } catch {
                // 指针失效(agent 侧已清 session)→ 清除回退,下次 run 开新会话
                await acpSessionStore.remove(forKey: key)
            }
            state.isLoadingACPSessions = false
        }
        await refreshACPSessionList()
    }

    // MARK: - 会话选择器动作

    /// 刷新会话列表(session/list → state.acpSessions;失败保持旧列表)。
    @MainActor
    func refreshACPSessionList() async {
        guard let engine = agentModeRouter?.currentEngine as? ACPAgentEngine,
              let state = chatCardWindowController?.cardState,
              state.acpSessionUIEnabled else { return }
        state.isLoadingACPSessions = true
        if let infos = try? await engine.listSessions() {
            let current = engine.currentSessionId
            state.acpSessions = infos.map { Self.sessionItem(from: $0, currentId: current) }
        }
        state.isLoadingACPSessions = false
    }

    /// 切换会话:loadSession 回放重建时间线(指针持久化由 onSessionIdChanged 顺带完成)。
    @MainActor
    func selectACPSession(_ sid: String) async {
        guard let engine = agentModeRouter?.currentEngine as? ACPAgentEngine,
              let state = chatCardWindowController?.cardState,
              sid != engine.currentSessionId else { return }
        state.isLoadingACPSessions = true
        if let turns = try? await engine.loadSession(sid) {
            state.load(history: Self.rows(from: turns))
        }
        state.isLoadingACPSessions = false
        await refreshACPSessionList()
    }

    /// 新会话:engine 立即 session/new + 清时间线与旧用量(新会话上下文从零计)。
    @MainActor
    func newACPSession() async {
        guard let engine = agentModeRouter?.currentEngine as? ACPAgentEngine,
              let state = chatCardWindowController?.cardState else { return }
        state.isLoadingACPSessions = true
        _ = try? await engine.newSession()
        state.load(history: [])
        state.contextUsed = nil
        state.contextSize = nil
        state.contextCost = nil
        state.isLoadingACPSessions = false
        await refreshACPSessionList()
    }

    // MARK: - 纯映射(可单测)

    /// 持久化指针 key:engineKind|cwd(三 ACP engine × 项目 → 各自指针,P3 起按选中 entry)。
    nonisolated static func acpSessionPointerKey(defaults: UserDefaults) -> String {
        ACPSessionStore.key(
            engineKind: AgentEngineRegistry.resolve(from: defaults).id,
            cwd: currentACPProjectRoot(defaults: defaults).path
        )
    }

    /// 回放消息 → 卡片消息行。
    nonisolated static func rows(from turns: [ACPReplayedTurn]) -> [ChatCardRow] {
        turns.map { ChatCardRow(role: $0.role == .user ? .user : .assistant, text: $0.text) }
    }

    /// session/list 项 → 卡片会话列表项(标题兜底 sessionId 前缀;ISO 8601 解析容错)。
    nonisolated static func sessionItem(from info: ACPSessionInfo, currentId: String?) -> ACPSessionItem {
        let title: String
        if let t = info.title, !t.isEmpty {
            title = t
        } else {
            title = String(info.sessionId.prefix(12))
        }
        return ACPSessionItem(
            id: info.sessionId, title: title,
            updatedAt: parseACPDate(info.updatedAt),
            isCurrent: info.sessionId == currentId
        )
    }

    /// ISO 8601 解析(先带毫秒,退回不带;都失败 → nil 不崩)。
    nonisolated static func parseACPDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}
