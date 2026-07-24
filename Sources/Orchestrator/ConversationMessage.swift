import Foundation

/// A single turn in a conversation (user, assistant, or system).
public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let role: LLMRole
    public let content: String
    public let timestamp: Date
    /// Model that produced this message; nil for user messages or when unknown.
    public let model: String?
    /// P5:产生这条 assistant 消息的 agent engine(`AgentEngineKind.rawValue`,
    /// @mention 多引擎时间线的署名;nil = 灵魂层 / 用户消息 / 未知)。
    /// Codable 可选:旧 JSON 无此键解码为 nil,零迁移。
    public let source: String?

    public init(
        id: UUID = UUID(),
        role: LLMRole,
        content: String,
        timestamp: Date = Date(),
        model: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
        self.source = source
    }
}

/// Container that wraps all messages for a single conversation session.
/// Not publicly exposed; embedded inside `ConversationStore`.
struct ConversationEnvelope: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    var messages: [ConversationMessage]

    init(id: UUID = UUID(), createdAt: Date = Date(), messages: [ConversationMessage] = []) {
        self.id = id
        self.createdAt = createdAt
        self.messages = messages
    }
}
