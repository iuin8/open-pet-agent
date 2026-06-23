import Testing
import Foundation
@testable import Live2D

@Suite("Live2DModelProbe 真实模型解析(D-2.1)")
struct Live2DModelProbeTests {

    /// 包根:本测试文件 → 上溯 3 层(Tests/Live2DTests/<file> → 包根)。
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Hiyori 样本 fixture(setup-cubism.sh 解入 gitignored Vendor;Live2DTests 仅在 Vendor
    /// 存在时编 → 必在)。
    private static var hiyoriPack: URL {
        packageRoot.appendingPathComponent("Vendor/Cubism/Samples/Hiyori", isDirectory: true)
    }

    @Test("加载真实 Hiyori.moc3 → 画布/参数/部件数合理")
    func parsesRealHiyori() throws {
        let moc = Self.hiyoriPack.appendingPathComponent("Hiyori.moc3")
        try #require(FileManager.default.fileExists(atPath: moc.path),
                     "缺 Hiyori fixture(\(moc.path));重跑 scripts/setup-cubism.sh 解出样本")
        let m = try #require(Live2DModelProbe.metrics(mocPath: moc.path),
                             "Cubism 解析 Hiyori.moc3 失败(framework/Core 未正确链接?)")
        #expect(m.canvasWidthPixel > 0)
        #expect(m.canvasHeightPixel > 0)
        #expect(m.pixelsPerUnit > 0)
        #expect(m.parameterCount > 0, "真实模型应有可驱动参数")
        #expect(m.partCount > 0, "真实模型应有部件")
    }

    @Test("从包目录自动定位 .moc3 并解析")
    func parsesFromPackDir() throws {
        try #require(FileManager.default.fileExists(atPath: Self.hiyoriPack.path))
        let m = try #require(Live2DModelProbe.metrics(packDir: Self.hiyoriPack))
        #expect(m.parameterCount > 0)
    }

    @Test("不存在的 moc 路径 → nil(不崩)")
    func missingMocReturnsNil() {
        #expect(Live2DModelProbe.metrics(mocPath: "/nonexistent/x.moc3") == nil)
    }

    @Test("非 moc 数据 → nil(一致性校验拦下)")
    func garbageMocReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).moc3")
        try Data("not a real moc3 file".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(Live2DModelProbe.metrics(mocPath: tmp.path) == nil)
    }

    // MARK: - D-3a motion 引擎

    @Test("Hiyori motion 引擎:组/idle/物理/pose 资产齐 + Update 推进参数")
    func motionEngineDrivesModel() throws {
        let m3 = Self.hiyoriPack.appendingPathComponent("Hiyori.model3.json")
        try #require(FileManager.default.fileExists(atPath: m3.path),
                     "缺 Hiyori fixture;重跑 scripts/setup-cubism.sh")
        let p = try #require(Live2DModelProbe.motionMetrics(model3Path: m3.path, frames: 8),
                             "motion 探针失败(L2DUserModel 加载 / Update 崩?)")
        #expect(p.motionGroupCount >= 2, "Hiyori 有 Idle + TapBody 两组")
        #expect(p.idleMotionCount == 9, "Hiyori Idle 组 9 条 motion")
        #expect(p.hasPhysics, "Hiyori 带 physics3.json")
        #expect(p.hasPose, "Hiyori 带 pose3.json")
        #expect(p.parametersAdvanced, "跑 8 帧 Update 后参数应被呼吸/idle/物理推进")
    }

    @Test("从包目录定位 model3.json 跑 motion 探针")
    func motionMetricsFromPackDir() throws {
        try #require(FileManager.default.fileExists(atPath: Self.hiyoriPack.path))
        let p = try #require(Live2DModelProbe.motionMetrics(packDir: Self.hiyoriPack))
        #expect(p.motionGroupCount > 0)
        #expect(p.parametersAdvanced)
    }

    @Test("不存在的 model3 → nil(不崩)")
    func missingModel3ReturnsNil() {
        #expect(Live2DModelProbe.motionMetrics(model3Path: "/nonexistent/x.model3.json") == nil)
    }
}
