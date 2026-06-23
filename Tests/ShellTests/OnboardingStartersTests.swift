import Testing
@testable import Shell

// MARK: - OnboardingStarters 逻辑测试（无头，无 UI 依赖）

@Suite("OnboardingStarters 开箱 onboarding 判定")
struct OnboardingStartersTests {

    // MARK: UD key 常量

    @Test("dismissedKey 常量值正确")
    func dismissedKeyConstant() {
        #expect(OnboardingStarters.dismissedKey == "onboarding.starters.dismissed")
    }

    // MARK: shouldShow 四种情形

    @Test("空库 + 未 dismissed → 应弹")
    func emptyNotDismissed() {
        #expect(OnboardingStarters.shouldShow(communityPetCount: 0, dismissed: false) == true)
    }

    @Test("空库 + 已 dismissed → 不弹")
    func emptyDismissed() {
        #expect(OnboardingStarters.shouldShow(communityPetCount: 0, dismissed: true) == false)
    }

    @Test("非空库 + 未 dismissed → 不弹")
    func nonEmptyNotDismissed() {
        #expect(OnboardingStarters.shouldShow(communityPetCount: 1, dismissed: false) == false)
    }

    @Test("非空库 + 已 dismissed → 不弹")
    func nonEmptyDismissed() {
        #expect(OnboardingStarters.shouldShow(communityPetCount: 2, dismissed: true) == false)
    }

    @Test("社区宠数量 > 1 仍不弹")
    func manyPetsNotDismissed() {
        #expect(OnboardingStarters.shouldShow(communityPetCount: 5, dismissed: false) == false)
    }
}
