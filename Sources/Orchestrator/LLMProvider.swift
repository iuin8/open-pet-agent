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
