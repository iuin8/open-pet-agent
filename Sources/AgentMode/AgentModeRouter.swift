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
///
/// P5 @mention 引擎池:`runAgent(prompt:kind:)` 显式指定 kind 时,同 kind 用当前
/// engine,不同 kind 走 per-kind 懒建池(`engineFactory` 由 App 注入,构建时完成
/// 回调 wiring)。池引擎首跑前经 `preparePooledEngine` 一次性恢复持久会话指针,
/// 之后复用自己的 ACP session(各引擎私有 session,互不串上下文)。
@MainActor
public final class AgentModeRouter {

    /// 当前选中的工具 engine(由 UserDefaults["tool.engine.kind"] 持久化)。
    /// `nil` = 用户未启用工具层(默认),所有 prompt 都走灵魂层 LLM。
    public private(set) var currentEngine: (any AgentEngine)?

    /// 当前 engine kind(便于 UI 反查 / UserDefaults 持久化)。
    /// 通过 `setEngine` 时由实例的 static `kind` 反推记录,避免运行时 Mirror 反射。
    public private(set) var currentKind: AgentEngineKind?

    /// P5:@mention 池。key = engine kind;value = 懒建的 engine(各持子进程/session)。
    private var pooledEngines: [AgentEngineKind: any AgentEngine] = [:]
    /// P5:已完成首跑前准备(持久指针恢复)的池 kind,防每个 run 重复 loadSession。
    private var preparedKinds: Set<AgentEngineKind> = []

    /// P5:per-kind 懒建工厂(App 注入:构建 engine + 完成权限/思考/用量/指针回调
    /// wiring)。返回 nil = 该 kind 不可池化 → `engine(for:)` nil → @mention 判不可用。
    public var engineFactory: ((AgentEngineKind) -> (any AgentEngine)?)?

    /// P5:池引擎**首跑前**一次性准备(App 注入:按持久指针 `loadSession` 恢复会话,
    /// 回放丢弃只要把 session 置为当前;指针失效由 App 清除,首 run 开新会话)。
    public var preparePooledEngine: ((AgentEngineKind, any AgentEngine) async -> Void)?

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

    /// P5:取某 kind 的可用 engine —— 当前 engine 同 kind 直接用(接线/恢复 App 已做);
    /// 否则池缓存命中返回,未命中经 `engineFactory` 懒建入池。
    public func engine(for kind: AgentEngineKind) -> (any AgentEngine)? {
        if currentKind == kind, let currentEngine { return currentEngine }
        if let pooled = pooledEngines[kind] { return pooled }
        guard let engine = engineFactory?(kind) else { return nil }
        pooledEngines[kind] = engine
        return engine
    }

    /// P5:已池化的 engine(不触发懒建)。App 切默认引擎时优先收养池内实例,避免同
    /// kind 双开子进程 / 双会话。
    public func existingPooledEngine(for kind: AgentEngineKind) -> (any AgentEngine)? {
        pooledEngines[kind]
    }

    /// P5:项目切换等 cwd 变化 → 池内 engine(旧 cwd 子进程 + 旧会话桶)全部失效,
    /// 清池(deinit 各自 shutdown 子进程);再次 @mention 时经工厂按新 cwd 重建。
    public func clearPooledEngines() {
        pooledEngines.removeAll()
        preparedKinds.removeAll()
    }

    /// 用 prompt 跑一次工具任务。无 engine 时返回的 stream 立即
    /// throw `AgentEngineError.notImplemented`。
    ///
    /// P5:`kind` 显式指定(@mention 路由)→ 跑该 kind 的 engine(当前或池);池引擎
    /// 首跑前等 `preparePooledEngine` 一次性恢复会话。`kind == nil` → 当前默认 engine。
    /// P7.2:`images` 透传 engine(ACP image content block;非 ACP engine 默认降级忽略)。
    public func runAgent(
        prompt: String,
        kind: AgentEngineKind? = nil,
        images: [ChatImage] = []
    ) -> AsyncThrowingStream<String, Error> {
        guard let kind else {
            guard let engine = currentEngine else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: AgentEngineError.notImplemented(.claudeCode))
                }
            }
            return engine.run(prompt: prompt, images: images)
        }
        guard let engine = engine(for: kind) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AgentEngineError.notImplemented(kind))
            }
        }
        // 当前 engine 同 kind:直接跑(接线/会话恢复 App 在切 engine 时已完成)。
        if currentKind == kind { return engine.run(prompt: prompt, images: images) }
        // 池引擎:首跑前一次性准备(持久指针 → loadSession 恢复),再转发流。
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                if !self.preparedKinds.contains(kind) {
                    self.preparedKinds.insert(kind)
                    await self.preparePooledEngine?(kind, engine)
                }
                do {
                    for try await delta in engine.run(prompt: prompt, images: images) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// P7.2 能力门闸:某 kind engine 的 ACP `promptCapabilities.image`(initialize 协商)。
    /// 池引擎未准备先 `preparePooledEngine`(与 runAgent 同款一次性,防门闸先于首跑);
    /// engine 非 ACP / 协商失败(prepare 抛错、子进程起不来)→ false(不静默丢图)。
    public func supportsImagePrompt(kind: AgentEngineKind) async -> Bool {
        guard let engine = engine(for: kind) else { return false }
        if currentKind != kind, !preparedKinds.contains(kind) {
            preparedKinds.insert(kind)
            await preparePooledEngine?(kind, engine)
        }
        guard let acp = engine as? ACPAgentEngine else { return false }
        do {
            return try await acp.ensureReady().promptCapabilities.contains(.image)
        } catch {
            return false
        }
    }

    /// engine 是否已设置 + 可用(async,因为 `AgentEngine.isAvailable` 是 async)。
    public func isReady() async -> Bool {
        guard let engine = currentEngine else { return false }
        return await engine.isAvailable
    }
}
