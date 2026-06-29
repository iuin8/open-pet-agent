import Foundation

/// Anthropic Claude API provider implementing `LLMProvider`.
///
/// The Anthropic Messages API differs from OpenAI Chat Completions in three
/// key ways:
/// 1. **Endpoint**: `https://api.anthropic.com/v1/messages` (fixed)
/// 2. **Auth header**: `x-api-key: <key>` + `anthropic-version: 2023-06-01`
///    instead of `Authorization: Bearer <key>`
/// 3. **System prompt**: top-level `"system"` field, not a message role
/// 4. **max_tokens**: required (not optional)
/// 5. **SSE format**: `event: content_block_delta` with `delta.text` chunks
///    instead of OpenAI's `choices[0].delta.content`
public actor AnthropicProvider: LLMProvider {
    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias HTTPStreamClient = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse)

    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let anthropicVersion = "2023-06-01"
    public static let defaultMaxTokens = 4096

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let maxTokens: Int
    private let httpClient: HTTPClient
    private let httpStreamClient: HTTPStreamClient

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        endpoint: URL = AnthropicProvider.defaultEndpoint,
        maxTokens: Int = AnthropicProvider.defaultMaxTokens,
        httpClient: @escaping HTTPClient = { try await URLSession.shared.data(for: $0) },
        httpStreamClient: @escaping HTTPStreamClient = { request in
            let (urlBytes, response) = try await URLSession.shared.bytes(for: request)
            let stream = AsyncThrowingStream<UInt8, Error> { continuation in
                Task {
                    do {
                        for try await byte in urlBytes {
                            continuation.yield(byte)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            return (stream, response)
        }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.maxTokens = maxTokens
        self.httpClient = httpClient
        self.httpStreamClient = httpStreamClient
    }

    // MARK: - Atomic chat (non-streaming)

    public func chat(_ messages: [LLMMessage]) async throws -> String {
        let (systemPrompt, userAssistantMessages) = Self.splitMessages(messages)

        let requestBody = AnthropicRequestBody(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: userAssistantMessages.map { AnthropicMessageDTO(role: $0.role.rawValue, content: $0.content) },
            stream: false
        )

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(requestBody)
        } catch {
            throw LLMProviderError.transportError(error.localizedDescription)
        }

        let request = Self.buildRequest(apiKey: apiKey, endpoint: endpoint, bodyData: bodyData)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch let error as LLMProviderError {
            throw error
        } catch {
            throw LLMProviderError.transportError(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw LLMProviderError.httpError(status: http.statusCode, body: body)
        }

        let completion: AnthropicResponse
        do {
            completion = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            throw LLMProviderError.decodingFailed(error.localizedDescription)
        }

        guard let firstContent = completion.content.first, firstContent.type == "text" else {
            throw LLMProviderError.emptyResponse
        }

        return firstContent.text
    }

    // MARK: - Tool-calling chat (non-streaming)

    /// 工具回合(非流式):顶层 `tools`(`input_schema` = schema)发请求,解析
    /// `content[]` 里的 `tool_use` 块(Anthropic 的 input 本就是对象)+ `stop_reason`。
    public func chatWithTools(_ messages: [LLMMessage], tools: [LLMToolDef]) async throws -> LLMTurn {
        let (systemPrompt, userAssistantMessages) = Self.splitMessages(messages)

        let requestBody = AnthropicToolsRequestBody(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: userAssistantMessages.map { AnthropicMessageDTO(role: $0.role.rawValue, content: $0.content) },
            stream: false,
            tools: tools.map {
                AnthropicToolDTO(name: $0.name, description: $0.description, inputSchema: $0.parameters)
            }
        )

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(requestBody)
        } catch {
            throw LLMProviderError.transportError(error.localizedDescription)
        }

        let request = Self.buildRequest(apiKey: apiKey, endpoint: endpoint, bodyData: bodyData)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch let error as LLMProviderError {
            throw error
        } catch {
            throw LLMProviderError.transportError(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw LLMProviderError.httpError(status: http.statusCode, body: body)
        }

        let completion: AnthropicToolsResponse
        do {
            completion = try JSONDecoder().decode(AnthropicToolsResponse.self, from: data)
        } catch {
            throw LLMProviderError.decodingFailed(error.localizedDescription)
        }

        // content 可同时含 text 块与 tool_use 块 → 文本拼接、工具调用各收集。
        var textParts: [String] = []
        var toolCalls: [LLMToolCall] = []
        for block in completion.content {
            switch block.type {
            case "text":
                if let t = block.text { textParts.append(t) }
            case "tool_use":
                if let id = block.id, let name = block.name {
                    toolCalls.append(LLMToolCall(id: id, name: name, arguments: block.input ?? .object([:])))
                }
            default:
                break
            }
        }
        let text = textParts.isEmpty ? nil : textParts.joined()
        let stopReason = Self.mapStopReason(completion.stopReason, hasToolCalls: !toolCalls.isEmpty)
        return LLMTurn(text: text, toolCalls: toolCalls, stopReason: stopReason)
    }

    /// 归一 Anthropic `stop_reason` → `LLMStopReason`。
    internal static func mapStopReason(_ raw: String?, hasToolCalls: Bool) -> LLMStopReason {
        switch raw {
        case "tool_use": return .toolUse
        case "end_turn": return .stop
        case "max_tokens": return .maxTokens
        default: return hasToolCalls ? .toolUse : .stop
        }
    }

    // MARK: - Streaming chat (SSE)

    // nonisolated: all captured properties are `let` constants (immutable) and
    // Sendable; accessing them from a nonisolated context is safe in Swift 6.
    public nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let capturedApiKey = apiKey
        let capturedModel = model
        let capturedEndpoint = endpoint
        let capturedMaxTokens = maxTokens
        let capturedStreamClient = httpStreamClient

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try Self.buildStreamRequest(
                        apiKey: capturedApiKey,
                        model: capturedModel,
                        endpoint: capturedEndpoint,
                        maxTokens: capturedMaxTokens,
                        messages: messages
                    )
                    let (byteStream, response) = try await capturedStreamClient(request)

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: LLMProviderError.httpError(status: http.statusCode, body: ""))
                        return
                    }

                    try await Self.consumeAnthropicSSEStream(byteStream, continuation: continuation)
                } catch let error as LLMProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMProviderError.transportError(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Internal helpers (internal for testability)

    /// Split messages into system prompt and user/assistant messages.
    /// Anthropic requires the system prompt as a top-level field; the
    /// messages array must only contain user and assistant roles.
    internal static func splitMessages(_ messages: [LLMMessage]) -> (systemPrompt: String, messages: [LLMMessage]) {
        var systemParts: [String] = []
        var conversationMessages: [LLMMessage] = []

        for message in messages {
            if message.role == .system {
                systemParts.append(message.content)
            } else {
                conversationMessages.append(message)
            }
        }

        return (systemParts.joined(separator: "\n"), conversationMessages)
    }

    /// Build the URLRequest with Anthropic-specific headers.
    internal static func buildRequest(apiKey: String, endpoint: URL, bodyData: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        return request
    }

    /// Build the streaming URLRequest.
    private static func buildStreamRequest(
        apiKey: String,
        model: String,
        endpoint: URL,
        maxTokens: Int,
        messages: [LLMMessage]
    ) throws -> URLRequest {
        let (systemPrompt, userAssistantMessages) = splitMessages(messages)
        let body = AnthropicRequestBody(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: userAssistantMessages.map { AnthropicMessageDTO(role: $0.role.rawValue, content: $0.content) },
            stream: true
        )
        let bodyData = try JSONEncoder().encode(body)
        return buildRequest(apiKey: apiKey, endpoint: endpoint, bodyData: bodyData)
    }

    /// Parse a single Anthropic SSE event string and return extracted delta texts.
    ///
    /// Anthropic events are delimited by `\n\n`. Each event consists of:
    /// - `event: <type>` line
    /// - `data: <json>` line(s)
    ///
    /// Only `content_block_delta` events with `delta.type == "text_delta"` are
    /// extracted; all others (message_start, content_block_start, ping,
    /// message_delta, message_stop) return empty arrays.
    internal static func parseAnthropicSSEEvent(_ event: String) -> [String] {
        let lines = event.components(separatedBy: "\n")

        var eventType: String?
        var dataLines: [String] = []

        for line in lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                dataLines.append(String(line.dropFirst(6)))
            }
        }

        guard eventType == "content_block_delta" else {
            return []
        }

        let combinedData = dataLines.joined()
        guard
            let jsonData = combinedData.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let delta = json["delta"] as? [String: Any],
            let deltaType = delta["type"] as? String,
            deltaType == "text_delta",
            let text = delta["text"] as? String
        else {
            return []
        }

        return [text]
    }

    /// Consume the raw byte stream, splitting on `\n\n` SSE event boundaries,
    /// and yield individual delta strings into the continuation.
    ///
    /// Uses `Data` buffer (not `String`) to preserve multi-byte UTF-8 codepoints
    /// across HTTP chunk boundaries (same fix as in OpenAIProvider).
    private static func consumeAnthropicSSEStream(
        _ byteStream: AsyncThrowingStream<UInt8, Error>,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var buffer = Data()
        let delimiter = Data([0x0A, 0x0A])

        for try await byte in byteStream {
            buffer.append(byte)
            while let boundary = buffer.range(of: delimiter) {
                let eventData = buffer.subdata(in: buffer.startIndex..<boundary.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
                yieldAnthropicEvent(from: eventData, continuation: continuation)
            }
        }

        // Flush any remaining bytes (server may close stream without trailing \n\n).
        if !buffer.isEmpty {
            yieldAnthropicEvent(from: buffer, continuation: continuation)
        }

        continuation.finish()
    }

    /// Decode one SSE event from `data` (assumed UTF-8) and yield delta strings.
    private static func yieldAnthropicEvent(
        from data: Data,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard let event = String(data: data, encoding: .utf8) else { return }
        let deltas = parseAnthropicSSEEvent(event)
        for delta in deltas where !delta.isEmpty {
            continuation.yield(delta)
        }
    }
}

// MARK: - Private DTOs

private struct AnthropicMessageDTO: Codable {
    let role: String
    let content: String
}

private struct AnthropicRequestBody: Codable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessageDTO]
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
    }
}

private struct AnthropicResponse: Codable {
    let content: [ContentBlock]

    struct ContentBlock: Codable {
        let type: String
        let text: String
    }
}

// MARK: - Tool-calling DTOs

private struct AnthropicToolsRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessageDTO]
    let stream: Bool
    let tools: [AnthropicToolDTO]

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
        case tools
    }
}

private struct AnthropicToolDTO: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    private enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

private struct AnthropicToolsResponse: Decodable {
    let content: [ContentBlock]
    let stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    /// text 块只有 `text`;tool_use 块有 `id`/`name`/`input`(对象)。各字段按块类型可空。
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }
}
