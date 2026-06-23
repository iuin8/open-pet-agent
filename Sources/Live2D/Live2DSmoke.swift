import CubismCore
import Live2DBridge

// 工作块 D 框架 smoke —— 验证官方 Cubism 栈在本项目 SwiftPM 能编译 + 链接 + 调用。
// D-0:Core C 静态库(macOS slice)链接 + `csmGetVersion()` 可调(swift-cubism iOS-only 路已否决)。
// D-2.0:Cubism Native Framework(C++ + ObjC++ Metal renderer 源)编进 SwiftPM + `CubismFramework::
//        StartUp` 经 ObjC++ 桥可调 —— 框架可集成,渲染管线(metallib + Metal renderer)留 D-2.2。
// 后续 Live2DModelPackLoader / Live2DPetRenderer 取代本 smoke。

public enum Live2DSmoke {
    /// 调官方 Core C API `csmGetVersion()` → 返回版本号(非 0 = Core 链接成功)。
    public static func coreVersion() -> UInt32 {
        csmGetVersion()
    }

    /// 启动 Cubism Framework(C++ 经 ObjC++ 桥)→ 返回是否就绪(true = framework 编译+链接+运行 OK)。
    @discardableResult
    public static func startFramework() -> Bool {
        L2DBridge.startUpFramework() && L2DBridge.isFrameworkStarted()
    }
}
