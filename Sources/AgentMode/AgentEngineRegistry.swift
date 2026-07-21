import Foundation

/// 工具层后端能力声明(镜像「形象插件化」的 `supportedSignatures` 能力闸,
/// 与灵魂层 `SoulBackendCapability` 同构)。
///
/// 用于设置 UI 标注 / 未来按能力过滤(如「只列可 bundle 的 engine」),不参与
/// engine 构造逻辑本身 —— 构造永远走 `AgentEngineEntry.makeEngine`。
public struct AgentEngineCapability: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 依赖用户已装并登录的外部 CLI(`claude` / `codex`),`isAvailable` 探测
    /// PATH;未装则 engine 不可用。
    public static let requiresCLI = AgentEngineCapability(rawValue: 1 << 0)
    /// 可 bundle 进 .app(单二进制零依赖,用户无需自装 CLI)。当前仅 opencode
    /// 满足(bundled headless runtime,N3.x 真接入)。
    public static let bundleable = AgentEngineCapability(rawValue: 1 << 1)
    /// 原生视觉(读图 / 截屏理解),codex 自带。
    public static let nativeVision = AgentEngineCapability(rawValue: 1 << 2)
}

/// 一个工具层 engine 的注册项。镜像灵魂层 `SoulBackendEntry`:`id`(字符串
/// 身份,取代写死 `switch kind`)+ 展示名 + CLI binary 名 + 能力声明 + 构造闭包。
/// 新增 engine = 加一个 entry,路由 / picker / 探测分支零改动。
public struct AgentEngineEntry: Sendable, Identifiable {
    /// 持久化身份。与 `UserDefaults["tool.engine.kind"]` 存的字符串对齐;沿用
    /// `AgentEngineKind` 的 rawValue → 零迁移、与既有 UD 值兼容。
    public let id: String
    /// 设置 UI 展示名(engine picker 下拉)。
    public let displayName: String
    /// CLI binary 名(`CLIAvailability.locate` 探测用)。bundleable engine
    /// 也给名字(便于统一探测),真 bundled runtime 接入后可忽略。
    public let binaryName: String
    /// 能力声明(能力闸;UI / 未来按能力过滤用)。
    public let capabilities: AgentEngineCapability
    /// 构造 engine 实例。`AgentModeRouter.setEngine` 拿到后注册;engine kind 由
    /// 实例的 `static kind` 反推(`type(of:).kind`),不靠 entry.id。纯函数,
    /// 无副作用,可在 `@MainActor` 调用。
    public let makeEngine: @Sendable () -> any AgentEngine

    public init(
        id: String,
        displayName: String,
        binaryName: String,
        capabilities: AgentEngineCapability,
        makeEngine: @escaping @Sendable () -> any AgentEngine
    ) {
        self.id = id
        self.displayName = displayName
        self.binaryName = binaryName
        self.capabilities = capabilities
        self.makeEngine = makeEngine
    }
}

/// 工具层 engine 注册表 —— 镜像「形象插件化」到 `AgentEngine` 选型层(与灵魂层
/// `SoulBackendRegistry` 同构)。
///
/// 用 id 字符串 + 注册项取代写死的 `switch kind`:`MinimalAppDelegate
/// .applySelectedAgentEngine` 经 `resolve(from:)` 选中 entry、再调 `makeEngine`
/// 构造 engine 装进 router。新增 engine(claude/codex 已落地;opencode 已留
/// 一等 entry,bundled runtime 待 N3.x)= 往 `all` 加一个 entry,路由 / picker /
/// CLI 探测分支零改动。
///
/// 持久化 key 沿用 `AgentEngineKind.userDefaultsKey`("tool.engine.kind");
/// entry id 沿用 `AgentEngineKind` 的 rawValue,避免字符串漂移。
public enum AgentEngineRegistry {

    /// Claude Code via **ACP**(`claude-agent-acp` 适配器子进程,P3 起取代 `claude -p` 一次性
    /// 子进程)。认证带外(复用 claude CLI 登录态);能力实测见 ACPAgentEngineKinds.swift。
    public static let claudeCode = AgentEngineEntry(
        id: AgentEngineKind.claudeCode.rawValue,
        displayName: "Claude Code",
        binaryName: "claude-agent-acp",
        capabilities: [.requiresCLI],
        makeEngine: { ClaudeACPAgentEngine(command: ["claude-agent-acp"]) }
    )

    /// Codex via **ACP**(`codex-acp` 适配器子进程,P3 起取代 `codex exec` 一次性子进程)。
    /// 认证带外(复用 codex CLI 登录态);原生视觉经 ACP image prompt capability。
    public static let codex = AgentEngineEntry(
        id: AgentEngineKind.codex.rawValue,
        displayName: "Codex",
        binaryName: "codex-acp",
        capabilities: [.requiresCLI, .nativeVision],
        makeEngine: { CodexACPAgentEngine(command: ["codex-acp"]) }
    )

    /// opencode via **ACP**(Agent Client Protocol)—— 经 JSON-RPC/stdio 接 opencode 子进程,
    /// 一套协议取代手写 stdout parser(ACP-0~1b)。需用户已装 opencode CLI(或未来 bundle 进 .app)。
    /// 实测 opencode 1.2.27 真互操作(initialize/session/prompt/agent_message_chunk/end_turn 全通)。
    public static let openCode = AgentEngineEntry(
        id: AgentEngineKind.openCode.rawValue,
        displayName: "opencode (ACP)",
        binaryName: "opencode",
        capabilities: [.bundleable],
        makeEngine: { ACPAgentEngine() }
    )

    /// 所有内置 engine。顺序即 picker 展示顺序;`all[0]`(claudeCode)是 fallback。
    public static let all: [AgentEngineEntry] = [claudeCode, codex, openCode]

    /// 按 id 查 entry。未知 id → nil。
    public static func lookup(id: String) -> AgentEngineEntry? {
        all.first { $0.id == id }
    }

    /// 从 `UserDefaults["tool.engine.kind"]` 解析当前选中 engine。
    ///
    /// key 缺失 / 值无法匹配任何 entry → fallback 到 `all[0]`(claudeCode),
    /// 与旧 `applySelectedAgentEngine` 的默认行为一致(向后兼容)。
    public static func resolve(from userDefaults: UserDefaults) -> AgentEngineEntry {
        guard let raw = userDefaults.string(forKey: AgentEngineKind.userDefaultsKey),
              let entry = lookup(id: raw) else {
            return all[0]
        }
        return entry
    }
}
