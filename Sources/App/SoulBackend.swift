import Foundation
import Orchestrator

/// 灵魂层后端能力声明(镜像「形象插件化」的 `supportedSignatures` 能力闸)。
///
/// 用于设置 UI 标注 / 未来按能力过滤(如「只列可 bundle 的后端」),不参与
/// provider 构造逻辑本身 —— 构造永远走 `SoulBackendEntry.makeProvider`。
public struct SoulBackendCapability: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 云托管:用户自带 key 打第三方 API(OpenAI / Anthropic / DeepSeek …)。
    public static let cloudHosted = SoulBackendCapability(rawValue: 1 << 0)
    /// 本地网关:localhost 常驻 daemon(openclaw),由 App 自动 bootstrap。
    public static let localGateway = SoulBackendCapability(rawValue: 1 << 1)
    /// 自带跨会话记忆(SOUL.md / MEMORY 持久化,「越用越懂你」)。
    public static let nativeMemory = SoulBackendCapability(rawValue: 1 << 2)
    /// 自带人格(内置 persona / SOUL 身份,不靠本仓 prompt 硬塞)。
    public static let nativePersona = SoulBackendCapability(rawValue: 1 << 3)
    /// 可 bundle 进 .app(单二进制零依赖)。云后端 / openclaw 均不满足,
    /// 留给未来 opencode 类后端声明。
    public static let bundleable = SoulBackendCapability(rawValue: 1 << 4)
}

/// 一个灵魂层后端在「设置面板 provider picker」里的展示 + 持久化映射(纯数据,
/// 不引 SwiftUI/UI 类型)。让**每个后端自己声明** picker 怎么显示、配置写读哪个
/// `UserDefaults` 槽 —— 镜像「形象插件化」里 pet 用 `supportedSignatures` 自声明
/// 能力,Settings 层据此渲染/读写,**零写死类型分支**(新增后端=填一个 picker info,
/// picker / 字段 / 存取全自动跟上)。
public struct SoulBackendPickerInfo: Sendable, Equatable {
    /// 云后端三槽的 `UserDefaults` key(用户在 picker 里手填 key/baseURL/model 就
    /// 写这三个槽、读也从这读)。**`nil` = 该后端自动管理配置**(如 openclaw 走专属
    /// 槽 + App 自动 bootstrap),picker 选中它时**不显示**手填字段、改显示 `managedNote`。
    public let apiKeySlot: String?
    public let baseURLSlot: String?
    public let modelSlot: String?
    /// 字段标签 / 占位提示(仅 `apiKeySlot != nil` 的云后端用到)。
    public let keyLabel: String
    public let keyPlaceholder: String
    public let baseURLPlaceholder: String
    public let baseURLHint: String
    public let modelPlaceholder: String
    /// 自动管理后端(`apiKeySlot == nil`)被选中时,替代手填字段显示的一句说明。
    public let managedNote: String

    public init(
        apiKeySlot: String?,
        baseURLSlot: String?,
        modelSlot: String?,
        keyLabel: String = "API Key",
        keyPlaceholder: String = "sk-...",
        baseURLPlaceholder: String = "",
        baseURLHint: String = "留空使用默认 endpoint",
        modelPlaceholder: String = "",
        managedNote: String = ""
    ) {
        self.apiKeySlot = apiKeySlot
        self.baseURLSlot = baseURLSlot
        self.modelSlot = modelSlot
        self.keyLabel = keyLabel
        self.keyPlaceholder = keyPlaceholder
        self.baseURLPlaceholder = baseURLPlaceholder
        self.baseURLHint = baseURLHint
        self.modelPlaceholder = modelPlaceholder
        self.managedNote = managedNote
    }

    /// 该后端是否自动管理配置(无手填 key/baseURL/model 字段)。
    public var isManaged: Bool { apiKeySlot == nil }
}

/// 一个灵魂层后端的注册项。镜像 `PetPluginRegistry` 的 entry:`id`(字符串
/// 身份,取代写死 enum)+ 能力声明 + 构造闭包 + 设置 picker 展示/槽位。新增后端 =
/// 加一个 entry。
public struct SoulBackendEntry: Sendable, Identifiable {
    /// 持久化身份。与 `UserDefaults["LLMProvider"]` 存的字符串对齐;两个老值
    /// (`openAICompatible` / `anthropic`)沿用 `LLMProviderKind` 的 rawValue → 零迁移。
    public let id: String
    /// 设置 UI 展示名(provider picker / 标注用)。
    public let displayName: String
    /// 能力声明(能力闸;UI / 未来按能力过滤用)。
    public let capabilities: SoulBackendCapability
    /// 设置面板 provider picker 的展示 + 配置槽映射(让后端自声明 UI/存取,
    /// Settings 层不写死类型分支)。
    public let picker: SoulBackendPickerInfo
    /// 从 `UserDefaults` 构造 provider。配置缺失(无 key / 专属槽空)→ 返回 nil,
    /// 上层走 echo fallback。纯函数,无副作用,可在任意 isolation 调用。
    public let makeProvider: @Sendable (UserDefaults) -> (any LLMProvider)?

    public init(
        id: String,
        displayName: String,
        capabilities: SoulBackendCapability,
        picker: SoulBackendPickerInfo,
        makeProvider: @escaping @Sendable (UserDefaults) -> (any LLMProvider)?
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.picker = picker
        self.makeProvider = makeProvider
    }
}

/// 灵魂层后端注册表 —— 镜像「形象插件化」到 LLM provider 选型层。
///
/// 用 id 字符串 + 注册项取代写死的 `switch kind`:`AppBootstrap.resolveLLMProvider`
/// 经 `resolve(from:)` 选中 entry、再调 `makeProvider` 构造 provider。新增后端
/// (openclaw 已落地;hermes / 未来后端留 slot)= 往 `all` 加一个 entry,路由分支
/// 零改动。
///
/// 持久化 key 沿用 `LLMProviderKind.userDefaultsKey`("LLMProvider"),与既有
/// UserDefaults 值兼容(零迁移);entry id 沿用 `LLMProviderKind` 的 rawValue,
/// 避免字符串漂移。
public enum SoulBackendRegistry {

    /// OpenAI 兼容(默认 fallback;也覆盖 DeepSeek / Groq / Ollama 等自定义 baseURL)。
    public static let openAICompatible = SoulBackendEntry(
        id: LLMProviderKind.openAICompatible.rawValue,
        displayName: "OpenAI 兼容",
        capabilities: [.cloudHosted],
        picker: SoulBackendPickerInfo(
            apiKeySlot: LLMSettingsKeys.openAIApiKey,
            baseURLSlot: LLMSettingsKeys.openAIBaseURL,
            modelSlot: LLMSettingsKeys.openAIModel,
            keyLabel: "OpenAI Key",
            keyPlaceholder: "sk-...",
            baseURLPlaceholder: "https://api.openai.com/v1",
            baseURLHint: "留空使用默认 OpenAI endpoint",
            modelPlaceholder: "gpt-4o-mini"
        ),
        makeProvider: { AppBootstrap.resolveOpenAICompatibleProvider(userDefaults: $0) }
    )

    /// Anthropic Messages API。
    public static let anthropic = SoulBackendEntry(
        id: LLMProviderKind.anthropic.rawValue,
        displayName: "Anthropic",
        capabilities: [.cloudHosted],
        picker: SoulBackendPickerInfo(
            apiKeySlot: LLMSettingsKeys.anthropicApiKey,
            baseURLSlot: LLMSettingsKeys.anthropicBaseURL,
            modelSlot: LLMSettingsKeys.anthropicModel,
            keyLabel: "Anthropic Key",
            keyPlaceholder: "sk-ant-...",
            baseURLPlaceholder: "https://api.anthropic.com",
            baseURLHint: "留空使用默认 Anthropic endpoint",
            modelPlaceholder: "claude-sonnet-4-5"
        ),
        makeProvider: { AppBootstrap.resolveAnthropicProvider(userDefaults: $0) }
    )

    /// OpenClaw 本地网关:带 SOUL / MEMORY 的常驻 agent,接成 OpenAI 兼容
    /// endpoint(由 `MinimalAppDelegate.setupOpenClawBootstrap` 自动 bootstrap
    /// 写专属槽)。三槽 `nil` → 自动管理(picker 选中时只显示状态说明,不手填 key)。
    public static let openclaw = SoulBackendEntry(
        id: "openclaw",
        displayName: "OpenClaw 本地网关",
        capabilities: [.localGateway, .nativeMemory, .nativePersona],
        picker: SoulBackendPickerInfo(
            apiKeySlot: nil,
            baseURLSlot: nil,
            modelSlot: nil,
            managedNote: "OpenClaw 由本地网关自动管理(自带 SOUL + 记忆),无需手填 key —— 运行状态见下方卡片。"
        ),
        makeProvider: { AppBootstrap.resolveOpenClawProvider(userDefaults: $0) }
    )

    /// 所有内置后端。顺序即默认优先级;`all[0]`(openAICompatible)是 fallback。
    public static let all: [SoulBackendEntry] = [openAICompatible, anthropic, openclaw]

    /// 按 id 查 entry。未知 id → nil。
    public static func lookup(id: String) -> SoulBackendEntry? {
        all.first { $0.id == id }
    }

    /// 从 `UserDefaults["LLMProvider"]` 解析当前选中后端。
    ///
    /// key 缺失 / 值无法匹配任何 entry → fallback 到 `all[0]`(openAICompatible),
    /// 与旧 `LLMProviderKind.resolve` 的默认行为一致(向后兼容)。
    public static func resolve(from userDefaults: UserDefaults) -> SoulBackendEntry {
        guard let raw = userDefaults.string(forKey: LLMProviderKind.userDefaultsKey),
              let entry = lookup(id: raw) else {
            return all[0]
        }
        return entry
    }
}
