import Foundation

/// LLM 相关配置的 `UserDefaults` key 常量集中点。
///
/// 改成 UserDefaults 后(原来 apiKey 走 KeychainStore),所有 LLM 配置
/// (provider / apiKey / baseURL / model)都同源存 UserDefaults,设置面板
/// 打开时回显、保存时写入、`AppBootstrap.resolveLLMConfig` 启动时读,统一
/// 一份 key 命名,避免散落字符串字面量带来的拼写漂移。
///
/// 安全说明:虽然苹果文档建议密钥走 Keychain,本项目目前定位为开源桌宠
/// 玩具 + 用户自己的 API key(不是平台凭据),用 UserDefaults 换取"无
/// 重签名 Keychain 弹窗"的开发体验,符合"实用 > 教条"。后续如果上架
/// App Store / 做企业分发,再回去做 Keychain 版本即可。
public enum LLMSettingsKeys {
    // MARK: - OpenAI 兼容(默认 provider)
    public static let openAIApiKey = "OpenAIAPIKey"
    public static let openAIBaseURL = "OpenAIBaseURL"
    public static let openAIModel = "OpenAIModel"

    // MARK: - Anthropic
    public static let anthropicApiKey = "AnthropicAPIKey"
    public static let anthropicBaseURL = "AnthropicBaseURL"
    public static let anthropicModel = "AnthropicModel"

    // MARK: - OpenClaw 本地网关(灵魂层一等后端)
    //
    // openclaw 不再「伪装混进 OpenAI 槽」,而是用独立槽存自动 bootstrap 出来的
    // localhost baseURL(已带 `/v1`)+ Bearer token。model 固定 `openclaw`
    // (chatCompletions 只认这个 id,见 OpenClawGatewayManager),不需单独 key。
    // 与 OpenAI/Anthropic 槽隔离 → 用户自配云 provider 与 openclaw 自动注入互不覆盖。
    public static let openClawBaseURL = "OpenClawBaseURL"
    public static let openClawToken = "OpenClawToken"
}
