import AppKit
import QuartzCore
import Rendering
import RuntimeBridge

/// Pet 形象「视觉驱动器」：持有当前 `PetRenderer` 并把**位置/速度态**喂给它做
/// 物理 squash。从 `DesktopShellController` 抽出（P2，2026-06-10）——控制器只做
/// 窗口编排 + 事件路由，渲染器的持有与速度耦合下沉到这里，缩小控制器跨层职责。
///
/// 单一职责 = drag + runtime 两条速度链路 → `PetRenderer.updateForVelocity`。
/// 只依赖 Rendering（PetRenderer），不碰 Context/Orchestrator、不直接碰窗口——
/// layer 宿主与窗口几何仍由控制器负责。控制器经转发计算属性把 `petRenderer`
/// 暴露为 `DesktopShellController.petRenderer`（公开 API 不变）。
@MainActor
final class PetVisualDriver {
    /// 当前 pet 形象渲染器。`nil` = Metal 不可用（headless CI / 某些 VM）→ 控制器
    /// 保留 placeholder。`internal` 可写，让控制器转发属性与运行时 `replacePetRenderer`
    /// 都能换装。
    var petRenderer: PetRenderer?

    /// Drag-velocity tracking for `PetRenderer.updateForVelocity`（Phase A.5.1
    /// step 4 — physical squash coupling）。每次 `feedDragVelocity` 采样位置+时间，
    /// 算出屏幕空间速度（px/s）喂给 renderer 沿拖拽矢量拉伸。拖拽结束置 nil，让新
    /// 一轮拖拽从干净原点开始，而不是用陈旧位置合成尖峰。
    private var lastDragPosition: NSPoint?
    private var lastDragTime: CFTimeInterval?

    /// 最近一次拖拽帧算出的屏幕空间速度(px/s,bottom-origin y-up,与 window frame origin 同系)。
    /// 供「松手甩出」取初速:`DesktopShellController.handlePetDragDidEnd` 在 `dragDidEnd()` 前读走。
    /// `dragDidEnd` 清零,新一轮拖拽从 0 起。
    private(set) var lastDragVelocity: CGVector = .zero

    /// 上一帧从 runtime 观测到的 pet 世界位置（非用户拖拽）。`applyRuntimeVelocity`
    /// 据此从相邻 pose 推物理速度矢量（px/s），让 orb 在弹跳/自由落体/撞墙时也
    /// squash，而不只在用户拖拽时。首帧前为 nil；拖拽期间也清 nil（拖拽速度链路
    /// 拥有 orb）。Phase A.5.1 step 4 — physical squash coupling，runtime 侧。
    private var lastRuntimePetPosition: NSPoint?
    private var lastRuntimePetFrameTime: TimeInterval?

    /// |v| (px/s) below this is treated as runtime jitter — orb is told to
    /// ease back to its state base instead of squashing along noise.
    private static let runtimeVelocityIdleThreshold: CGFloat = 5.0

    /// `dt` floor when sampling runtime velocity (1/120 s). Prevents
    /// degenerate divisions on the rare frames where two pose updates land
    /// in the same wall-clock tick.
    private static let runtimeVelocityMinDeltaTime: TimeInterval = 1.0 / 120.0

    /// Compute screen-space velocity from successive drag samples and
    /// forward it to the orb renderer. First call after a drag start has
    /// no prior sample, so we just record the origin and skip emission —
    /// avoids a synthesized infinite-velocity spike.
    func feedDragVelocity(to position: NSPoint) {
        let now = CACurrentMediaTime()
        defer {
            lastDragPosition = position
            lastDragTime = now
        }
        guard let prevPos = lastDragPosition, let prevTime = lastDragTime else {
            return
        }
        let dt = now - prevTime
        guard dt > 0.0001 else { return }
        let velocity = CGVector(
            dx: (position.x - prevPos.x) / dt,
            dy: (position.y - prevPos.y) / dt
        )
        lastDragVelocity = velocity
        petRenderer?.updateForVelocity(velocity)
    }

    /// 拖拽结束：清速度让 orb 回弹到 chat-state base + 重置采样，新一轮拖拽从
    /// 干净原点开始（避免用陈旧位置合成速度尖峰）。
    func dragDidEnd() {
        petRenderer?.updateForVelocity(.zero)
        lastDragPosition = nil
        lastDragTime = nil
        lastDragVelocity = .zero
    }

    /// 从 runtime 相邻 pose 估速度并驱动 squash（控制器 `applyRuntimePetVelocity`
    /// 的内核）。`isDragging` 由控制器从 drag adapter 读出传入。
    ///
    /// Gating：
    /// - 拖拽中：完全跳过并清 baseline（`handlePetDragDidMove` 拥有 orb；双喂会抖；
    ///   清 baseline 避免拖拽后那帧从「拖前 pose ↔ 拖后 pose」的大跳合成 warp 速度）。
    /// - 首帧（无 baseline）：只记录、不发射——避免合成无穷速度尖峰。
    /// - |v| 低于 `runtimeVelocityIdleThreshold`（5 px/s）：发 `.zero`，让 orb 回弹到
    ///   chat-state base，而不是夹在 runtime 噪声的微抖速度上。
    func applyRuntimeVelocity(position: NSPoint, now: TimeInterval, isDragging: Bool) {
        if isDragging {
            lastRuntimePetPosition = nil
            lastRuntimePetFrameTime = nil
            return
        }

        defer {
            lastRuntimePetPosition = position
            lastRuntimePetFrameTime = now
        }

        guard let prev = lastRuntimePetPosition,
              let prevTime = lastRuntimePetFrameTime else {
            return
        }

        let dt = max(now - prevTime, Self.runtimeVelocityMinDeltaTime)
        let velocity = CGVector(
            dx: (position.x - prev.x) / dt,
            dy: (position.y - prev.y) / dt
        )
        let magnitude = (velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot()
        if magnitude < Self.runtimeVelocityIdleThreshold {
            petRenderer?.updateForVelocity(.zero)
        } else {
            petRenderer?.updateForVelocity(velocity)
        }
    }
}
