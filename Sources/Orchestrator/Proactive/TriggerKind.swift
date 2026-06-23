// Sources/Orchestrator/Proactive/TriggerKind.swift
import Foundation

/// 主动建议的触发场景类型。`displayName` 作为头顶 context 标签气泡的文本。
public enum TriggerKind: String, Sendable, Equatable, CaseIterable {
    case appSwitch
    case idleReturn
    case dwell
    case lateNight
    /// 第 1 层：生命感预设短语（无 LLM，引擎自己的轻节奏）。
    case chatter
    /// 第 2 层：LLM 自主闲聊（复用 throttle 配额）。
    case autonomous

    /// context 标签气泡显示用中文（让用户一眼知道 pet 为什么主动开口）。
    public var displayName: String {
        switch self {
        case .appSwitch: return "应用切换"
        case .idleReturn: return "久未活动"
        case .dwell: return "专注中"
        case .lateNight: return "深夜"
        case .chatter: return "碎碎念"
        case .autonomous: return "主动关心"
        }
    }
}

/// 一次触发候选的原始信号。由 `ProactiveSuggestionEngine` 从桌面快照构造，
/// 喂给 `ProactiveTriggerEvaluator`（判定）与 `ProactivePromptComposer`（组词）。
/// 纯值类型，不依赖 AppKit / snapshot 语义 → 纯逻辑层可独立单测。
public struct ProactiveSignal: Sendable, Equatable {
    public let kind: TriggerKind
    public let appName: String?
    public let windowTitle: String?
    public let awaySeconds: TimeInterval?
    public let dwellSeconds: TimeInterval?

    public init(
        kind: TriggerKind,
        appName: String? = nil,
        windowTitle: String? = nil,
        awaySeconds: TimeInterval? = nil,
        dwellSeconds: TimeInterval? = nil
    ) {
        self.kind = kind
        self.appName = appName
        self.windowTitle = windowTitle
        self.awaySeconds = awaySeconds
        self.dwellSeconds = dwellSeconds
    }
}
