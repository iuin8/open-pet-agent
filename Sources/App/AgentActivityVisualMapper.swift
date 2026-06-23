import AgentSensing
import Rendering

/// App 层纯映射：把感知层的 `AgentEvent` 翻译成 Rendering 层的 `PetActivityVisual`（→petdex 状态行）。
///
/// **严格对照 petdex (https://github.com/crafter-station/petdex) 官方 `stateForEvent`** 的
/// `bubble-runner` + STATE_MAP——原汁原味,不自创状态:
/// - `user.prompt` → jumping（你发问,桌宠雀跃）
/// - tool pre：只读工具(read/grep/glob)→ review,其余 → running
/// - tool post(成功)→ idle；`session.error`(工具出错)→ failed
/// - `session.waiting` → waiting
/// - 模型生成文本/思考:**petdex 无对应 hook → 不改态**(返回 nil,继承上一态)
///
/// Rendering 不依赖 AgentSensing（避免成环）；本 mapper 在 App 接线层充当桥梁。
public enum AgentActivityVisualMapper {

    /// petdex bubble-runner 把这三个只读工具特判成 review 态(小写比较)。严格对照,不增不减。
    static let readOnlyTools: Set<String> = ["read", "grep", "glob"]

    static func isReadOnlyTool(_ name: String) -> Bool { readOnlyTools.contains(name.lowercased()) }

    /// 把**原始** `AgentEvent` 映射成 petdex sprite 应显示的视觉态。`nil` = 不改态(petdex 无对应 hook)。
    /// 纯函数,无副作用,好无头测。
    public static func visual(forEvent event: AgentEvent) -> PetActivityVisual? {
        switch event.kind {
        case .userPrompt:
            return .celebrating                                  // petdex user.prompt → jumping 行
        case .toolUse(let name, _):
            return isReadOnlyTool(name) ? .reviewing : .working  // read/grep/glob → review,其余 → running
        case .toolResult(_, let isError):
            return isError ? .failed : .idle                     // petdex session.error→failed / post→idle(活跃期被 250ms 防抖平滑成 running)
        case .awaitingUser:
            return .waiting                                       // petdex session.waiting → waiting 行
        case .done:
            return .idle                                          // 一轮收尾/静默 → idle(petdex stop→waving 靠 sidecar 自动复位 idle;本仓无复位,直接 idle 等效)
        case .assistantText, .thinking, .sessionStart, .interrupted, .compactBoundary:
            return nil                                            // petdex 无「生成文本」hook → 不改态(继承上一态),根治「一直挥手」
        }
    }
}
