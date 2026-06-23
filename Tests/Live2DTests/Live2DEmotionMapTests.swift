import Testing
import Rendering
@testable import Live2D

// 工作块 D D-3b:情绪态 → motion 映射纯函数测试(无头)。

@Suite("Live2DEmotionMap 情绪态映射(D-3b)")
struct Live2DEmotionMapTests {

    private let hiyoriGroups = ["Idle", "TapBody"]

    @Test("平静态(idle/watching/thinking)不打断 idle 基线 → 无 motion/表情",
          arguments: [PetEmotionState.idle, .watching, .thinking])
    func calmStatesKeepBaseline(state: PetEmotionState) {
        let a = Live2DEmotionMap.action(for: state, groups: hiyoriGroups, expressions: [])
        #expect(a.motionGroup == nil)
        #expect(a.expression == nil)
    }

    @Test("活跃态(talking/confused)→ 播第一个非 idle 组",
          arguments: [PetEmotionState.talking, .confused])
    func activeStatesPlayReaction(state: PetEmotionState) {
        let a = Live2DEmotionMap.action(for: state, groups: hiyoriGroups, expressions: [])
        #expect(a.motionGroup == "TapBody")
    }

    @Test("只有 Idle 组时活跃态降级为不打断(无 reaction 可播)")
    func activeWithOnlyIdleDegradesToBaseline() {
        let a = Live2DEmotionMap.action(for: .talking, groups: ["Idle"], expressions: [])
        #expect(a.motionGroup == nil)
    }

    @Test("空组列表 → 不崩,不播")
    func emptyGroupsSafe() {
        let a = Live2DEmotionMap.action(for: .confused, groups: [], expressions: [])
        #expect(a.motionGroup == nil)
    }

    @Test("firstNonIdleGroup 大小写不敏感跳过 idle,保序取第一个非 idle")
    func firstNonIdleCaseInsensitiveOrdered() {
        #expect(Live2DEmotionMap.firstNonIdleGroup(["idle", "IDLE", "Flick", "TapBody"]) == "Flick")
        #expect(Live2DEmotionMap.firstNonIdleGroup(["Idle"]) == nil)
        #expect(Live2DEmotionMap.firstNonIdleGroup([]) == nil)
    }

    @Test("优先级枚举值与桥 C++ L2DMotionPriority 镜像一致")
    func priorityRawValuesMatchBridge() {
        #expect(Live2DMotionPriority.none.rawValue == 0)
        #expect(Live2DMotionPriority.idle.rawValue == 1)
        #expect(Live2DMotionPriority.normal.rawValue == 2)
        #expect(Live2DMotionPriority.force.rawValue == 3)
    }
}
