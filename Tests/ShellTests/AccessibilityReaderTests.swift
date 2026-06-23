import AppKit
import Testing
@testable import Shell

/// AccessibilityReader 主要逻辑依赖系统状态 (前台 app / focused element /
/// 选中文本 / pasteboard / AX 权限), 在 swift test 环境里:
///   - 测试进程通常无前台窗口, AX 直读拿不到 focused element
///   - ⌘C fallback 会 post CGEvent 到 hid event tap, 但无目标 app 接收
///   - pasteboard `changeCount` 不会改变 → fallback 返回 nil
/// 所以本套测试只验证 "API 形状 + 不崩溃 + nil-safe 行为"。
/// 真实路径覆盖需要走集成测试 / 手动 QA。
@MainActor
@Suite("AccessibilityReader — 系统选中文本读取")
struct AccessibilityReaderTests {

    @Test("readSelectedText 在测试环境调用不崩, 返回 nil 或 String 均合法")
    func readSelectedTextDoesNotCrash() {
        // 测试进程通常没有有效 focused element, 预期 nil。
        // 但 macOS 可能在不同 CI / 本地环境给出不一致结果 (比如 Xcode 本身
        // 是前台 app 时), 所以只断言 "调用完成 + 类型正确"。
        let result = AccessibilityReader.readSelectedText()
        // result 可能是 nil 或非空 String; 不做内容断言。
        if let text = result {
            #expect(!text.isEmpty)
            // 显式语义: 若返回非 nil, 必非空 (readSelectedText 内部
            // 已过滤 isEmpty)。
        }
    }

    @Test("多次调用幂等 — 每次都安全返回")
    func repeatedCallsAreSafe() {
        // 主要担心 pasteboard 恢复路径有泄露 / 状态污染, 多调几次验证
        // 不会越调越糟。
        for _ in 0..<3 {
            _ = AccessibilityReader.readSelectedText()
        }
        // 没崩 = pass。
    }

    @Test("readSelectedText 是 static, 不持有状态")
    func readSelectedTextIsStateless() {
        // 通过 enum 实现, 编译期保证无实例; 这条测试主要是文档化意图。
        // 若有人未来把 AccessibilityReader 改成 class / actor 持有 state,
        // enum 形态会 fail 编译, 这里的引用就提醒注意。
        let fn: () -> String? = AccessibilityReader.readSelectedText
        _ = fn
    }
}
