import AgentMode
import AppKit
import Shell

// ACP-2 permission UI 接线:把 ACPAgentEngine 的 session/request_permission 回调接到
// 现有 PermissionCard 管线(复用 AgentSensing 的 pet 旁侧卡 + PendingAction)。
// agent 请求工具权限 → 弹卡 → 用户 allow/deny → outcome 回写 ACP client → agent 继续。
// 同处接线:thought(思考中状态,ACP-2)+ usage(上下文占用条,ACP-3)engine 回调 → ChatCardState。
// 非 ACP engine(Claude/Codex 本地子进程不经 ACP)→ wireACPPermissionHandler no-op(cast 失败)。

extension MinimalAppDelegate {

    /// engine 切换后调:给 ACPAgentEngine 注入 onPermissionRequest(若当前 engine 是 ACP)。
    /// 非 ACP engine → no-op。在 `applySelectedAgentEngine` 后调(确保 `currentEngine` 已设)。
    /// 时机:engine 创建后、首次 run 前 → ensureConnected 时透传给 ACPClient。
    @MainActor
    func wireACPPermissionHandler() {
        // engine 已换实例 → 会话 UI 态随旧 engine 失效(P2;新 engine 待重新能力探测)
        resetACPSessionUI()
        guard let acp = agentModeRouter?.currentEngine as? ACPAgentEngine else { return }
        wireACPEngineCallbacks(acp, kind: type(of: acp).kind)
    }

    /// 给任一 ACP engine 实例接回调(P5 抽出:当前 engine 与 @mention 池引擎同一份逻辑,
    /// 池工厂懒建时也走这里)。`kind` 显式传 —— 池引擎 ≠ UD 选中引擎,会话指针桶必须按
    /// **实际跑的** engine 存,否则 @codex 的 sessionId 会错写进 opencode 桶。
    @MainActor
    func wireACPEngineCallbacks(_ acp: ACPAgentEngine, kind: AgentEngineKind) {
        // onPermissionRequest 是 @Sendable async 闭包(ACPClient actor 跨边界调)。
        // 直接 `await self?.presentACPPermission`(presentACPPermission 是 @MainActor async,
        // await 跨 actor hop 回主 actor)。@Sendable 闭包 [weak self] 在 Swift 5 是 warning
        // (Swift 6 需 self Sendable 或经 holder)—— 当前可接受(appDelegate 是单例 @MainActor)。
        acp.onPermissionRequest = { [weak self] req in
            await self?.presentACPPermission(req) ?? req.safeDefaultOutcome
        }
        // thought 展示(ACP-2 thought UI):agent_thought_chunk → pet「思考中」状态。
        // @Sendable 同步闭包 → `Task { @MainActor }` hop 回主 actor 设 `cardState.isThinking`。
        acp.onThought = { _ in
            Task { @MainActor [weak self] in
                self?.chatCardWindowController?.cardState.isThinking = true
            }
        }
        // usage 展示(ACP-3):usage_update → composer 上方上下文占用条。
        // 同 onThought:@Sendable 同步闭包 → `Task { @MainActor }` hop 回主 actor 设 cardState。
        acp.onUsage = { [weak self] usage in
            Task { @MainActor [weak self] in
                guard let state = self?.chatCardWindowController?.cardState else { return }
                Self.applyContextUsage(usage, to: state)
            }
        }
        // 会话指针持久化(P2):首建/恢复/新建 session → ACPSessionStore 落盘(开卡恢复用)。
        // P5:桶 kind 按该实例实际 kind(池引擎与 UD 选中引擎可能不同)。
        acp.onSessionIdChanged = { [weak self] sid in
            Task { @MainActor [weak self] in
                self?.persistACPSessionPointer(sid, engineKind: kind.rawValue)
            }
        }
    }

    // MARK: - 用量映射(可单测)

    /// `ACPUsage` → `ChatCardState` 上下文占用字段(usage_update → composer 上方占用条)。
    /// size = nil(fallback 只报 used)不覆盖此前已知窗口 —— 精确值一旦到手就留住。
    /// prompt 明细同理(nil 不清,只在有新明细时更新 tooltip)。
    @MainActor
    static func applyContextUsage(_ usage: ACPUsage, to state: ChatCardState) {
        state.contextUsed = usage.used
        if let size = usage.size { state.contextSize = size }
        state.contextCost = usage.cost.map(formatUsageCost)
        if let prompt = usage.prompt { state.contextDetail = formatUsageDetail(prompt) }
    }

    /// token 明细格式化(tooltip):"in 2.5k · cache 52.1k · out 0.3k · total 54.9k"(有值才列)。
    nonisolated static func formatUsageDetail(_ usage: ACPPromptUsage) -> String {
        var parts = ["in \(compactTokenCount(usage.inputTokens))"]
        if usage.cachedReadTokens > 0 { parts.append("cache \(compactTokenCount(usage.cachedReadTokens))") }
        if let out = usage.outputTokens { parts.append("out \(compactTokenCount(out))") }
        if let total = usage.totalTokens { parts.append("total \(compactTokenCount(total))") }
        return parts.joined(separator: " · ")
    }

    /// 紧凑 token 计数:≥1000 → "52.1k",否则原数。
    nonisolated static func compactTokenCount(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n)
    }

    /// cost 展示格式化:USD → "$0.0123";其它币种原样前缀("CNY 0.0123")。
    nonisolated static func formatUsageCost(_ cost: ACPUsage.Cost) -> String {
        let amount = String(format: "%.4f", cost.amount)
        return cost.currency == "USD" ? "$\(amount)" : "\(cost.currency) \(amount)"
    }

    /// 弹 pet 旁权限卡等用户处置 ACP 权限请求,返回 outcome。
    /// `.standard` 型(allow/deny 按钮):allow → `allow_*` optionId;deny → `reject_*` optionId 或 cancelled。
    /// store 缺席 → safeDefaultOutcome(不卡 turn)。
    ///
    /// agent 死(transport EOF)时 `ACPClient.handleEOF` 不知此 cont → onPermissionRequest 不会因
    /// agent 死而 resume。靠 **600s timeout 兜底**(超时 → safeDefault),不永挂(边缘:agent 死在等权限)。
    /// once-guard 保证 cont 只 resume 一次(用户先答则 timeout no-op)。
    @MainActor
    func presentACPPermission(_ req: ACPPermissionRequest) async -> ACPPermissionOutcome {
        guard let store = chatCardWindowController?.agentSessionStore else {
            return req.safeDefaultOutcome
        }
        ensurePermissionCardController(store: store)
        let reqId = "acp-\(UUID().uuidString)"
        let model = Self.permissionCardModel(from: req)

        return await withCheckedContinuation { (cont: CheckedContinuation<ACPPermissionOutcome, Never>) in
            // once-guard:防 double resume(onAllow 后 onSuperseded / timeout 等并发触发 → CheckedContinuation
            // double resume 会 crash)。resolve 是 @MainActor 闭包,串行调 → flag 无竞态。
            var resolved = false
            // 答完(任一路径)→ resume continuation + 清高亮 + 复位 pet 模式 + 出队。
            let resolve: @MainActor (ACPPermissionOutcome) -> Void = { [weak self] outcome in
                guard !resolved else { return }
                resolved = true
                cont.resume(returning: outcome)
                self?.chatCardWindowController?.agentSessionStore.highlightedItemId = nil
                self?.permissionCardController?.returnToPet()
                self?.chatCardWindowController?.agentSessionStore.removePending(id: reqId)
            }
            // timeout:agent 死(transport EOF)或用户久不答 → safeDefault(不永挂)。
            // 600s 匹配现有 permissionCard 超时(+PermissionWiring);once-guard 保证 cont 只 resume 一次。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                resolve(req.safeDefaultOutcome)
            }
            let action = PendingAction(
                id: reqId,
                model: model,
                onAllow: { resolve(Self.outcomeForAllow(req: req)) },
                onDeny: { resolve(Self.outcomeForDeny(req: req)) },
                onSelectOption: { idx in
                    resolve(req.options.indices.contains(idx)
                            ? .selected(optionId: req.options[idx].optionId)
                            : req.safeDefaultOutcome)
                },
                onSubmit: { _ in resolve(req.safeDefaultOutcome) },
                onSuperseded: { resolve(req.safeDefaultOutcome) },
                onLocate: nil   // ACP 无 sessionId 定位(留后)
            )
            store.addPending(action)
        }
    }

    // MARK: - 纯映射(可单测)

    /// `ACPPermissionRequest` → `PermissionCardModel`(`.standard`:allow/deny 按钮)。
    /// 简化:统一 standard 型(`allow_once` / `reject_once` 映射,直觉可用)。
    /// 高级(`allow_always` / `reject_always`)留后(需 `PermissionCardModel` 扩型或专用 UI)。
    nonisolated static func permissionCardModel(from req: ACPPermissionRequest) -> PermissionCardModel {
        PermissionCardModel(
            kind: .standard,
            title: req.title ?? req.kind ?? "工具权限",
            detail: nil,
            project: nil
        )
    }

    /// allow → `allow_*` optionId;无 allow option → safeDefault(不卡 turn)。
    nonisolated static func outcomeForAllow(req: ACPPermissionRequest) -> ACPPermissionOutcome {
        if let id = req.options.first(where: { $0.kind.hasPrefix("allow") })?.optionId {
            return .selected(optionId: id)
        }
        return req.safeDefaultOutcome
    }

    /// deny → `reject_*` optionId;无 reject option → cancelled。
    nonisolated static func outcomeForDeny(req: ACPPermissionRequest) -> ACPPermissionOutcome {
        if let id = req.options.first(where: { $0.kind.hasPrefix("reject") })?.optionId {
            return .selected(optionId: id)
        }
        return .cancelled
    }
}
