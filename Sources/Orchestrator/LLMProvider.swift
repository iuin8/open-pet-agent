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
