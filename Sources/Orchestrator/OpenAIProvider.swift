import Foundation

public actor OpenAIProvider: LLMProvider {
    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Stream client returns a byte stream and response for SSE streaming.
    /// Tests inject a mock returning bytes from a pre-built string; production
    /// uses URLSession.bytes(for:). The byte stream is AsyncThrowingStream<UInt8, Error>
    /// so both test and production can produce it without type-erasure complexity.
    public typealias HTTPStreamClient = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse)

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let httpClient: HTTPClient
    private let httpStreamClient: HTTPStreamClient

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
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
        self.httpClient = httpClient
        self.httpStreamClient = httpStreamClient
    }

    // MARK: - Atomic chat (non-streaming)

    public func chat(_ messages: [LLMMessage]) async throws -> String {
        let requestBody = RequestBody(
            model: model,
            messages: messages.map { MessageDTO(role: $0.role.rawValue, content: $0.content) },
            stream: false
        )
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(requestBody)
        } catch {
            throw LLMProviderError.transportError(error.localizedDescription)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

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

        let completion: CompletionResponse
        do {
            completion = try JSONDecoder().decode(CompletionResponse.self, from: data)
        } catch {
            throw LLMProviderError.decodingFailed(error.localizedDescription)
        }

        guard let first = completion.choices.first else {
            throw LLMProviderError.emptyResponse
        }

        return first.message.content
    }

    // MARK: - Tool-calling chat (non-streaming)

    /// 工具回合(非流式):带 `tools` 发请求,解析 `choices[0].message.tool_calls`
    /// (OpenAI 的 arguments 是 JSON 字符串,二次 parse 成 `JSONValue`)+ `finish_reason`。
    public func chatWithTools(_ messages: [LLMMessage], tools: [LLMToolDef]) async throws -> LLMTurn {
        let requestBody = ToolsRequestBody(
            model: model,
            messages: messages.map { MessageDTO(role: $0.role.rawValue, content: $0.content) },
            stream: false,
            tools: tools.map {
                ToolDTO(type: "function",
                        function: FunctionDTO(name: $0.name, description: $0.description, parameters: $0.parameters))
            },
            toolChoice: tools.isEmpty ? nil : "auto"
        )
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(requestBody)
        } catch {
            throw LLMProviderError.transportError(error.localizedDescription)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

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

        let completion: ToolsCompletionResponse
        do {
            completion = try JSONDecoder().decode(ToolsCompletionResponse.self, from: data)
        } catch {
            throw LLMProviderError.decodingFailed(error.localizedDescription)
        }

        guard let choice = completion.choices.first else {
            throw LLMProviderError.emptyResponse
        }

        let toolCalls: [LLMToolCall] = (choice.message.toolCalls ?? []).map { tc in
            // arguments 是 JSON 串;parse 失败(空串 / 残缺)兜底成空对象,不丢整轮。
            LLMToolCall(id: tc.id, name: tc.function.name,
                        arguments: JSONValue.parse(tc.function.arguments) ?? .object([:]))
        }
        // content 可能为 null(纯工具调用回合)→ 归一成 nil。
        let text = (choice.message.content?.isEmpty == false) ? choice.message.content : nil
        let stopReason = Self.mapFinishReason(choice.finishReason, hasToolCalls: !toolCalls.isEmpty)
        return LLMTurn(text: text, toolCalls: toolCalls, stopReason: stopReason)
    }

    /// 归一 OpenAI `finish_reason` → `LLMStopReason`。
    internal static func mapFinishReason(_ raw: String?, hasToolCalls: Bool) -> LLMStopReason {
        switch raw {
        case "tool_calls": return .toolUse
        case "stop": return .stop
        case "length": return .maxTokens
        default: return hasToolCalls ? .toolUse : .stop
        }
    }

    // MARK: - Streaming chat (SSE)

    // nonisolated: all captured properties are `let` constants (immutable) and
    // Sendable; accessing them from a nonisolated context is safe in Swift 6.
    // The protocol declares streamChat as a regular (non-async) function which
    // requires nonisolated conformance from actor types.
    public nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        // Capture immutable let properties — safe from nonisolated context.
        let capturedApiKey = apiKey
        let capturedModel = model
        let capturedEndpoint = endpoint
        let capturedStreamClient = httpStreamClient

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try Self.buildStreamRequest(
                        apiKey: capturedApiKey,
                        model: capturedModel,
                        endpoint: capturedEndpoint,
                        messages: messages
                    )
                    let (byteStream, response) = try await capturedStreamClient(request)

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: LLMProviderError.httpError(status: http.statusCode, body: ""))
                        return
                    }

                    try await Self.consumeSSEStream(byteStream, continuation: continuation)
                } catch let error as LLMProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMProviderError.transportError(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Internal SSE helpers (testable as internal static)

    /// Build the streaming URLRequest.
    private static func buildStreamRequest(
        apiKey: String,
        model: String,
        endpoint: URL,
        messages: [LLMMessage]
    ) throws -> URLRequest {
        let body = RequestBody(
            model: model,
            messages: messages.map { MessageDTO(role: $0.role.rawValue, content: $0.content) },
            stream: true
        )
        let bodyData = try JSONEncoder().encode(body)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        return request
    }

    /// Consume the raw byte stream, splitting on `\n\n` SSE event boundaries,
    /// and yield individual delta strings into the continuation.
    ///
    /// Buffer is `Data` (raw bytes), **not** `String`. A previous implementation
    /// did `Character(UnicodeScalar(byte))` per byte, which silently corrupted
    /// any multi-byte UTF-8 sequence (中文每字 3 bytes → 一字裂成 3 个独立 latin-1
    /// 字符 → 乱码). Splitting on raw `0x0A 0x0A` bytes and decoding each whole
    /// event with `String(data:encoding: .utf8)` keeps codepoints intact even
    /// when HTTP chunks cut mid-codepoint.
    private static func consumeSSEStream(
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
                if try yieldEvent(from: eventData, continuation: continuation) {
                    continuation.finish()
                    return
                }
            }
        }

        // Flush any remaining bytes (server may close stream without trailing \n\n).
        if !buffer.isEmpty {
            _ = try yieldEvent(from: buffer, continuation: continuation)
        }

        continuation.finish()
    }

    /// Decode one SSE event from `data` (assumed UTF-8), yield its delta
    /// strings, and report whether `[DONE]` was seen (caller should finish).
    private static func yieldEvent(
        from data: Data,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        guard let event = String(data: data, encoding: .utf8) else {
            // Drop undecodable events rather than tearing down the whole stream;
            // a corrupt single event is rare and recoverable, not fatal.
            return false
        }
        if event.contains("data: [DONE]") {
            return true
        }
        let deltas = parseSSEEvent(event)
        for delta in deltas where !delta.isEmpty {
            continuation.yield(delta)
        }
        return false
    }

    /// Parse a single SSE event (text between `\n\n` delimiters) and return
    /// any content delta strings. Returns `[]` for keepalive, DONE, or parse failures.
    ///
    /// An event may contain multiple `data:` lines (unusual but spec-legal).
    internal static func parseSSEEvent(_ event: String) -> [String] {
        var results: [String] = []
        let lines = event.components(separatedBy: "\n")
        for line in lines {
            if let delta = parseSSEDelta(line) {
                results.append(delta)
            }
        }
        return results
    }

    /// Parse a single SSE `data:` line and return the content delta string, or `nil` to skip.
    ///
    /// - Returns: the `delta.content` string (may be empty string `""`),
    ///   or `nil` when the line is a keepalive, `[DONE]` sentinel, non-`data:` prefix,
    ///   malformed JSON, or a role-only chunk with no `content` key.
    internal static func parseSSEDelta(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonText = String(line.dropFirst(6)) // drop "data: "
        guard jsonText != "[DONE]" else { return nil }

        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] else {
            return nil
        }

        return content as? String
    }
}

// MARK: - Private DTOs

private struct MessageDTO: Codable {
    let role: String
    let content: String
}

private struct RequestBody: Codable {
    let model: String
    let messages: [MessageDTO]
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream
    }
}

private struct CompletionResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: MessageContent
    }

    struct MessageContent: Codable {
        let role: String
        let content: String
    }
}

// MARK: - Tool-calling DTOs

private struct ToolsRequestBody: Encodable {
    let model: String
    let messages: [MessageDTO]
    let stream: Bool
    let tools: [ToolDTO]
    let toolChoice: String?

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case toolChoice = "tool_choice"
    }
}

private struct ToolDTO: Encodable {
    let type: String   // 恒 "function"
    let function: FunctionDTO
}

private struct FunctionDTO: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

private struct ToolsCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
        let toolCalls: [ToolCallDTO]?

        private enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDTO: Decodable {
        let id: String
        let function: FunctionCallDTO
    }

    struct FunctionCallDTO: Decodable {
        let name: String
        let arguments: String   // JSON 字符串
    }
}
