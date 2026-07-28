import Foundation
import AgentMode

/// Orchestrator 访问工具层 (Tool Mode) 路由器的桥 —— 与 `LLMProviderBox`
/// 同构, 用于在非 `@MainActor` 的 `CompanionOrchestrator` 里安全拿到
/// `@MainActor` 隔离的 `AgentModeRouter` 状态。
///
/// 为什么不直接传 `AgentModeRouter`:
/// - `AgentModeRouter` 是 `@MainActor final class` (Shell 层 / UI 层使用),
///   `CompanionOrchestrator` 是 `Sendable struct` 不带 actor 隔离, 直接同
///   步访问编译不过。
/// - Box 用 `MainActor.run` hop 一下就能跨边界, 调用方写起来像调普通
///   `async` 方法, 不必感知 router 的隔离细节。
///
/// 生命周期 / 所有权:
/// - Router 由 `MinimalAppDelegate` 持有 (跟 LLMProvider 同款), Box 只
///   通过 `routerProvider` 闭包动态拿引用 —— Box 不 own router, Box 释放
///   不会影响 router 生命周期。
/// - 闭包写成 `() -> AgentModeRouter?` 形式而非 stored reference, 是为了
///   保证 router 切换 engine 后 (`router.setEngine(...)`) Orchestrator
///   下一次 `replyStream` 立刻看见新状态, 不需要重建 Orchestrator。
///
/// 默认 init 给空闭包, 兼容现有 `CompanionOrchestrator()` 无参 init
/// —— 没接 Tool Mode 的代码路径行为完全不变 (isAgentModeEnabled = false
/// → 走 LLM 灵魂层)。
public final class AgentModeBox: @unchecked Sendable {
    /// 拉取当前 router 的闭包。返回 nil 表示工具层根本没接 (例如测试
    /// 环境 / `MinimalAppDelegate` 还没 wire), Orchestrator 把它当成
    /// "工具层未启用" 处理。
    private let routerProvider: @MainActor () -> AgentModeRouter?

    public init(routerProvider: @escaping @MainActor () -> AgentModeRouter? = { nil }) {
        self.routerProvider = routerProvider
    }

    /// 当前 engine kind。
    /// - nil = router 不存在 / 没注册 engine (工具层关闭)
    /// - non-nil = router 注册了一个 engine, 比如 `.claudeCode`
    public var currentEngineKind: AgentEngineKind? {
        get async {
            await MainActor.run {
                self.routerProvider()?.currentKind
            }
        }
    }

    /// 工具层是否启用 —— Orchestrator 的 `replyStream` 用这个判断走
    /// LLM 灵魂层还是 AgentEngine 子进程层。
    ///
    /// 启用 = router 存在 + engine 非 nil。两个条件少一个就走灵魂层。
    public var isAgentModeEnabled: Bool {
        get async {
            await MainActor.run {
                self.routerProvider()?.currentEngine != nil
            }
        }
    }

    /// P5:某 kind 的 engine 是否可跑(@mention 预检):router 能拿到(当前/池/工厂懒建)
    /// 且 CLI 可用。注意 `engine(for:)` 有懒建副作用 —— 预检通过即完成池化,后续
    /// `runAgent(kind:)` 直接用同一实例。
    public func canRunAgent(kind: AgentEngineKind) async -> Bool {
        guard let engine = await MainActor.run(body: { self.routerProvider()?.engine(for: kind) }) else {
            return false
        }
        return await engine.isAvailable
    }

    /// 跑一次工具任务, 返回流式 delta token 的 stream。
    ///
    /// 无 router / 无 engine 时 stream 立即 finish 抛 `AgentEngineError
    /// .notImplemented(.claudeCode)` —— 调用方 (`CompanionOrchestrator
    /// .replyStream`) 看到 throw 应当走 LLM fallback 而非把错误透传给
    /// 用户 (`isAgentModeEnabled` 应该先判, 这里只是 belt-and-suspenders)。
    ///
    /// P5:`kind` 显式指定(@mention)→ 透传 router 路由到该 kind 的 engine。
    /// P7.2:`images` 透传(ACP image content block 管线)。
    ///
    /// 内部用 outer-stream 包了一层 inner-stream 是为了:
    /// 1. 跨 actor 把 MainActor 的 router stream 桥到非 actor 的调用方
    /// 2. 调用方取消 outer stream 时也能传播到 router 的子进程 (router
    ///    的 onTermination 会 SIGTERM 子进程)
    public func runAgent(
        prompt: String,
        kind: AgentEngineKind? = nil,
        images: [ChatImage] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let router = self.routerProvider(),
                      kind != nil || router.currentEngine != nil else {
                    continuation.finish(throwing: AgentEngineError.notImplemented(kind ?? .claudeCode))
                    return
                }
                do {
                    for try await delta in router.runAgent(prompt: prompt, kind: kind, images: images) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
