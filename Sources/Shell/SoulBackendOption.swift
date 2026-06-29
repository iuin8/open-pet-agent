import Foundation

/// 设置面板 LLM provider picker 的一项 —— App 层从 `SoulBackendRegistry.all` 映射
/// 注入(Shell 不依赖 App,故走注入,镜像 `availableAgentEngines` / `availablePetPlugins`)。
/// 纯数据;`managed = true` 的后端(openclaw 本地网关)由 App 自动管理配置,picker
/// 选中它时**隐藏**手填字段、改显示 `managedNote`。
public struct SoulBackendOption: Identifiable, Sendable, Equatable {
    public let id: String            // 后端 id,持久化到 `UserDefaults["LLMProvider"]`
    public let displayName: String   // picker 展示名
    public let managed: Bool         // true = 自动管理(无手填字段)
    public let keyLabel: String
    public let keyPlaceholder: String
    public let baseURLPlaceholder: String
    public let baseURLHint: String
    public let modelPlaceholder: String
    public let managedNote: String

    public init(
        id: String, displayName: String, managed: Bool,
        keyLabel: String = "API Key", keyPlaceholder: String = "sk-...",
        baseURLPlaceholder: String = "", baseURLHint: String = "留空使用默认 endpoint",
        modelPlaceholder: String = "", managedNote: String = ""
    ) {
        self.id = id; self.displayName = displayName; self.managed = managed
        self.keyLabel = keyLabel; self.keyPlaceholder = keyPlaceholder
        self.baseURLPlaceholder = baseURLPlaceholder; self.baseURLHint = baseURLHint
        self.modelPlaceholder = modelPlaceholder; self.managedNote = managedNote
    }

    /// SwiftUI preview / 测试用兜底(不经 App 注入时);生产路径由 App 从
    /// `SoulBackendRegistry.all` 注入,镜像 `availableAgentEngines` 默认值的做法。
    /// 三项与注册表 `all` 顺序一致(openAICompatible / anthropic / openclaw)。
    public static let defaults: [SoulBackendOption] = [
        SoulBackendOption(
            id: "openAICompatible", displayName: "OpenAI 兼容", managed: false,
            keyLabel: "OpenAI Key", keyPlaceholder: "sk-...",
            baseURLPlaceholder: "https://api.openai.com/v1",
            baseURLHint: "留空使用默认 OpenAI endpoint", modelPlaceholder: "gpt-4o-mini"
        ),
        SoulBackendOption(
            id: "anthropic", displayName: "Anthropic", managed: false,
            keyLabel: "Anthropic Key", keyPlaceholder: "sk-ant-...",
            baseURLPlaceholder: "https://api.anthropic.com",
            baseURLHint: "留空使用默认 Anthropic endpoint", modelPlaceholder: "claude-sonnet-4-5"
        ),
        SoulBackendOption(
            id: "openclaw", displayName: "OpenClaw 本地网关", managed: true,
            managedNote: "OpenClaw 由本地网关自动管理(自带 SOUL + 记忆),无需手填 key —— 运行状态见下方卡片。"
        )
    ]
}
