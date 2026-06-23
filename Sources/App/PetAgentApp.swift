import AppKit
import Darwin
import Foundation
import Orchestrator
import ToolMode

private final class LaunchStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: OpenPetAgentApp.LaunchState?

    func set(_ value: OpenPetAgentApp.LaunchState) {
        lock.lock()
        defer { lock.unlock() }
        state = value
    }

    func get() -> OpenPetAgentApp.LaunchState? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

private final class LLMBoxBox: @unchecked Sendable {
    private let lock = NSLock()
    private var box: LLMProviderBox?

    func set(_ value: LLMProviderBox) {
        lock.lock()
        defer { lock.unlock() }
        box = value
    }

    func get() -> LLMProviderBox? {
        lock.lock()
        defer { lock.unlock() }
        return box
    }
}

private final class LiveContextBoxBox: @unchecked Sendable {
    private let lock = NSLock()
    private var box: LiveContextBox?

    func set(_ value: LiveContextBox) {
        lock.lock()
        defer { lock.unlock() }
        box = value
    }

    func get() -> LiveContextBox? {
        lock.lock()
        defer { lock.unlock() }
        return box
    }
}

/// N2.3 — 工具层路由器的共享 holder。`MinimalAppDelegate` 在 `init` 时
/// 创建 `ToolModeRouter` 并写入 holder; `ToolModeBox` 在 Orchestrator 那
/// 边通过 `routerProvider` 闭包 (运行在 `@MainActor`) 把 router 拉出来读。
/// 这样既解决"orchestrator 比 delegate 先创建"的鸡生蛋, 也保证 router
/// 切 engine 后 (`router.setEngine(...)`) 下一次 `replyStream` 立刻看见
/// 新状态, 无需重建 Orchestrator。
public final class ToolModeRouterHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var router: ToolModeRouter?

    public init() {}

    /// 由 `MinimalAppDelegate.init` 注入 router 引用。仅 `@MainActor` 调用
    /// (router 自身是 MainActor 隔离类型), 锁只是防止 read 越过 write barrier。
    @MainActor
    public func set(_ value: ToolModeRouter?) {
        lock.lock()
        defer { lock.unlock() }
        router = value
    }

    /// 由 `ToolModeBox.routerProvider` 在 `@MainActor` 闭包里调用。
    @MainActor
    public func get() -> ToolModeRouter? {
        lock.lock()
        defer { lock.unlock() }
        return router
    }
}

@main
enum OpenPetAgentApp {
    enum LaunchState: Equatable {
        case ready(AppRootSystem)
        case failed(String)
    }

    static let bootstrapFailureExitCode: Int32 = 1
    @MainActor private static var retainedDelegate: NSApplicationDelegate?

    @MainActor
    static func main() {
        // We are on the real main thread here. Sample the initial snapshot
        // synchronously while we still own main, then offload the rest of the
        // async bootstrap to a detached Task so NSApplication.run() later
        // enters a clean main thread with no Swift concurrency Task owning it.
        let sampler = AppBootstrap.makeLiveSnapshotSampler()
        let initialSnapshot = sampler.sample()
        let userDefaults = UserDefaults.standard

        let stateBox = LaunchStateBox()
        let llmBoxBox = LLMBoxBox()
        let liveContextBoxBox = LiveContextBoxBox()
        // N2.3 — 工具层路由 holder。bootstrap 时构造空 ToolModeBox 闭包指
        // 向它; `MinimalAppDelegate.init` 后续注入实际 router 引用,
        // Orchestrator 的 `replyStream` 通过 holder 拿到当前 engine。
        let toolModeRouterHolder = ToolModeRouterHolder()
        let toolModeBox = ToolModeBox { toolModeRouterHolder.get() }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let result: LaunchState
            do {
                let bootstrap = AppBootstrap(
                    userDefaults: userDefaults,
                    snapshot: initialSnapshot,
                    snapshotSampler: sampler,
                    toolModeBox: toolModeBox
                )
                llmBoxBox.set(bootstrap.llmProviderBox)
                liveContextBoxBox.set(bootstrap.liveContextBox)
                let rootSystem = try await bootstrap.makeRootSystem()
                result = .ready(rootSystem)
            } catch {
                result = .failed("Failed to bootstrap OpenPetAgent: \(error.localizedDescription)")
            }
            stateBox.set(result)
            semaphore.signal()
        }
        semaphore.wait()

        let resolvedLLMBox = llmBoxBox.get() ?? LLMProviderBox()
        let resolvedLiveContextBox = liveContextBoxBox.get()
        completeLaunchFlow(
            stateBox.get() ?? .failed("Failed to bootstrap OpenPetAgent: launch state missing"),
            launchReadyApp: { rootSystem in
                launchReadyApp(
                    rootSystem: rootSystem,
                    userDefaults: userDefaults,
                    llmProviderBox: resolvedLLMBox,
                    liveContextBox: resolvedLiveContextBox,
                    toolModeRouterHolder: toolModeRouterHolder
                )
            },
            writeToStandardError: { FileHandle.standardError.write($0) },
            exitProcess: { exit($0) }
        )
    }

    static func runLaunchFlow(
        makeRootSystem: () async throws -> AppRootSystem,
        launchReadyApp: (AppRootSystem) -> Void,
        writeToStandardError: (Data) -> Void,
        exitProcess: (Int32) -> Void
    ) async {
        let launchState = await bootstrapLaunchState(makeRootSystem: makeRootSystem)

        await MainActor.run {
            completeLaunchFlow(
                launchState,
                launchReadyApp: launchReadyApp,
                writeToStandardError: writeToStandardError,
                exitProcess: exitProcess
            )
        }
    }

    @MainActor
    static func completeLaunchFlow(
        _ launchState: LaunchState,
        launchReadyApp: (AppRootSystem) -> Void,
        writeToStandardError: (Data) -> Void,
        exitProcess: (Int32) -> Void
    ) {
        switch launchState {
        case let .ready(rootSystem):
            launchReadyApp(rootSystem)
        case let .failed(message):
            let exitCode = reportLaunchFailure(message, writeToStandardError: writeToStandardError)
            exitProcess(exitCode)
        }
    }

    @MainActor
    static func launchReadyApp(
        rootSystem: AppRootSystem,
        userDefaults: UserDefaults = .standard,
        llmProviderBox: LLMProviderBox = LLMProviderBox(),
        liveContextBox: LiveContextBox? = nil,
        toolModeRouterHolder: ToolModeRouterHolder? = nil,
        setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void = { policy in
            NSApplication.shared.setActivationPolicy(policy)
        },
        installDelegate: @MainActor (NSApplicationDelegate) -> Void = { delegate in
            NSApplication.shared.delegate = delegate
        },
        makeDelegate: (@MainActor (AppRootSystem) -> NSApplicationDelegate)? = nil,
        runApplication: @MainActor (NSApplicationDelegate) -> Void = { _ in
            NSApplication.shared.finishLaunching()
            NSApplication.shared.run()
        }
    ) {
        let resolvedMakeDelegate = makeDelegate ?? { rs in
            MinimalAppDelegate(
                rootSystem: rs,
                userDefaults: userDefaults,
                llmProviderBox: llmProviderBox,
                liveContextBox: liveContextBox,
                toolModeRouterHolder: toolModeRouterHolder
            )
        }
        let delegate = resolvedMakeDelegate(rootSystem)
        retainedDelegate = delegate
        setActivationPolicy(.accessory)
        installDelegate(delegate)
        runApplication(delegate)
    }

    static func bootstrapLaunchState(
        makeRootSystem: () async throws -> AppRootSystem = { try await AppBootstrap().makeRootSystem() }
    ) async -> LaunchState {
        do {
            return .ready(try await makeRootSystem())
        } catch {
            return .failed("Failed to bootstrap OpenPetAgent: \(error.localizedDescription)")
        }
    }

    static func reportLaunchFailure(
        _ message: String,
        writeToStandardError: (Data) -> Void = { FileHandle.standardError.write($0) }
    ) -> Int32 {
        writeToStandardError(Data("\(message)\n".utf8))
        return bootstrapFailureExitCode
    }
}
