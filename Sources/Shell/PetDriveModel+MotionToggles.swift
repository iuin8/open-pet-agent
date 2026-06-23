import Rendering

public extension PetDriveModel {
    /// 「跟随光标 / 桌面漫游」这类宿主驱动的运动开关是否对该形象生效。
    ///
    /// 仅程序化形象(Orb / Slime,`.proceduralMotion`)由宿主 `PetMotionController` 仲裁漫步与爬墙,
    /// 这两个开关才有意义。其余形象一律不响应,菜单据此灰掉(`validateMenuItem`),避免「点了没反应」:
    /// - `.activityStateIndicator`(petdex sprite):位置由帧循环钉死,只随 agent 活动切状态行;
    /// - `.selfAnimating`(Live2D):Cubism 自驱姿态/物理,位置固定;
    /// - `.autonomousEngine`(Shimeji):引擎按自身行为图自管漫步,不受宿主开关控制(改了反而破坏原汁原味)。
    var supportsHostDrivenMotion: Bool { self == .proceduralMotion }
}
