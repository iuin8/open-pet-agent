import Testing
@testable import Live2D

// 工作块 D D-4a:BGRA8 → alpha 轮廓 mask 纯函数测试(无头)。真实 GPU 离屏渲染靠装好的 app 视觉验收。

@Suite("Live2DSilhouetteExtractor BGRA→alpha mask(D-4a)")
struct Live2DSilhouetteExtractorTests {

    /// 构造 width×height 的紧凑 BGRA8,alpha 由闭包给定(B/G/R 填噪声证明只取 alpha)。
    private func bgra(width: Int, height: Int, alpha: (_ x: Int, _ y: Int) -> UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                buf[i] = 11; buf[i + 1] = 22; buf[i + 2] = 33     // B/G/R 噪声(不应进 mask)
                buf[i + 3] = alpha(x, y)                          // A
            }
        }
        return buf
    }

    @Test("取 alpha 通道(byte 3),忽略 BGR")
    func extractsAlphaChannelOnly() {
        let buf = bgra(width: 2, height: 2) { x, _ in x == 0 ? 0 : 255 }
        let m = Live2DSilhouetteExtractor.extract(bgra: buf, width: 2, height: 2)
        #expect(m.width == 2 && m.height == 2)
        #expect(m.mask == [0, 255, 0, 255])   // 每行 (x=0→0, x=1→255)
    }

    @Test("row 0 = 纹理顶(行序不翻转,与 sprite 约定一致)")
    func rowZeroIsTop() {
        // 顶行全不透明,底行全透明 → mask 前 width 个为 255。
        let buf = bgra(width: 3, height: 2) { _, y in y == 0 ? 200 : 0 }
        let m = Live2DSilhouetteExtractor.extract(bgra: buf, width: 3, height: 2)
        #expect(Array(m.mask.prefix(3)) == [200, 200, 200])
        #expect(Array(m.mask.suffix(3)) == [0, 0, 0])
    }

    @Test("alpha 原值保留(不阈值化,kernel 自判阈值)")
    func preservesRawAlpha() {
        let buf = bgra(width: 1, height: 3) { _, y in [0, 128, 255][y] }
        let m = Live2DSilhouetteExtractor.extract(bgra: buf, width: 1, height: 3)
        #expect(m.mask == [0, 128, 255])
    }

    @Test("缓冲过短 → 全 0 mask(防越界,当帧不堆)")
    func shortBufferYieldsZeroMask() {
        let m = Live2DSilhouetteExtractor.extract(bgra: [1, 2, 3], width: 4, height: 4)
        #expect(m.width == 4 && m.height == 4)
        #expect(m.mask == [UInt8](repeating: 0, count: 16))
    }

    @Test("零尺寸安全")
    func zeroSizeSafe() {
        let m = Live2DSilhouetteExtractor.extract(bgra: [], width: 0, height: 0)
        #expect(m.mask.isEmpty && m.width == 0 && m.height == 0)
    }
}
