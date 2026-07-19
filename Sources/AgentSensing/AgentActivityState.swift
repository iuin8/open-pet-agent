import Foundation

/// 一个会话的高层活动状态 —— 桌宠情绪映射的中间层(感知层不认识 pet 类型,
/// App/Shell 接线层把它翻成 `PetEmotionState`)。
///
/// 映射建议(在接线层做,非本 target 职责):
/// - `.working`  → 桌宠 `.thinking`(专注/忙)
/// - `.talking`  → 桌宠 `.talking`
/// - `.awaitingUser` → 桌宠 `.watching`(抬头看你)+ 一次性 `.acknowledge` 提醒
/// - `.idle`     → 桌宠 `.idle`(+ 刚从忙转 idle 时 `.celebrate` 庆祝完成)
public enum AgentActivityState: String, Sendable, Equatable {
    case working
    case talking
    case awaitingUser
    case idle
}

extension AgentEvent {
    /// 这条事件把会话推向哪个高层状态。`nil` = 不改变当前状态(如 sessionStart)。
    public var impliedState: AgentActivityState? {
        switch kind {
        case .toolUse, .toolResult, .userPrompt:
            return .working
        case .assistantText, .thinking:
            return .talking   // 思考也算「在产出」(模型在想)→ 同 assistantText
        case .awaitingUser:
            return .awaitingUser
        case .done:
            return .idle
        case .sessionStart, .interrupted, .systemNotice, .compactBoundary:
            return nil   // 中断/系统通知/压缩边界不改活动状态(尤其别误判 →idle 触发「庆祝」招牌动作)
        }
    }
}

/// 把一串事件折叠成「每个会话当前状态」,并识别状态跃迁(用来触发一次性反应,
/// 如 working→idle 时让桌宠庆祝)。纯值类型,无副作用,好无头单测。
public struct AgentActivityTracker: Sendable {
    /// sessionId → 当前状态。
    public private(set) var states: [String: AgentActivityState] = [:]

    public init() {}

    /// 一次状态跃迁的描述(供接线层决定要不要触发一次性反应)。
    public struct Transition: Sendable, Equatable {
        public let sessionId: String
        public let from: AgentActivityState?
        public let to: AgentActivityState
    }

    /// 吃一条事件,更新对应会话状态;若状态真的变了,返回这次跃迁,否则 `nil`。
    public mutating func ingest(_ event: AgentEvent) -> Transition? {
        guard let next = event.impliedState else { return nil }
        let prev = states[event.sessionId]
        guard prev != next else { return nil }
        states[event.sessionId] = next
        return Transition(sessionId: event.sessionId, from: prev, to: next)
    }

    /// 当前是否有任一会话在等用户(供桌宠决定要不要保持「看你」)。
    public var anyAwaitingUser: Bool {
        states.values.contains(.awaitingUser)
    }

    /// 当前是否有任一会话在忙(working / talking)。
    public var anyActive: Bool {
        states.values.contains { $0 == .working || $0 == .talking }
    }
}
