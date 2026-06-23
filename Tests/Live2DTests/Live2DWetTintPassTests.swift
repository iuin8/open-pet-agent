import Metal
import Testing
@testable import Live2D

// 工作块 D B3:Live2D 淋湿水渍 tint。
// — premultipliedAlpha 是纯函数,无头断言 clamp/缩放。
// — 真实 blend 数学用 GPU 离屏渲一遍验证(destinationAlpha 作 coverage:只染有覆盖的像素,
//   alpha 通道恒等保持)。无 GPU(headless CI)则 `try #require` 干净跳过。

@Suite("Live2DWetTintPass 水渍 tint(B3)")
@MainActor
struct Live2DWetTintPassTests {

    // MARK: - 纯函数:premultipliedAlpha

    @Test("wetness 0 → 0;1 → maxTintAlpha")
    func premultipliedAlphaEndpoints() {
        #expect(Live2DWetTintPass.premultipliedAlpha(forWetness: 0) == 0)
        #expect(Live2DWetTintPass.premultipliedAlpha(forWetness: 1) == Live2DWetTintPass.maxTintAlpha)
    }

    @Test("wetness 越界 clamp 到 [0,1]")
    func premultipliedAlphaClamps() {
        #expect(Live2DWetTintPass.premultipliedAlpha(forWetness: -0.5) == 0)
        #expect(Live2DWetTintPass.premultipliedAlpha(forWetness: 2.0) == Live2DWetTintPass.maxTintAlpha)
    }

    @Test("wetness 0.5 → 半量")
    func premultipliedAlphaMidpoint() {
        let a = Live2DWetTintPass.premultipliedAlpha(forWetness: 0.5)
        #expect(abs(a - Live2DWetTintPass.maxTintAlpha * 0.5) < 1e-6)
    }

    // MARK: - GPU blend 行为(真实 Metal,无 Cubism/metallib 依赖)

    /// 预填 1×1 .bgra8Unorm .shared 纹理为指定 BGRA,跑一遍 wet tint,读回。
    private func renderTint(dstBGRA: [UInt8], wetness: Float) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let pass = try #require(Live2DWetTintPass(device: device))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let tex = try #require(device.makeTexture(descriptor: desc))
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                    withBytes: dstBGRA, bytesPerRow: 4)

        let cb = try #require(queue.makeCommandBuffer())
        pass.encode(commandBuffer: cb, targetTexture: tex, wetness: wetness)
        cb.commit()
        cb.waitUntilCompleted()

        var out = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&out, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return out
    }

    @Test("不透明像素满湿 → 向蓝偏移,alpha 保持 255")
    func opaquePixelTintsTowardBlue() throws {
        // 不透明红(premultiplied):BGRA = (0, 0, 255, 255)
        let out = try renderTint(dstBGRA: [0, 0, 255, 255], wetness: 1.0)
        // result.rgb = blue·0.32 + red·0.68;result.a = dstA 恒等。
        #expect(out[3] == 255)              // A 恒等(occluder 轮廓不受影响)
        #expect(out[0] > 5)                 // B:0 → 升(混入蓝)
        #expect(out[2] < 255 && out[2] > 150)  // R:255 → 降但仍主导
    }

    @Test("全透明像素 → 不被染色(destinationAlpha 作 coverage)")
    func transparentPixelStaysClear() throws {
        let out = try renderTint(dstBGRA: [0, 0, 0, 0], wetness: 1.0)
        #expect(out == [0, 0, 0, 0])       // dstA=0 → 蓝色贡献为 0,完全透明保持
    }

    @Test("wetness 0 → 像素不变(无 encoder)")
    func dryPixelUnchanged() throws {
        let out = try renderTint(dstBGRA: [0, 0, 255, 255], wetness: 0.0)
        #expect(out == [0, 0, 255, 255])
    }
}
