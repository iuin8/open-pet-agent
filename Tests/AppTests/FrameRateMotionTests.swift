import Testing
@testable import App

/// 帧率自适应(修「盯着看也卡 / 像休眠」):帧率按**宠物窗口是否可见**调,而非按用户键鼠空闲。
/// 可见 → 满帧率顺滑;被完全遮挡 → idle 省电频率(看不到时降频无感)。纯逻辑单测 `desiredHz(petVisible:)`。
@Suite("帧率自适应(按可见性,不按键鼠空闲)")
struct FrameRateMotionTests {

    @Test("宠物可见 → 满帧率(盯着看永远顺滑)")
    func visiblePetFullRate() {
        #expect(MinimalAppDelegate.desiredHz(petVisible: true) == MinimalAppDelegate.frameLoopHz)
    }

    @Test("宠物被完全遮挡/不可见 → idle 省电频率(看不到时降频无感)")
    func occludedPetIdleRate() {
        #expect(MinimalAppDelegate.desiredHz(petVisible: false) == MinimalAppDelegate.idleFrameLoopHz)
    }

    @Test("满帧率 > idle 频率(可见时确实更顺滑)")
    func fullRateExceedsIdle() {
        #expect(MinimalAppDelegate.desiredHz(petVisible: true) > MinimalAppDelegate.desiredHz(petVisible: false))
    }

    @Test("可见但静止(无运动驱动)→ 降到可见 idle 频率(§6.6 残留:省窗口枚举/orchestrator)")
    func visibleIdleThrottled() {
        let idle = MinimalAppDelegate.desiredHz(petVisible: true, hasActiveMotion: false)
        #expect(idle == MinimalAppDelegate.visibleIdleFrameLoopHz)
        // 静止降频区间合理:遮挡(6) < 可见静止(10) < 可见有运动(30)
        #expect(idle < MinimalAppDelegate.frameLoopHz)
        #expect(idle > MinimalAppDelegate.idleFrameLoopHz)
    }

    @Test("可见且有运动 → 仍满帧率(动宠盯着看不卡,不踩 §6.1)")
    func visibleActiveFullRate() {
        #expect(MinimalAppDelegate.desiredHz(petVisible: true, hasActiveMotion: true) == MinimalAppDelegate.frameLoopHz)
    }
}
