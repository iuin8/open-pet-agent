import Testing
@testable import App

/// 右键「设为主宠」交换语义:新宠升主宠;旧主宠若**可同屏**(Shimeji)则降为装饰留屏,否则随替换消失。
/// 纯逻辑单测 `decorativeIDsAfterPromote`(菜单项/回调见 ShellTests.PetShellWindowDecorativeMenuTests)。
@Suite("设为主宠(交换装饰集)")
struct PromoteToPrimaryTests {

    @Test("可同屏旧主宠 → 交换:新主宠出装饰集、旧主宠进装饰集")
    func swapWhenOldCanDecorate() {
        let next = MinimalAppDelegate.decorativeIDsAfterPromote(
            current: ["codex:green"], newPrimary: "codex:green", oldPrimary: "codex:red", oldCanDecorate: true)
        #expect(next == ["codex:red"])
    }

    @Test("旧主宠不可同屏(orb/Live2D)→ 仅移除新主宠,旧主宠不进装饰集(随替换消失)")
    func oldNotDecoratableJustRemovesNew() {
        let next = MinimalAppDelegate.decorativeIDsAfterPromote(
            current: ["codex:green"], newPrimary: "codex:green", oldPrimary: "orb", oldCanDecorate: false)
        #expect(next == [])
    }

    @Test("多只装饰:升其一为主宠,保留其余 + 旧主宠降级补入")
    func keepsOtherDecorativesAndAppendsOldPrimary() {
        let next = MinimalAppDelegate.decorativeIDsAfterPromote(
            current: ["codex:green", "codex:blue"], newPrimary: "codex:green", oldPrimary: "codex:red", oldCanDecorate: true)
        #expect(next == ["codex:blue", "codex:red"])
    }

    @Test("旧主宠已在装饰集 → 不重复追加(去重)")
    func dedupesOldPrimary() {
        let next = MinimalAppDelegate.decorativeIDsAfterPromote(
            current: ["codex:red", "codex:green"], newPrimary: "codex:green", oldPrimary: "codex:red", oldCanDecorate: true)
        #expect(next == ["codex:red"])
    }
}
