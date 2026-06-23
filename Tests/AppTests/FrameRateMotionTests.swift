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
}
