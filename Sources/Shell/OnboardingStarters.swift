import Foundation

// MARK: - OnboardingStarters

/// 开箱 onboarding 判定逻辑（纯函数，无副作用，可无头测试）。
///
/// 规则：社区库空（`communityPetCount == 0`）且用户未手动关闭（`dismissed == false`）→ 弹推荐卡。
/// 内置 Orb / Slime 是程序化宠，不计入社区库；社区库 = CodexSpritePackLoader + Live2DModelPackLoader
/// 扫描结果之和，由调用方（MinimalAppDelegate+Onboarding）传入。
public enum OnboardingStarters {

    /// UserDefaults key：用户点「以后再说」后写入 `true`，防止重启重弹。
    public static let dismissedKey = "onboarding.starters.dismissed"

    /// 是否应该显示开箱推荐卡。
    ///
    /// - Parameters:
    ///   - communityPetCount: 社区库中的宠物数量（不含内置程序化宠）。
    ///   - dismissed: 用户是否已手动关闭过（从 UserDefaults 读取）。
    /// - Returns: `true` → 弹推荐卡；`false` → 跳过。
    public static func shouldShow(communityPetCount: Int, dismissed: Bool) -> Bool {
        communityPetCount == 0 && !dismissed
    }
}
