import Foundation

/// 钉住的会话引用(持久化进 UserDefaults)。
/// 用**稳定文件路径**作加载 + re-stat 源(非「最近活跃」易失窗口)。
/// 放在 AgentSensing 模块，使 `SessionDirectoryBrowser`(T3) 可直接使用，无需引用 Shell。
public struct PinnedSessionRef: Codable, Equatable, Sendable {
    public let agent: AgentKind
    public let sessionId: String
    /// transcript jsonl 绝对路径(稳定)，文件被删仍保留路径供 UI 展示"文件已删除"。
    public let filePath: String
    /// 钉住时缓存的标题(文件后续被删仍可显)。
    public let title: String?
    public let gitBranch: String?
    public let pinnedAt: Date

    public init(
        agent: AgentKind,
        sessionId: String,
        filePath: String,
        title: String?,
        gitBranch: String?,
        pinnedAt: Date
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.filePath = filePath
        self.title = title
        self.gitBranch = gitBranch
        self.pinnedAt = pinnedAt
    }
}
