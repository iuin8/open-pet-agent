import Foundation

public protocol LLMProvider: Sendable {
    func chat(_ messages: [LLMMessage]) async throws -> String

    /// Streaming variant. Each yielded value is an **incremental delta** (new token text).
    /// Callers accumulate deltas to build the full reply.
    ///
    /// The default implementation wraps `chat(_:)`: it awaits the full reply,
    /// yields it as a single chunk, then finishes. This means existing stub
    /// providers (e.g. `StubProvider` in tests) automatically satisfy
    /// the streaming protocol without any code changes.
    func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error>

    /// 工具调用通道(灵魂层「自建轻 harness」P0)。给定一组工具声明,模型可在
    /// 这一轮返回纯文本、或要求调用若干工具(`LLMTurn.toolCalls`)。**非流式**——
    /// 工具回合走原子请求,绕开流式 tool_call 累加深坑(见 roadmap §自建 harness L2);
    /// 最终纯文本回合仍可用 `streamChat` 流式。
    ///
    /// **默认实现忽略 `tools`、退化为调 `chat(_:)`** —— 老 Provider / 测试 stub 零改动
    /// 即满足协议(能力闸 + default no-op:不支持工具的后端默认不调工具,而非报错)。
    /// 真正支持的 Provider(OpenAI / Anthropic)各自覆写,把两家 API 差异关在内部。
    func chatWithTools(_ messages: [LLMMessage], tools: [LLMToolDef]) async throws -> LLMTurn
}

public extension LLMProvider {
    /// Default implementation: delegates to `chat(_:)` and yields the
    /// full response as a single delta. Conforming types may override
    /// this to provide true incremental SSE streaming.
    func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let full = try await chat(messages)
                    continuation.yield(full)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 默认实现:忽略 `tools`,调旧 `chat(_:)` 把回复包成纯文本 `LLMTurn`
    /// (`stopReason = .stop`,无工具调用)。不支持工具的后端默认 no-op,零改动编译。
    func chatWithTools(_ messages: [LLMMessage], tools: [LLMToolDef]) async throws -> LLMTurn {
        let text = try await chat(messages)
        return LLMTurn(text: text, toolCalls: [], stopReason: .stop)
    }
}

public enum LLMRole: String, Sendable, Codable, Equatable {
    case system
    case user
    case assistant
}

public struct LLMMessage: Sendable, Codable, Equatable {
    public let role: LLMRole
    public let content: String

    public init(role: LLMRole, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LLMProviderError: Error, Equatable {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case decodingFailed(String)
    case emptyResponse
    case transportError(String)
}


// MARK: - 用户可读错误描述(LocalizedError)

extension LLMProviderError: LocalizedError {
    /// NSError 桥接 `localizedDescription` 走这里 —— 卡片 / 气泡 / 日志共用同一份文案。
    /// httpError 按状态码给行动指引(401/403 换 key、429 降频、400 查模型名),并附服务商
    /// 错误体摘录(有界),避免只显示「Orchestrator.LLMProviderError错误0」这种不可读信息。
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API key —— 请打开菜单栏 → ⚙️ 设置 填写后重试。"
        case .httpError(let status, let body):
            let detail = Self.httpDetail(body)
            switch status {
            case 401, 403:
                return "API key 无效或已过期(HTTP \(status))—— 请到 ⚙️ 设置 检查并更新 key。\(detail)"
            case 429:
                return "请求太频繁或额度不足(HTTP 429)—— 稍后重试,或检查服务商套餐额度。\(detail)"
            case 400:
                return "请求被拒绝(HTTP 400,常见于模型名写错或该模型不可用)。\(detail)"
            case 500...599:
                return "AI 服务端错误(HTTP \(status))—— 稍后重试。\(detail)"
            default:
                return "AI 服务返回错误(HTTP \(status))。\(detail)"
            }
        case .decodingFailed:
            return "响应解析失败 —— 模型返回了非预期格式,可重试或换模型。"
        case .emptyResponse:
            return "模型返回空内容 —— 可重试或换个模型。"
        case .transportError(let message):
            return "网络请求失败 —— \(message)"
        }
    }

    /// 服务商错误体摘录:首个非空行 ≤120 字符;空体 → 空串(不残留噪音)。
    private static func httpDetail(_ body: String) -> String {
        guard let line = body.split(separator: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let clipped = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        return "服务商信息:\(clipped)"
    }
}

// MARK: - 错误响应体读取(stream 路径)

/// 读取 HTTP 错误响应体(有界 ≤ `limit` 字节):streamChat 非 2xx 时把服务商的错误
/// JSON 带上(如 "Incorrect API key provided"),供 `LLMProviderError.httpError.body`
/// 展示。读体失败不掩盖主错误 —— 返回已读到的部分(可能为空)。
enum LLMErrorBodyDrain {
    static func drain(_ stream: AsyncThrowingStream<UInt8, Error>, limit: Int = 4096) async -> String {
        var data = Data()
        data.reserveCapacity(1024)
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // 读体失败(连接中断等)忽略:主错误是 HTTP 状态码,体只是附加上下文。
        }
        return String(decoding: data, as: UTF8.self)
    }
}
