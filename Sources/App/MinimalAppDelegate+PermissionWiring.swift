import AgentSensing
import AppKit
import Shell
import os

extension MinimalAppDelegate {

    static let permissionLog = Logger(subsystem: "io.openpetagent", category: "AgentSensing.permission")

    /// applicationDidFinishLaunching 末段调。启用时:起本地 hook server → 就绪后把 OpenPetAgent
    /// 自己的 type:http hook 装进 settings.json(端口没变就不重写)→ 接 onPermission 弹卡。
    /// 默认**关**(它会改 settings.json + 开端口 + 与其它 hook 工具共存);用户在菜单主动开。
    @MainActor
    func setupPermissionAnswering() {
        debugInjectPermissionsIfRequested()   // env-gated 合成待答,验 pet 旁权限侧卡
        let enabled = (userDefaults.object(forKey: Self.permissionAnsweringEnabledKey) as? Bool) ?? false
        guard enabled else { return }
        startPermissionHookServer()
    }

    /// 调试钩子(env `PETAGENT_DEBUG_PERMISSION`):启动后注入①一个合成 Claude 会话(含 running 的 Bash/Edit 工具行,
    /// 给「定位会话」一个落点)+ ②几条合成待答 → pet 旁权限侧卡**带尖角**堆叠弹出可录。p1 接 `onLocate` 验
    /// 「定位会话 → 尖角重锚到 Bash 消息行(toggle 切回 pet)」。合成请求**不注册 responder**(liveness 不 reap),
    /// 点允许/拒绝/选项即出队。用法见 dev-guide。
    @MainActor
    func debugInjectPermissionsIfRequested() {
        guard ProcessInfo.processInfo.environment["PETAGENT_DEBUG_PERMISSION"] != nil else { return }
        // **`Task { @MainActor in }`** 而非 `DispatchQueue.main.asyncAfter`:让 synth 返回的待答闭包**继承 MainActor 隔离**
        // (可直接调 @MainActor 的 `store.removePending`);Sendable 的 asyncAfter 闭包不继承 → 编译报 actor 隔离错。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let store = self.chatCardWindowController?.agentSessionStore else { return }
            self.ensurePermissionCardController(store: store)
            let dbgSid = "dbg-perm-session"
            // ① 合成会话:含 running 的 Bash/Edit 工具行 → 「定位会话」能找到 Bash 行重锚尖角。
            let base = Date()
            func ev(_ k: AgentEventKind, _ dt: Double, _ detail: String? = nil) -> AgentEvent {
                AgentEvent(agent: .claudeCode, sessionId: dbgSid, cwd: "/Users/me/projects/sample",
                           kind: k, timestamp: base.addingTimeInterval(dt), detail: detail)
            }
            store.appendLive(ev(.userPrompt(text: "跑一下测试然后推送"), 0))
            store.appendLive(ev(.assistantText(text: "好的,我先跑测试再推送。"), 0.01))
            store.appendLive(ev(.toolUse(name: "Bash", summary: "npm test && git push"), 0.02, "npm test && git push origin main"))
            store.appendLive(ev(.toolUse(name: "Edit", summary: "Counter.swift"), 0.03, "- var count = 0\n+ var count = 1"))
            store.updateMetadata([dbgSid: SessionMetadata(title: "调试权限定位", projectName: "pet-agent",
                startTime: base.addingTimeInterval(-60), gitBranch: "feature/x", messageCount: 4, lastModified: base)], agent: .claudeCode)
            // 合成权限 prompt(给 onLocate 用,sessionId 对上合成会话)。
            func prompt(_ tool: String, _ summary: String, _ kind: PermissionPromptKind) -> PermissionPrompt {
                PermissionPrompt(sessionId: dbgSid, cwd: "/Users/me/projects/sample", toolName: tool,
                                 summary: summary, suggestions: [], kind: kind)
            }
            // 答完复位:清高亮 + 切回 pet + 出队(对齐真实 resolve 路径:经 [weak self] 惰性取 store,不强捕获 → 不成引用环)。
            let resolve: (String) -> Void = { [weak self] id in
                guard let self, let store = self.chatCardWindowController?.agentSessionStore else { return }
                store.highlightedItemId = nil
                self.permissionCardController?.returnToPet()
                store.removePending(id: id)
            }
            // closure(非 func):在 @MainActor Task 里形成 → 继承 MainActor 隔离 → 内层待答闭包可直接调 store。
            let synth: (String, PermissionCardModel, (() -> Void)?) -> PendingAction = { id, model, locate in
                PendingAction(id: id, model: model,
                              onAllow: { resolve(id) },
                              onDeny: { resolve(id) },
                              onSelectOption: { _ in resolve(id) },
                              onSubmit: { _ in resolve(id) },
                              onSuperseded: {},
                              onLocate: locate)
            }
            store.addPending(synth("p1", PermissionCardModel(kind: .standard, title: "Bash",
                detail: "npm test && git push origin main", project: "pet-agent"),
                { [weak self] in self?.locatePermissionSession(prompt: prompt("Bash", "npm test && git push", .standard)) }))
            store.addPending(synth("p2", PermissionCardModel(kind: .plan, title: "计划审批",
                detail: "Claude 想结束计划模式开始执行", project: "pet-agent"), nil))
            store.addPending(synth("p3", PermissionCardModel(kind: .question, title: "用哪个方案?",
                detail: "检测到两种实现路径,你倾向哪个?", project: "pet-agent",
                options: ["方案 A:原地修根因", "方案 B:换 AppKit 地基", "方案 C:先调研开源"]), nil))
            // `PETAGENT_DEBUG_PERMISSION=locate`:注入后 +4s **自动**定位 p1 → 尖角重锚到 Bash 行
            //(免脆弱坐标点击验 T4 重锚)。`=1` 仅停在 pet 旁堆叠态(验 T2/T3)。
            if ProcessInfo.processInfo.environment["PETAGENT_DEBUG_PERMISSION"] == "locate" {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.locatePermissionSession(prompt: prompt("Bash", "npm test && git push", .standard))
            }
        }
    }

    /// 起 server + 装 hook。toggle 开 / 启动启用时调。
    @MainActor
    func startPermissionHookServer() {
        guard permissionHookServer == nil else { return }   // 已在跑
        let server = PermissionHookServer(
            onPermission: { [weak self] prompt, responder in
                let weakSelf = self
                Task { @MainActor in
                    weakSelf?.presentPendingAction(prompt: prompt, responder: responder)
                }
            }
        )
        permissionHookServer = server
        server.start { result in
            switch result {
            case .success(let port):
                Task { @MainActor in
                    let installer = HookInstaller()
                    if installer.installedPort() != port {   // 端口变了才重写,避免 churn
                        do { try installer.install(port: port) }
                        catch { Self.permissionLog.error("装 hook 失败: \(error.localizedDescription, privacy: .public)") }
                    }
                    Self.permissionLog.notice("权限应答已启用 @\(port, privacy: .public)")
                }
            case .failure(let err):
                let msg = err.localizedDescription
                Task { @MainActor in Self.permissionLog.error("hook server 起不来: \(msg, privacy: .public)") }
            }
        }
    }

    /// toggle 关 / 退出时调:停 server + 卸我们自己的 hook(不碰别人的条目)。
    @MainActor
    func stopPermissionHookServer(uninstallHook: Bool) {
        permissionHookServer?.stop()
        permissionHookServer = nil
        // 收口待答:清队列(各 responder 弃权)+ 停 liveness + 收起侧卡。
        permissionLivenessTimer?.invalidate(); permissionLivenessTimer = nil
        permissionResponders.removeAll()
        chatCardWindowController?.agentSessionStore.clearAllPending()
        permissionCardController?.hide()
        if uninstallHook {
            do { try HookInstaller().uninstall() }
            catch { Self.permissionLog.error("卸 hook 失败: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// 菜单 toggle:开 → 起 server + 装 hook;关 → 停 server + 卸 hook。持久化。
    @MainActor
    func setPermissionAnswering(enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.permissionAnsweringEnabledKey)
        if enabled { startPermissionHookServer() }
        else { stopPermissionHookServer(uninstallHook: true) }
    }

    // MARK: - 待答队列(pet 旁权限侧卡)+ 回写 + liveness

    /// 权限/问题来了 → **入队**(多并发并存,不顶替)+ 在 pet 旁弹权限侧卡(陪伴卡片无需开着,2026-06-16)。
    /// 用户在侧卡 `PendingActionView` 点允许/拒绝/选项/自定义答案 → 回写 responder + 出队。
    @MainActor
    func presentPendingAction(prompt: PermissionPrompt, responder: any HookResponder) {
        guard let store = chatCardWindowController?.agentSessionStore else { responder.respond(.abstain); return }
        ensurePermissionCardController(store: store)
        let reqId = UUID().uuidString
        let model = Self.permissionCardModel(from: prompt)
        let firstOptions: [String]
        if case .question(let qs) = prompt.kind { firstOptions = qs.first?.options.map(\.label) ?? [] }
        else { firstOptions = [] }

        // 答完(任一路径)→ 移除 responder 记录 + 清行高亮 + 复位 pet 模式 + 出队(出队触发 onPendingQueueChanged → 重排/收起侧卡)。
        let resolve: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.permissionResponders[reqId] = nil
            self.chatCardWindowController?.agentSessionStore.highlightedItemId = nil
            self.permissionCardController?.returnToPet()
            self.chatCardWindowController?.agentSessionStore.removePending(id: reqId)
        }
        let action = PendingAction(
            id: reqId,
            model: model,
            onAllow: { responder.respond(.allow); resolve() },
            onDeny: { responder.respond(.deny); resolve() },
            onSelectOption: { idx in
                let label = firstOptions.indices.contains(idx) ? firstOptions[idx] : ""
                responder.respond(.allow, updatedInputJSON: prompt.answeredInputJSON(answer: label))
                resolve()
            },
            onSubmit: { text in
                responder.respond(.allow, updatedInputJSON: prompt.answeredInputJSON(answer: text))
                resolve()
            },
            // 清队收口(toggle 关 / 退出)→ 弃权兜底(once-guard 让已决策的 no-op)。
            onSuperseded: { responder.respond(.abstain) },
            // 定位会话:打开触发它的会话 + 尖角重锚到对应消息行(toggle 再点回 pet)。仅有 sessionId 才给。
            onLocate: prompt.sessionId == nil ? nil : { [weak self] in self?.locatePermissionSession(prompt: prompt) }
        )
        permissionResponders[reqId] = responder
        store.addPending(action)   // → onPendingQueueChanged → syncPermissionCard 弹/重排
    }

    /// 懒建 pet 旁权限侧卡控制器 + 接队列变化 → 同步侧卡 + 起 liveness 轮询。
    @MainActor
    private func ensurePermissionCardController(store: AgentSessionStore) {
        guard permissionCardController == nil else { return }
        let ctrl = PermissionCardWindowController(store: store)
        // row 模式贴陪伴卡片旁 + 尖角对准消息行 → 需要陪伴卡片当前窗口 frame。
        ctrl.companionCardFrameProvider = { [weak self] in self?.chatCardWindowController?.window?.frame }
        permissionCardController = ctrl
        store.onPendingQueueChanged = { [weak self] in
            DispatchQueue.main.async { self?.syncPermissionCard() }
        }
        startPermissionLiveness()
    }

    /// 据队列在 pet 旁显示/重排/收起权限侧卡。
    @MainActor
    func syncPermissionCard() {
        guard let ctrl = permissionCardController else { return }
        let pet = shellController?.windowSet.petWindow
        let petRect = pet?.frame ?? .zero
        let screen = pet?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        ctrl.sync(petRect: petRect, screen: screen)
    }

    /// 点权限卡「定位会话」(toggle):已 row 锚 → 切回 pet 旁 + 清高亮;否则 → 选中触发会话 + 开陪伴卡片到
    /// Claude Code tab + 高亮触发请求的消息行 + 把尖角重锚到该行(类侧卡锚源行)。
    @MainActor
    func locatePermissionSession(prompt: PermissionPrompt) {
        guard let store = chatCardWindowController?.agentSessionStore,
              let ctrl = permissionCardController else { return }
        // toggle:已在 row 模式 → 切回 pet 旁 + 清高亮。
        if ctrl.isRowAnchored {
            store.highlightedItemId = nil
            ctrl.returnToPet()
            return
        }
        // 1) 选中触发它的会话(Claude transcript 的 canonicalSessionId == session_id,直接匹配)。
        if let sid = prompt.sessionId, store.sessions(for: .claudeCode).contains(where: { $0.id == sid }) {
            store.selectSession(agent: .claudeCode, sessionId: sid)
        }
        // 2) 打开陪伴卡片到 Claude Code tab。
        chatCardWindowController?.presentOnTab(.claudeCode)
        // 3) 找触发请求的消息行:权限在工具执行**前**抛 → tool_use 行已写入,匹配「最后一条 running 且同名 .tool」;
        //    计划/问题(无对应 tool 行)退到「最后一条 awaiting」;再退到「最后一条同名 tool」。没匹配 → 只开会话不重锚。
        guard let row = Self.matchingPermissionRow(in: store.items(for: .claudeCode), toolName: prompt.toolName) else { return }
        store.highlightedItemId = row.id
        store.highlightedRegion = .primary   // 权限源行 = 工具行(主内容)
        // 4) row 锚 → 尖角对准该行。midY 写链跨多个主队列 hop(冷启动慢)→ controller `anchorToRow` 内**有限重试**
        //    轮询到 midY 就绪,**不再用固定延迟**(踩空会静默回退 pet)。
        permissionCardController?.anchorToRow()
    }

    /// 触发请求的消息行匹配(纯函数,可单测)。**turn 模型**:扫各轮 steps 找含 running 同名工具的轮 → 高亮整轮;
    /// 退到 awaiting 轮 → 含同名工具的轮。
    nonisolated static func matchingPermissionRow(in items: [ConversationItem], toolName: String) -> ConversationItem? {
        func steps(_ it: ConversationItem) -> [TurnStep]? {
            if case .assistantTurn(let a) = it.kind { return a.steps }
            return nil
        }
        func hasTool(_ st: [TurnStep], running: Bool) -> Bool {
            st.contains {
                if case .tool(_, let n, _, let s, _, _, _) = $0, n == toolName { return running ? s == .running : true }
                return false
            }
        }
        for it in items.reversed() where steps(it).map({ hasTool($0, running: true) }) == true { return it }
        for it in items.reversed() { if case .awaiting = it.kind { return it } }
        for it in items.reversed() where steps(it).map({ hasTool($0, running: false) }) == true { return it }
        return nil
    }

    /// liveness 轮询(1s):连接死(超时/Claude 退出)→ `isAlive=false` → 把死请求移出队列(死卡消失,不杵着可点无效)。
    @MainActor
    private func startPermissionLiveness() {
        permissionLivenessTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reapDeadPermissions() }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionLivenessTimer = t
    }

    @MainActor
    func reapDeadPermissions() {
        guard let store = chatCardWindowController?.agentSessionStore else { return }
        let dead = permissionResponders.filter { !$0.value.isAlive }.map(\.key)
        for id in dead {
            permissionResponders[id] = nil
            store.removePending(id: id)
        }
    }

    /// `PermissionPrompt`(AgentSensing)→ `PermissionCardModel`(Shell)。
    static func permissionCardModel(from prompt: PermissionPrompt) -> PermissionCardModel {
        switch prompt.kind {
        case .plan:
            return PermissionCardModel(
                kind: .plan, title: "计划审批",
                detail: "Claude 想结束计划模式开始执行", project: prompt.projectName
            )
        case .question(let qs):
            let q = qs.first
            return PermissionCardModel(
                kind: .question, title: q?.header ?? "有个问题",
                detail: q?.question, project: prompt.projectName,
                options: q?.options.map(\.label) ?? []
            )
        case .standard:
            return PermissionCardModel(
                kind: .standard, title: prompt.toolName,
                detail: prompt.summary, project: prompt.projectName
            )
        }
    }
}
