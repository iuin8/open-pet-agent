import Foundation

/// A single turn in a conversation (user, assistant, or system).
public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let role: LLMRole
    public let content: String
    public let timestamp: Date
    /// Model that produced this message; nil for user messages or when unknown.
    public let model: String?

    public init(
        id: UUID = UUID(),
        role: LLMRole,
        content: String,
        timestamp: Date = Date(),
        model: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
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
