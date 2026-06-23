import Foundation

/// 一个被发现的活跃 agent 会话的引用 —— 哪个 agent、稳定 sessionId(文件名去后缀)、transcript 文件 URL。
/// 会话切换 picker 用它把 store 里的 sessionId 映射回文件 URL 去拉历史。纯值类型、Sendable。
public struct AgentSessionRef: Sendable, Equatable, Identifiable {
    public let agent: AgentKind
    public let sessionId: String
    public let url: URL

    public var id: String { sessionId }

    public init(agent: AgentKind, sessionId: String, url: URL) {
        self.agent = agent
        self.sessionId = sessionId
        self.url = url
    }
}
