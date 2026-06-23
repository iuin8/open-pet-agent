import Metal

// 工作块 B3(Live2D)—— 淋湿水渍 tint pass。
//
// 为何不复用 sprite 的 CALayer 蓝色层方案:Live2D host layer 是 `CAMetalLayer`,在它上面叠
// 一个 CALayer 蓝色层 + 帧 alpha mask 需要每帧从 GPU 读回轮廓、CPU 重建 CGImage 作 mask,带
// 1 帧延迟且每帧 CPU 开销 —— 模型每帧 mesh 形变时蓝色会与真实像素错位(凑数感)。
//
// 更优解:在 Cubism `DrawModel` 之后,用 `loadAction=.load` 在**同一 drawable** 上开一道我们
// 完全自管的全屏 quad pass,blend 用 `destinationAlpha` 作 coverage —— 蓝色只染模型已渲像素,
// 纯 GPU、零读回、零延迟、premultiplied 正确,且 **alpha 通道经 blend 保持 dst 不变**(D-4a
// occluder 读的就是 alpha 轮廓,wet tint 不能动它)。MSL 运行时编译(`makeLibrary(source:)`,
// 不需 Metal toolchain,与主 app SDF renderer 同路)。
//
// 颜色 / 上限与 sprite 路径(`SpriteSheetPetRenderer`)对齐:srgb(0.30, 0.55, 0.95),
// 满湿 alpha 上限 0.32,保持两种形象淋湿观感一致。
@MainActor
public final class Live2DWetTintPass {

    /// 满湿(wetness=1)时的水渍 alpha 上限。与 sprite `maxWetTintAlpha` 一致。
    public static let maxTintAlpha: Float = 0.32

    /// 淋湿程度(0..1,越界 clamp)→ 预乘 alpha 量。纯函数,供无头单测验证 clamp/缩放。
    public static func premultipliedAlpha(forWetness level: Float) -> Float {
        min(max(level, 0), 1) * maxTintAlpha
    }

    private let pipeline: MTLRenderPipelineState

    /// 用 renderer 的 device 构建。MSL 编译 / pipeline 创建失败 → nil(renderer 跳过 wet tint)。
    public init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFn = library.makeFunction(name: "live2d_wet_vertex"),
              let fragmentFn = library.makeFunction(name: "live2d_wet_fragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        let color = desc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm          // 与 metalLayer / drawable 一致
        color.isBlendingEnabled = true
        // result.rgb = blue_premul·dstA + dstRGB·(1−srcA);result.a = srcA·dstA + dstA·(1−srcA) = dstA
        // → 蓝色按模型覆盖率(dstA)染色,alpha 通道恒等保持(occluder 轮廓不受影响)。
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .destinationAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .destinationAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = state
    }

    /// 在 `targetTexture`(已渲好模型的 drawable)上叠一道水渍 tint。须与 `model.draw` 同一
    /// command buffer、在 present 之前调。wetness ≤ 0 时不产出 encoder。
    public func encode(commandBuffer: MTLCommandBuffer, targetTexture: MTLTexture, wetness: Float) {
        var premulAlpha = Self.premultipliedAlpha(forWetness: wetness)
        guard premulAlpha > 0 else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targetTexture
        pass.colorAttachments[0].loadAction = .load     // 保留已渲模型像素
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&premulAlpha, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)   // 全屏三角形
        encoder.endEncoding()
    }

    /// 全屏三角形顶点(无 buffer,vertex_id 推 NDC)+ 预乘蓝色 fragment。
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct WetVSOut { float4 position [[position]]; };

    vertex WetVSOut live2d_wet_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        WetVSOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    fragment float4 live2d_wet_fragment(constant float &premulAlpha [[buffer(0)]]) {
        const float3 tint = float3(0.30, 0.55, 0.95);   // 与 sprite 水渍同色
        return float4(tint * premulAlpha, premulAlpha); // 预乘输出
    }
    """
}
