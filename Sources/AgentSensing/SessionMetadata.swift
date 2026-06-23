import Foundation

/// 一个会话文件的轻量元数据 —— 供陪伴卡片 picker 区分同项目多会话(P3.8 G3)。
///
/// 纯值类型、Sendable。由 `SessionMetadataScanner` 扫 transcript 头/尾抽出(成本受控,不全读 GB 文件)。
public struct SessionMetadata: Sendable, Equatable {
    /// 人话标题:优先 Claude Code 自写的 `ai-title`(尾部最新值),回退首条真实 user 消息。取不到 → nil。
    public let title: String?
    /// 项目名(头部首条带 cwd 事件的目录末段)。logs 取不到时给 picker 兜底标签。
    public let projectName: String?
    /// 会话起始时间(头部首条事件 timestamp)。
    public let startTime: Date?
    /// git 分支(头部 `"gitBranch"` 字段;Codex / 无该字段 → nil)。同项目多会话的关键消歧位。
    public let gitBranch: String?
    /// 消息数(user+assistant 记录数)。文件超扫描预算 → nil(避免 GB 级全读;picker 此时靠 标题+分支+时间 区分)。
    public let messageCount: Int?
    /// **上下文窗口占用 token**(P3.8 F,参考 claude-devtools):尾部最新 assistant `usage` 的
    /// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`(= 该轮喂给模型的总 token)。
    /// Codex / 取不到 → nil。配 `contextWindowLimit` 算占用百分比。
    public let contextTokens: Int?
    /// 文件最后修改时间(picker 相对时间 + 活跃标识用)。
    public let lastModified: Date

    /// 默认上下文窗口上限(Claude 系列 200k;1M 模型另算,暂统一 200k)。
    public static let contextWindowLimit = 200_000

    public init(
        title: String?,
        projectName: String?,
        startTime: Date?,
        gitBranch: String?,
        messageCount: Int?,
        contextTokens: Int? = nil,
        lastModified: Date
    ) {
        self.title = title
        self.projectName = projectName
        self.startTime = startTime
        self.gitBranch = gitBranch
        self.messageCount = messageCount
        self.contextTokens = contextTokens
        self.lastModified = lastModified
    }
}
