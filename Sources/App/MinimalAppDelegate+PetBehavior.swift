import AppKit
import Foundation
import Shell

// MARK: - S1 桌宠主动行为 (mouse area + idle 反应)

extension MinimalAppDelegate {
    /// MouseAreaTracker callback: 鼠标 X 移到屏幕左/中/右时 orb 沿对应方向
    /// 短暂 squash, 视觉上像"扭头看光标方向"。复用现有 `updateForVelocity`
    /// 物理形变通道, 0 shader 改动。
    func handleMouseAreaChange(_ area: MouseAreaTracker.MouseArea) {
        guard let renderer = shellController?.petRenderer else { return }
        let dx: CGFloat = switch area {
        case .left:   -120  // 朝左 squash
        case .right:   120
        case .center:    0  // 回中性
        }
        renderer.updateForVelocity(CGVector(dx: dx, dy: 0))
        // 0.3s 后归零, orb ease 自动回静态。复用现有 squash 0.25s ease-out。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            renderer.updateForVelocity(.zero)
        }
    }

    /// IdleStateTracker callback: 用户 3 分钟无键鼠输入 → orb panel 微调暗(alphaValue 0.7);回来变亮。
    /// 注意:**不再据此调帧率** —— 「用户没碰键鼠」≠「用户没在看宠物」,据此降到 6Hz 会让用户盯着看时
    /// 也卡(像休眠,这是反复反馈的根因)。帧率改由 `handlePetVisibilityChange`(窗口是否被遮挡)驱动。
    func handleIdleSleepingChange(_ isSleeping: Bool) {
        guard let pet = shellController?.windowSet.petWindow else { return }
        let target: CGFloat = isSleeping ? Self.sleepingAlpha : Self.awakeAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.smooth
            ctx.allowsImplicitAnimation = false
            pet.animator().alphaValue = target
        }
    }

    /// 窗口遮挡变化 → 调帧率。**宠物可见**(用户看得到)= 满 30Hz 顺滑;**完全被遮挡 / 不可见** = 降 6Hz
    /// 省电(看不到时降频无感)。这是取代「按键鼠空闲降频」的**正确信号** —— 修「盯着看也卡 / 像休眠」。
    /// 事件驱动(`NSWindow.didChangeOcclusionStateNotification`),非每帧轮询;只在目标频率变化时 reschedule。
    func handlePetVisibilityChange() {
        let desiredHz = Self.desiredHz(petVisible: isAnyPetWindowVisible())
        guard desiredHz != currentFrameLoopHz else { return }
        currentFrameLoopHz = desiredHz
        frameLoopHandle?.setRate(desiredHz)
    }

    /// 主宠或任一装饰宠窗口当前可见(未被完全遮挡)。无主宠窗口 → 按可见(宁可顺滑,不误降)。
    func isAnyPetWindowVisible() -> Bool {
        guard let primary = shellController?.windowSet.petWindow else { return true }
        if primary.occlusionState.contains(.visible) { return true }
        return decorativePets.contains { $0.pet.isWindowVisible }
    }

    /// 纯逻辑(便于单测):宠物可见 → 满帧率;不可见 → idle 省电频率。
    nonisolated static func desiredHz(petVisible: Bool) -> Double {
        petVisible ? frameLoopHz : idleFrameLoopHz
    }
}
