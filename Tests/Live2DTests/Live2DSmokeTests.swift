import Testing
@testable import Live2D

@Suite("Live2D D-0 框架 smoke")
struct Live2DSmokeTests {
    /// 验证官方 Cubism Core 静态库(macOS slice)真链接 + C API 真可调:
    /// `csmGetVersion()` 返回非 0 版本号 → macOS Cubism 集成可行(swift-cubism iOS-only 路已否决)。
    @Test("官方 Cubism Core macOS 链接 + csmGetVersion 可调")
    func coreLinksAndRuns() {
        let v = Live2DSmoke.coreVersion()
        #expect(v > 0, "csmGetVersion 返回 0 → Core 未正确链接")
    }

    /// D-2.0:Cubism Native Framework(C++ + ObjC++ Metal renderer 源)编进 SwiftPM +
    /// `CubismFramework::StartUp` 经 ObjC++ 桥可调 → framework 可集成(渲染管线留 D-2.2)。
    @Test("Cubism Framework 经 ObjC++ 桥 StartUp 可调")
    func frameworkStartsUp() {
        #expect(Live2DSmoke.startFramework(), "CubismFramework StartUp/IsStarted 失败 → 框架未正确编译/链接")
    }
}
