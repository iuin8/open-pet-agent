import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("QuickAskHotkey — ⌘⇧Space 全局快问热键")
struct QuickAskHotkeyTests {

    // MARK: - Combo 形状

    @Test("默认 combo 是 ⌘⇧Space (keyCode 49 + Command|Shift)")
    func defaultComboIsCommandShiftSpace() {
        let combo = QuickAskHotkey.Combo.commandShiftSpace
        #expect(combo.keyCode == 49)
        #expect(combo.modifiers == [.command, .shift])
    }

    @Test("Combo Equatable 实现按 keyCode + modifiers 判等")
    func comboEqualityIsStructural() {
        let a = QuickAskHotkey.Combo(keyCode: 49, modifiers: [.command, .shift])
        let b = QuickAskHotkey.Combo(keyCode: 49, modifiers: [.shift, .command])
        let c = QuickAskHotkey.Combo(keyCode: 49, modifiers: [.command])
        #expect(a == b)  // NSEvent.ModifierFlags 是 OptionSet, 顺序不影响判等
        #expect(a != c)
    }

    // MARK: - Lifecycle 幂等

    @Test("init 不自动 start — 必须显式 start")
    func initDoesNotAutoStart() {
        // 仅验证 init 不崩; 没法直接 introspect monitor 状态, 但能确认对象成形。
        let key = QuickAskHotkey { }
        _ = key  // suppress unused warning
    }

    @Test("start / stop 幂等: 反复调用不崩")
    func startStopIdempotent() {
        let key = QuickAskHotkey { }
        key.start()
        key.start()  // 二次 start 走 stop() 清理 + 重新注册, 不应崩
        key.stop()
        key.stop()  // 二次 stop no-op
    }

    @Test("自定义 combo 可以注入 (便于未来用户改键)")
    func customComboInjection() {
        let custom = QuickAskHotkey.Combo(
            keyCode: 0x24,  // kVK_Return
            modifiers: [.control, .option]
        )
        let key = QuickAskHotkey(combo: custom) { }
        _ = key
        // 主要验证 init 接受自定义 combo 不崩; 拦截逻辑是 NSEvent runtime
        // 行为, 单测无法触发, 保留集成测试。
    }
}
