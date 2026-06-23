import AgentSensing
import Foundation

/// 浏览出的一条会话：`ref`(含文件路径)供加载，`summary` 供 sheet/picker 渲染。
/// `AgentSessionSummary` 本身不带文件 URL，故需组合 ref 一起传递。
/// 放在 Shell 模块，与 `AgentSessionSummary` 同层，避免跨模块方向问题。
public struct BrowsedSession: Identifiable, Equatable, Sendable {
    public let ref: AgentSessionRef
    public let summary: AgentSessionSummary

    public var id: String { ref.sessionId }

    public init(ref: AgentSessionRef, summary: AgentSessionSummary) {
        self.ref = ref
        self.summary = summary
    }
}
