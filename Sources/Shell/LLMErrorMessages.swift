import Foundation

/// LLM 调用失败的友好中文文案 —— Shell 层把 `Error` 翻译成用户能看懂的提示,
/// 而不是把 stacktrace / NSURLError 编号扔到聊天气泡里。
///
/// 设计原则:
/// - 文案是 Markdown(被 `BondedMarkdownBubble` 渲染时会得到 ⚠️ + 加粗 + 配置提醒)
/// - 已知错误类型(URLError / Decoding / HTTPStatusError)走分类映射,未知 fallback
///   保留 `error.localizedDescription` 让用户至少能截图反馈
/// - 不抛出新错误类型,只输出 String —— 让 `BondedSession.catch` 直接喂给
///   `chain.appendAssistantReply` 没有耦合
public enum LLMErrorMessages {

    /// AI 模型未配置(`replyStream` 检测到 `LLMProviderBox.current == nil`)。
    /// 提示用户去菜单栏 → ⚙️ 设置 配置 API key + 模型。
    /// **必须**与 `Orchestrator.CompanionOrchestrator.providerNotConfiguredMessage`
    /// 保持一致 —— 两个模块各定义但用户感知同一句。
    public static let providerNotConfigured: String =
        "⚠️ **未配置 AI 模型** —— 请打开菜单栏 → ⚙️ 设置,填写 baseURL / API key / 模型名后重试。"

    /// 把任意 `Error` 翻译成 Markdown 友好文案。
    public static func friendly(for error: Error) -> String {
        if let urlError = error as? URLError {
            return friendlyURL(urlError)
        }
        // fallback: 保留原始 message 给用户截图反馈
        return "⚠️ **回复失败** —— \(error.localizedDescription)"
    }

    private static func friendlyURL(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "⚠️ **没有网络** —— 检查 Wi-Fi / 代理后重试。"
        case .timedOut:
            return "⚠️ **请求超时** —— LLM 服务响应太慢,可以稍后重试或换个模型。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "⚠️ **连不上 AI 服务器** —— 检查 baseURL 是否正确(常见错误:多了 `/v1`、漏了 https://)。"
        case .userAuthenticationRequired, .clientCertificateRequired:
            return "⚠️ **认证失败** —— API key 可能错了或过期,请到 ⚙️ 设置 重新填写。"
        case .cancelled:
            return "⚠️ **请求已取消**"
        default:
            return "⚠️ **网络错误** —— `\(error.localizedDescription)`(URLError code \(error.code.rawValue))"
        }
    }
}
