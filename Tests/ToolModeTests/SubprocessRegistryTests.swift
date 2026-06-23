import Foundation
import Testing
@testable import ToolMode

// MARK: - SubprocessRegistry 单元测试
//
// 设计目标:
// - 验证 register / unregister / activeCount 基本计数行为
// - 验证 terminateAll 对未启动的 Process 是 no-op(不崩、不抛)
// - 验证 terminateAll 真能杀掉一个真子进程
//
// 关于 .shared 单例污染:
// SubprocessRegistry.shared 跨测试共享,parallel 跑测试会互相干扰。但 Swift
// Testing 默认每个 test 拿自己的 instance(struct/actor 都是 value),我们这里
// 用本地 `SubprocessRegistry()` 私有实例做大部分计数测试,只对 terminateAll
// 真子进程场景用一次单独构造。
//
// 注意:public init 不存在 — 改用 reflection 不优雅,所以我们扩展一个 internal
// init 在测试 target 用 @testable 看。

// 每个 test 用独立 actor 实例,完全隔离 `.shared`,避免 parallel test 串扰。

@Test("SubprocessRegistry 初始 activeCount == 0")
func subprocessRegistryStartsEmpty() async {
    let registry = SubprocessRegistry()
    #expect(await registry.activeCount == 0)
}

@Test("SubprocessRegistry register 增加 activeCount")
func subprocessRegistryRegisterIncrements() async {
    let registry = SubprocessRegistry()

    let p1 = Process()
    let p2 = Process()
    await registry.register(p1)
    #expect(await registry.activeCount == 1)
    await registry.register(p2)
    #expect(await registry.activeCount == 2)
}

@Test("SubprocessRegistry unregister 减少 activeCount")
func subprocessRegistryUnregisterDecrements() async {
    let registry = SubprocessRegistry()

    let p = Process()
    await registry.register(p)
    #expect(await registry.activeCount == 1)
    await registry.unregister(p)
    #expect(await registry.activeCount == 0)
}

@Test("SubprocessRegistry unregister 未注册的 Process 是 no-op")
func subprocessRegistryUnregisterUnknownIsNoOp() async {
    let registry = SubprocessRegistry()

    let p = Process()
    await registry.unregister(p)  // never registered
    #expect(await registry.activeCount == 0)
}

@Test("SubprocessRegistry terminateAll 清空 active set")
func subprocessRegistryTerminateAllClears() async {
    let registry = SubprocessRegistry()

    await registry.register(Process())
    await registry.register(Process())
    #expect(await registry.activeCount == 2)

    await registry.terminateAll()
    #expect(await registry.activeCount == 0)
}

@Test("SubprocessRegistry terminateAll 对未启动 Process 不崩")
func subprocessRegistryTerminateUnstartedNoOp() async {
    let registry = SubprocessRegistry()

    // 未调 run() 的 Process isRunning == false,terminateAll 跳过 terminate
    let p = Process()
    await registry.register(p)
    await registry.terminateAll()
    #expect(p.isRunning == false)
    #expect(await registry.activeCount == 0)
}

@Test("SubprocessRegistry terminateAll 能 SIGTERM 真子进程")
func subprocessRegistryTerminateAllKillsRealProcess() async throws {
    let registry = SubprocessRegistry()

    // spawn 一个 sleep 60 长跑进程
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["60"]
    // 丢掉 stdout/stderr,避免 pipe 未读阻塞
    p.standardOutput = Pipe()
    p.standardError = Pipe()

    try p.run()
    await registry.register(p)
    #expect(p.isRunning == true)
    #expect(await registry.activeCount == 1)

    await registry.terminateAll()

    // SIGTERM 是 async — 给系统至多 2s 让进程退出
    let deadline = Date().addingTimeInterval(2.0)
    while p.isRunning && Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }
    #expect(p.isRunning == false)
}
