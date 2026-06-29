import Foundation

/// 跟踪所有 OpenPetAgent 工具层 spawn 的 active 子进程。app 退出时统一 SIGTERM
/// 收口,避免孤儿进程在后台继续烧 token。
///
/// 设计:
/// - actor 单例 `shared` — 全进程一份,跨 `AgentEngine` 实例共享
/// - `register(_:)` 在 `Process.run()` 成功后立即调,挂到 active set
/// - `unregister(_:)` 在 `waitUntilExit` 之后(或子进程结束兜底处)调,从 set 移除
/// - `terminateAll()` app 退出时调,遍历 active set 发 SIGTERM
///
/// 为什么用 actor 而非 `@MainActor class`:
/// 子进程 spawn / `waitUntilExit` 不一定在主 actor,registry 操作要 thread-safe;
/// actor isolation 比 NSLock 写起来干净。
///
/// 为什么持有 strong reference 而非 `NSHashTable.weakObjects`:
/// `Process` 在 Foundation 里没有非平凡的弱引用语义保证,而且如果 weak ref 被
/// 提前回收,我们就没法在 app 退出时 `terminate()` 它了。registry 持 strong ref,
/// 由 caller 显式 `unregister` 释放;万一漏调,最差只是 process 引用多挂一会儿
/// 直到 app 退出,不会泄漏长期内存。
public actor SubprocessRegistry {

    /// 进程单例。
    public static let shared = SubprocessRegistry()

    /// 当前活跃的子进程集合。
    /// `ObjectIdentifier` 作为 key 避免要求 `Process` 实现 `Hashable`。
    private var refs: [ObjectIdentifier: Process] = [:]

    /// internal init — 测试用,避免 parallel test 共用 `.shared` 互相污染。
    /// 生产代码统一通过 `.shared` 访问。
    internal init() {}

    /// 把一个 spawned `Process` 注册到活跃集合。`Process.run()` 成功后立即调。
    public func register(_ process: Process) {
        let id = ObjectIdentifier(process)
        refs[id] = process
    }

    /// 子进程 `waitUntilExit` 之后调,从活跃集合移除。
    public func unregister(_ process: Process) {
        let id = ObjectIdentifier(process)
        refs.removeValue(forKey: id)
    }

    /// 当前活跃子进程数(测试访问)。
    public var activeCount: Int { refs.count }

    /// 遍历所有活跃子进程发 SIGTERM。app 退出时
    /// (`NSApplicationDelegate.applicationWillTerminate(_:)`)调一次。
    /// 不阻塞 — 不等子进程退出,SIGTERM 是 best-effort。
    public func terminateAll() {
        let toKill = Array(refs.values)
        refs.removeAll()
        for process in toKill where process.isRunning {
            process.terminate()
        }
    }
}
