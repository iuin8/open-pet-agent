import Foundation

/// 灵魂层(自然对话)/ 工具层(让 pet 干活)的意图分流路由。
///
/// MVP:**手动选择型路由** —— 由 UI 显式标记 prompt 是"自然聊天"还是"工具
/// 任务",router 按用户选择走 LLM 灵魂层或 `AgentEngine` 工具层。后续
/// (N2.x 之后)可以接入 LLM 意图判定模型实现"自动路由"。
///
/// N2.0 阶段 router 不真持有 LLM provider(那是 `Orchestrator` 职责),
/// 只维护"当前选中的 tool engine 实例"。灵魂层 / 工具层完整 wire 由
/// `Orchestrator` / `Shell` 在 N2.1+ 接入时做。
@MainActor
public final class AgentModeRouter {

    /// 当前选中的工具 engine(由 UserDefaults["tool.engine.kind"] 持久化)。
    /// `nil` = 用户未启用工具层(默认),所有 prompt 都走灵魂层 LLM。
    public private(set) var currentEngine: (any AgentEngine)?

    /// 当前 engine kind(便于 UI 反查 / UserDefaults 持久化)。
    /// 通过 `setEngine` 时由实例的 static `kind` 反推记录,避免运行时 Mirror 反射。
    public private(set) var currentKind: AgentEngineKind?

    public init() {}

    /// 显式切换工具 engine。传 `nil` = 关闭工具层。
    ///
    /// 接受 `any AgentEngine`(而非旧的泛型 `E`),好让 `AgentEngineRegistry
    /// .makeEngine` 这种返回存在类型的注册表能直接喂进来;`kind` 由实例的
    /// 静态需求 `type(of:).kind` 反推(协议带 `static var kind`,存在类型的
    /// 元类型 `any AgentEngine.Type` 可访问静态成员),不再依赖编译期具体类型。
    public func setEngine(_ engine: (any AgentEngine)?) {
        currentEngine = engine
        currentKind = engine.map { type(of: $0).kind }
    }

    /// 用 prompt 跑一次工具任务。无 engine 时返回的 stream 立即
    /// throw `AgentEngineError.notImplemented(.claudeCode)`(代表默认
    /// fallback engine 还没接入)。
    public func runAgent(prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let engine = currentEngine else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AgentEngineError.notImplemented(.claudeCode))
            }
        }
        return engine.run(prompt: prompt)
    }

    /// engine 是否已设置 + 可用(async,因为 `AgentEngine.isAvailable` 是 async)。
    public func isReady() async -> Bool {
        guard let engine = currentEngine else { return false }
        return await engine.isAvailable
    }
}
