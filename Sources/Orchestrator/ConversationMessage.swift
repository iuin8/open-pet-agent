import Foundation
import AgentMode

/// P7.2:跨模块图片类型的唯一事实源在 AgentMode(ACP prompt 管线同型);Orchestrator
/// 再导出 —— Shell 聊天区保持「不 import AgentMode」的惯例,只 `import Orchestrator` 即可用,
/// 全链路同一名词类型,零映射样板。
public typealias ChatImage = AgentMode.ChatImage

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
    /// P7.2:随消息内联的图片(用户粘贴的附件;**结构化字段,不进 content 文本**)。
    /// Codable 可选:旧 JSON 无此键解码为 nil,零迁移;Data 自动 base64。
    public let images: [ChatImage]?

    public init(
        id: UUID = UUID(),
        role: LLMRole,
        content: String,
        timestamp: Date = Date(),
        model: String? = nil,
        source: String? = nil,
        images: [ChatImage]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
        self.source = source
        self.images = images
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
