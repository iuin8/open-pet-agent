import Foundation
import Live2DBridge

// 工作块 D D-2.1:从 Live2D 模型包读取只读元信息(画布像素 / 参数·部件数)—— 经 ObjC++ 桥
// 调 Cubism `CubismMoc`/`CubismModel`。证明框架真能解析真实模型数据;也是 D-2.2 渲染时定
// viewport / 参数驱动的基础。本阶段不渲染、不持有模型(读完即释放)。

/// 一个 Cubism 模型解析出的只读度量。
public struct Live2DModelMetrics: Equatable, Sendable {
    public let canvasWidthPixel: Float
    public let canvasHeightPixel: Float
    public let pixelsPerUnit: Float
    public let parameterCount: Int
    public let partCount: Int
}

/// 工作块 D D-3a:无头跑 motion 引擎的探针结果 —— 证明 `L2DUserModel` 的 Update 管线(idle
/// motion + 呼吸 + 物理 + pose)真在驱动模型参数(实际播放视觉由装好的 app 录屏验收)。
public struct Live2DMotionMetrics: Equatable, Sendable {
    public let motionGroupCount: Int
    public let idleMotionCount: Int
    public let expressionCount: Int
    public let hasPhysics: Bool
    public let hasPose: Bool
    /// 跑若干帧 Update 后参数是否相对默认值发生变化。
    public let parametersAdvanced: Bool
}

public enum Live2DModelProbe {

    /// 读 `.moc3` 文件的元信息;失败(读不到 / moc 版本不符 / 校验失败)返回 nil。
    public static func metrics(mocPath: String) -> Live2DModelMetrics? {
        guard let info = L2DBridge.loadMoc(atPath: mocPath) else { return nil }
        return Live2DModelMetrics(
            canvasWidthPixel: info.canvasWidthPixel,
            canvasHeightPixel: info.canvasHeightPixel,
            pixelsPerUnit: info.pixelsPerUnit,
            parameterCount: info.parameterCount,
            partCount: info.partCount
        )
    }

    /// 在一个模型包目录里找第一个 `.moc3`(限深 3,容 `<pack>/x.moc3` 或 `<pack>/runtime/x.moc3`)
    /// 并读元信息。配合 `Live2DModelPackLoader` 发现的包。
    public static func metrics(packDir: URL) -> Live2DModelMetrics? {
        guard let moc = firstMoc(in: packDir) else { return nil }
        return metrics(mocPath: moc.path)
    }

    /// 限深找第一个 `.moc3`(路径最短优先,偏向包根)。
    static func firstMoc(in dir: URL, maxDepth: Int = 3) -> URL? {
        firstFile(in: dir, ext: "moc3", maxDepth: maxDepth)
    }

    /// 限深找第一个 `.model3.json`(路径最短优先)。
    static func firstModel3(in dir: URL, maxDepth: Int = 3) -> URL? {
        firstFile(in: dir, suffix: ".model3.json", maxDepth: maxDepth)
    }

    private static func firstFile(in dir: URL, ext: String? = nil, suffix: String? = nil,
                                  maxDepth: Int) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var found: URL?
        for case let item as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            let matches = (ext != nil && item.pathExtension.lowercased() == ext)
                || (suffix != nil && item.lastPathComponent.lowercased().hasSuffix(suffix!))
            if matches, found == nil || item.path.count < found!.path.count { found = item }
        }
        return found
    }

    // MARK: - D-3a motion 引擎无头探针

    /// 加载 model3.json 全部资产 + 跑 `frames` 帧 Update(dt),返回 motion 引擎度量。失败返回 nil。
    public static func motionMetrics(model3Path: String, frames: Int = 6,
                                     dt: Double = 1.0 / 30.0) -> Live2DMotionMetrics? {
        guard let p = L2DBridge.probeMotion(atModel3Path: model3Path, frameCount: frames, dt: dt)
        else { return nil }
        return Live2DMotionMetrics(
            motionGroupCount: p.motionGroupCount,
            idleMotionCount: p.idleMotionCount,
            expressionCount: p.expressionCount,
            hasPhysics: p.hasPhysics,
            hasPose: p.hasPose,
            parametersAdvanced: p.parametersAdvanced
        )
    }

    /// 在包目录里定位 `.model3.json` 后跑 motion 探针。
    public static func motionMetrics(packDir: URL, frames: Int = 6,
                                     dt: Double = 1.0 / 30.0) -> Live2DMotionMetrics? {
        guard let m3 = firstModel3(in: packDir) else { return nil }
        return motionMetrics(model3Path: m3.path, frames: frames, dt: dt)
    }
}
