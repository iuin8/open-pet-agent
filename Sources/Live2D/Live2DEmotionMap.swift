import Rendering

// 工作块 D D-3b:情绪态 → Cubism motion 的映射(纯函数,可无头测)。
//
// 设计:D-3a 的 idle 基线(自动 motion 循环 + 呼吸 + 眨眼 + 物理)已让模型「活」。本层只在
// **活跃态**(talking / confused)叠加一次 reaction motion accent —— 切到该态时播一条非 idle
// 组的 motion(打断 idle,播完自动回 idle 循环)。平静态(idle/watching/thinking)不打断基线。
//
// **容错**:Live2D 模型的 motion 组命名各异(Hiyori 仅 Idle + TapBody),映射做 best-effort ——
// 取第一个非 idle 组;没有则降级为「不打断」(纯 idle 基线)。诚实边界:无音频振幅信号,
// **不做假 lip sync**(按反「凑数」原则,留待接入 TTS 振幅后再驱动 ParamMouthOpenY)。

/// motion 优先级,镜像桥 C++ `L2DMotionPriority`。
public enum Live2DMotionPriority: Int, Sendable {
    case none = 0
    case idle = 1
    case normal = 2
    case force = 3
}

/// 情绪态映射结果:可选「播某 motion 组」+ 可选「设表情」。两者都 nil = 保持 idle 基线。
public struct Live2DEmotionAction: Equatable, Sendable {
    public var motionGroup: String?
    public var expression: String?
    public init(motionGroup: String? = nil, expression: String? = nil) {
        self.motionGroup = motionGroup
        self.expression = expression
    }
}

public enum Live2DEmotionMap {
    /// Cubism 约定的 idle 组名。
    public static let idleGroup = "Idle"

    /// (情绪态, 模型可用 motion 组, 可用表情) → 动作。纯函数。
    public static func action(for state: PetEmotionState,
                              groups: [String],
                              expressions: [String]) -> Live2DEmotionAction {
        switch state {
        case .idle, .watching, .thinking:
            // 平静态:idle 基线足以表达,不打断。
            return Live2DEmotionAction()
        case .talking, .confused:
            // 活跃态:播一个非 idle 的 reaction 组(best-effort);没有则保持基线。
            return Live2DEmotionAction(motionGroup: firstNonIdleGroup(groups))
        }
    }

    /// 取第一个非 "Idle" 组(大小写不敏感)。无非 idle 组则 nil。
    static func firstNonIdleGroup(_ groups: [String]) -> String? {
        groups.first { $0.caseInsensitiveCompare(idleGroup) != .orderedSame }
    }
}
