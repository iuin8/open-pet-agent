import Foundation
import AgentMode
import Shell

// MARK: - Tool engine routing

extension MinimalAppDelegate {
    /// N2.4 — 按 UserDefaults `tool.engine.kind` 把对应 engine 装到 router。
    ///
    /// 不再写死 `switch kind`:经 `AgentEngineRegistry.resolve(from:)` 选中 entry
    /// (UD 没设 / 值不识别 → fallback `all[0]` = claudeCode,5417612 起的默认行为)。
    /// P3 起三个引擎统一 ACP:`makeACPEngine(kind:)` 按项目 cwd 组装适配器子进程。
    /// P5:@mention 池已有同 kind engine → 直接收养为当前(单实例/单会话,不双开子进程)。
    ///
    /// 两个调用方:
    /// - `didFinishLaunching` 启动时初始化 router
    /// - `onSaveAgentModeEnabled` callback 切 toggle 时即时刷新
    /// 两条路径必须用同一份选 engine 逻辑,避免一处改了另一处遗漏。
    static func applySelectedAgentEngine(
        to router: AgentModeRouter?,
        defaults: UserDefaults
    ) {
        guard let router else { return }
        let entry = AgentEngineRegistry.resolve(from: defaults)
        // P5:@mention 池里已有同 kind engine → 收养为当前(池在 `clearPooledEngines`
        // 前一直持有,直接 setEngine 避免同 kind 双开子进程 / 双会话)。
        if let kind = AgentEngineKind(rawValue: entry.id),
           let pooled = router.existingPooledEngine(for: kind) {
            router.setEngine(pooled)
            return
        }
        // 三个 ACP engine(P3 起统一:opencode / claude-agent-acp / codex-acp):per-kind 构建。
        if let kind = AgentEngineKind(rawValue: entry.id),
           let engine = makeACPEngine(kind: kind, defaults: defaults) {
            router.setEngine(engine)
            return
        }
        // 其他 engine / fallback:registry makeEngine
        router.setEngine(entry.makeEngine())
    }

    /// P3 三引擎统一 ACP 的 per-kind 构建(P5 抽出:`applySelectedAgentEngine` 与
    /// @mention 池 `engineFactory` 共用同一份组装逻辑,行为不漂移)。
    ///
    /// 用 ProjectStore.current() 选中的项目做 cwd,长驻适配器子进程(P1a 多项目数据地基;
    /// 详见 docs/project-config-architecture-design.md)。opencode 额外注入 OPENCODE_CONFIG
    /// + 项目 MCP projection;claude/codex 适配器读各自生态配置(.mcp.json / ~/.codex),
    /// ACP mcpServers 传空。非 ACP kind → nil(调用方走 registry makeEngine)。
    static func makeACPEngine(kind: AgentEngineKind, defaults: UserDefaults) -> (any AgentEngine)? {
        guard let acpCommand = acpCommand(for: kind.rawValue) else { return nil }
        ProjectStore.ensureDefaultProjectRegistered(defaults: defaults)
        let project = ProjectStore.current(defaults: defaults)
        let projectRoot = currentACPProjectRoot(defaults: defaults)
        var env = CLIProcessEnvironment.augmented()
        let mcpServersProvider: @Sendable (ACPAgentCapabilities) -> [ACPJSON]
        if kind == .openCode {
            let opencodeConfigPath = ProjectConfig.opencodeConfig(for: project).path
            env = env.merging(["OPENCODE_CONFIG": opencodeConfigPath]) { _, new in new }
            mcpServersProvider = { caps in
                do {
                    let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
                    // ACP v1 的 http/sse 是能力门控:agent 未声明的 transport 不下发。
                    return ACPMCPServerProjection.supported(servers, capabilities: caps.mcpCapabilities)
                } catch {
                    fputs("[ProjectConfig] opencode MCP projection failed: \(error)\n", stderr)
                    return []
                }
            }
        } else {
            mcpServersProvider = { _ in [] }
        }
        let transportFactory: @Sendable () -> any ACPTransport = {
            ACPStdioTransport(
                command: acpCommand,
                processEnvironment: env,
                currentDirectoryURL: projectRoot
            )
        }
        switch kind {
        case .claudeCode:
            return ClaudeACPAgentEngine(
                command: acpCommand, cwd: projectRoot,
                mcpServersProvider: mcpServersProvider, transportFactory: transportFactory
            )
        case .codex:
            return CodexACPAgentEngine(
                command: acpCommand, cwd: projectRoot,
                mcpServersProvider: mcpServersProvider, transportFactory: transportFactory
            )
        case .openCode:
            return ACPAgentEngine(
                command: acpCommand, cwd: projectRoot,
                mcpServersProvider: mcpServersProvider, transportFactory: transportFactory
            )
        }
    }

    /// engine id → 短标签(displayName 首词:"Claude Code"→"Claude","opencode (ACP)"→"opencode")。
    /// 未知 id → 原样返回(不吞信息)。P5 @mention 署名 chip / ACP 回放行署名用。
    nonisolated static func engineShortLabel(forId engineId: String) -> String {
        guard let entry = AgentEngineRegistry.lookup(id: engineId) else { return engineId }
        return entry.displayName.split(separator: " ").first.map(String.init) ?? entry.displayName
    }

    /// P5 follow-up:组 @mention 补全候选(开卡/切回复来源时刷新)。
    /// 工具层开启时:`AgentMention.candidates`(与解析同一份表)× registry 展示数据 ×
    /// CLI 可用性(适配器未装 → 置灰「未安装」,仍可选,发送后走友好不可用文案)。
    /// 关闭 → (false, []),composer 不弹补全。
    @MainActor
    func refreshMentionConfiguration() async -> (enabled: Bool, options: [MentionOption]) {
        guard userDefaults.bool(forKey: Self.agentModeEnabledKey) else { return (false, []) }
        let cli = CLIAvailability()
        var options: [MentionOption] = []
        for (trigger, kind) in AgentMention.candidates {
            let binary = AgentEngineRegistry.lookup(id: kind.rawValue)?.binaryName ?? trigger
            let available = await cli.locate(binary: binary) != nil
            options.append(MentionOption(
                trigger: trigger,
                label: Self.engineShortLabel(forId: kind.rawValue),
                systemImage: Self.replyIcon(for: kind.rawValue),
                brandLogo: Self.replyBrandLogo(for: kind.rawValue),
                available: available
            ))
        }
        return (true, options)
    }

    /// entry id → ACP 适配器 spawn 命令(P3 三引擎统一 ACP;非 ACP entry → nil 走 makeEngine)。
    nonisolated static func acpCommand(for entryId: String) -> [String]? {
        switch entryId {
        case AgentEngineKind.openCode.rawValue: return ["opencode", "acp"]
        case AgentEngineKind.claudeCode.rawValue: return ["claude-agent-acp"]
        case AgentEngineKind.codex.rawValue: return ["codex-acp"]
        default: return nil
        }
    }

    /// ACP engine 的会话 cwd(与 applySelectedAgentEngine 的 openCode 分支同一解析:
    /// ProjectStore.current + ProjectConfig.ensure,fallback project.rootURL)。
    /// P2 会话指针 key 用(与 engine 实际 cwd 保持一致是关键,故收敛为一个入口)。
    nonisolated static func currentACPProjectRoot(defaults: UserDefaults) -> URL {
        ProjectStore.ensureDefaultProjectRegistered(defaults: defaults)
        let project = ProjectStore.current(defaults: defaults)
        return (try? ProjectConfig.ensure(for: project)) ?? project.rootURL
    }

    // MARK: - 回复来源 segmented 配置（聊天面板 Composer 上方，直觉可用性）

    /// 从 UserDefaults 派生回复来源配置：当前 target + 可选项列表。
    /// 灵魂层（🐾 默认首项）+ `AgentEngineRegistry.all` 每个 engine 一项。聊天面板
    /// 开卡时调，同步 segmented 与设置面板（两处写同一份 UD）。
    nonisolated static func replyConfiguration(
        for defaults: UserDefaults
    ) -> (target: ReplyTarget, options: [ReplyOption]) {
        let enabled = defaults.bool(forKey: agentModeEnabledKey)
        let target: ReplyTarget = enabled
            ? .agent(AgentEngineRegistry.resolve(from: defaults).id)
            : .soul
        var options: [ReplyOption] = [
            ReplyOption(target: .soul, label: "聊天", systemImage: "pawprint.fill")
        ]
        options += AgentEngineRegistry.all.map { entry in
            // 短标签：取 displayName 首词（"Claude Code"→"Claude"，"opencode (ACP)"→"opencode"）。
            let short = entry.displayName.split(separator: " ").first.map(String.init) ?? entry.displayName
            return ReplyOption(target: .agent(entry.id), label: short, systemImage: replyIcon(for: entry.id), brandLogo: replyBrandLogo(for: entry.id))
        }
        return (target, options)
    }

    /// engine id → SF Symbol 图标（segmented 紧凑展示用;P5 follow-up 补全弹层复用）。
    /// 写死 id 映射（图标本就是 per-engine 定制）；未来 entry 加 iconSymbol 字段可去除此处 switch。
    nonisolated static func replyIcon(for engineId: String) -> String {
        switch engineId {
        case AgentEngineKind.claudeCode.rawValue: return "bolt.fill"
        case AgentEngineKind.codex.rawValue:      return "chevron.left.forwardslash.chevron.right"
        case AgentEngineKind.openCode.rawValue:   return "terminal.fill"
        default:                                  return "wrench.and.screwdriver"
        }
    }

    /// engine id → 品牌 logo（segmented / 补全弹层真品牌图标;无匹配时 nil 走 `systemImage`）。
    nonisolated static func replyBrandLogo(for engineId: String) -> BrandLogo? {
        switch engineId {
        case AgentEngineKind.claudeCode.rawValue: return .claude
        case AgentEngineKind.codex.rawValue:      return .codex
        case AgentEngineKind.openCode.rawValue:   return .opencode
        default:                                  return nil
        }
    }
}
