import Foundation

/// 子进程测试开关。`CodexEngine`/`ClaudeCodeEngine` 的 `run()` 测试 spawn stub 子进程，
/// 其 EOF/AsyncStream 收尾有竞态，某些时序下 stream 永不 finish → 测试无限挂死、拖垮
/// `swift test` 全套（2026-06-04 实测烧 131 分钟 CPU）。默认**跳过**这些测试，只在
/// 显式 `PETAGENT_SUBPROCESS_TESTS=1 swift test` 时运行。根治（给读流加硬超时）见 B。
///
/// 用法：`@Test("…", .enabled(if: subprocessTestsEnabled))`。条件为假时报告为 skipped。
let subprocessTestsEnabled = ProcessInfo.processInfo.environment["PETAGENT_SUBPROCESS_TESTS"] == "1"
