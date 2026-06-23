import AppKit
import Metal
import QuartzCore
import Rendering
import Live2DBridge

// 工作块 D D-2.2b:Live2D 形象的 PetRenderer —— 独立 CAMetalLayer + CVDisplayLink,整帧委托给
// `L2DLive2DModel`(Cubism Metal renderer)。
//
// 为何不复用 `MetalPetRenderer`(open class):它的 `tickAndRender` 自建**单个** MTLRenderCommandEncoder
// + 画全屏三角形(SDF 内联 shader 模式),而 Cubism `DrawModel` 在 command buffer 上**自管多个**
// encoder(mask 裁剪 + 模型 pass),两种帧模型不兼容。故本类自持渲染循环,只共享 CVDisplayLink
// 的 Unmanaged ctx + Task @MainActor 心跳模式(与 MetalPetRenderer 同款,经 Swift 并发验证)。

@MainActor
public final class Live2DPetRenderer: NSObject, PetRenderer {

    public var contentLayer: CALayer { metalLayer }

    /// Live2D 走 Cubism 自驱姿态(idle motion/呼吸/眨眼/物理由 C++ 桥每帧自管),位置固定不漫步
    /// —— 帧循环 `.selfAnimating` 分支让 PetMotionController 整段让位(漫步/爬墙如需作高级 opt-in,待后续)。
    public var driveModel: PetDriveModel { .selfAnimating }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let model: L2DLive2DModel
    private let metalLayer = CAMetalLayer()

    private var displayLink: CVDisplayLink?
    private var depthTexture: MTLTexture?
    private var lastFrameTime = CACurrentMediaTime()
    /// 显示器原生刷新率隔帧跳到 ~30Hz(与 MetalPetRenderer 同策略,降 main-actor 压力)。
    private var frameCounter: UInt64 = 0
    private static let frameStride: UInt64 = 2

    /// 用模型包的 `*.model3.json` URL 创建。Metal 不可用 / 模型加载失败 / metallib 缺 → nil
    /// (Shell 回退 placeholder)。
    public init?(model3URL: URL) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let model = L2DLive2DModel(model3Path: model3URL.path, device: device)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.model = model

        super.init()

        metalLayer.frame = CGRect(x: 0, y: 0, width: 180, height: 240)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false   // Cubism 用 offscreen/mask,须非 framebufferOnly
        metalLayer.isOpaque = false           // 透明桌宠窗口
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        startRenderLoop()
    }

    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
    }

    // MARK: - Display link(模式同 MetalPetRenderer)

    private func startRenderLoop() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let renderer = Unmanaged<Live2DPetRenderer>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in renderer.renderFrame() }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    public func pauseDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
    }

    public func resumeDisplayLink() {
        if let link = displayLink, !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
    }

    // MARK: - 帧

    private func renderFrame() {
        frameCounter &+= 1
        guard frameCounter % Self.frameStride == 0 else { return }

        let now = CACurrentMediaTime()
        // clamp 上限防 dt 尖峰:display link 暂停(host 隐藏)/系统休眠后恢复时,首帧 dt = 整段
        // 暂停时长(可数秒),原样喂 Cubism physics/motion 会跳变。100ms 足够覆盖正常掉帧。
        let dt = min(max(0.0, now - lastFrameTime), 0.1)
        lastFrameTime = now

        let scale = metalLayer.contentsScale
        let size = metalLayer.bounds.size
        let drawableSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
        ensureDepthTexture(width: Int(drawableSize.width), height: Int(drawableSize.height))

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        model.draw(in: commandBuffer, drawable: drawable, depthTexture: depthTexture,
                   width: Double(drawableSize.width), height: Double(drawableSize.height), deltaTime: dt)

        // B3 淋湿:在已渲模型上叠水渍 tint(同 command buffer、present 之前)。干则零开销。
        if wetness > 0.001 {
            wetTintPass?.encode(commandBuffer: commandBuffer, targetTexture: drawable.texture, wetness: wetness)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // D-4a:下雪时(shell 调过 currentFrameAlphaMask)把当前帧轮廓渲进离屏并读回(单独 command
        // buffer,避免与 display 帧共享 Cubism offscreen 状态;须在 display 帧 Update 之后)。
        if occluderRequested { encodeSilhouetteReadback() }
    }

    /// 深度附件(Cubism renderer 需);尺寸变化时重建。
    private func ensureDepthTexture(width: Int, height: Int) {
        if let t = depthTexture, t.width == width, t.height == height { return }
        guard width > 0, height > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        depthTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - PetRenderer(D-3b 情绪态 / 速度 → Cubism 驱动)

    /// motion 组 / 表情名只读快照(加载后不变,缓存避免每次过桥取)。
    private lazy var motionGroups: [String] = model.motionGroupNames
    private lazy var expressionNames: [String] = model.expressionNames
    private var lastState: PetEmotionState?

    /// 满偏速度(px/s):达到此速度时看向偏转到 ±1。
    private static let lookFullDeflectionSpeed: CGFloat = 800.0

    public func updateForState(_ state: PetEmotionState) {
        guard state != lastState else { return }   // 仅状态切换时叠加 reaction accent
        lastState = state
        let action = Live2DEmotionMap.action(for: state, groups: motionGroups, expressions: expressionNames)
        if let group = action.motionGroup {
            model.startRandomMotion(inGroup: group, priority: Live2DMotionPriority.normal.rawValue)
        }
        if let expr = action.expression {
            model.setExpression(expr)
        }
    }

    /// 速度 → 看向移动方向(头/眼/身朝向)。屏幕 y 向下 → Cubism 向上,取反。
    /// 速度归零时回正(`_dragManager` 内部平滑趋近)。
    public func updateForVelocity(_ velocity: CGVector) {
        let k = Self.lookFullDeflectionSpeed
        let x = Float(max(-1.0, min(1.0, velocity.dx / k)))
        let y = Float(max(-1.0, min(1.0, -velocity.dy / k)))
        model.setLookTargetX(x, y: y)
    }

    // MARK: - B3 淋湿(雨中水渍 tint,Metal pass 跟随真实渲染像素)

    /// 当前淋湿程度(0..1)。`renderFrame` > 0 时叠水渍 tint。
    private var wetness: Float = 0
    /// 水渍 tint pass(MSL 运行时编译,失败则 nil → 跳过 wet tint,不阻塞渲染)。
    private lazy var wetTintPass: Live2DWetTintPass? = Live2DWetTintPass(device: device)

    /// 工作块 B3 —— 淋湿程度(0 干 .. 1 全湿)。下雨时 app 每帧 lerp 后推入,
    /// 下一帧 `renderFrame` 据此叠蓝色水渍。clamp 越界。
    public func updateForWetness(_ level: Float) {
        wetness = min(max(level, 0), 1)
    }

    // MARK: - D-4a 雪堆遮挡(Live2D 真形变轮廓 → falling-sand occluder)
    //
    // Cubism 每帧 mesh 形变,occluder mask 必须取**真实当前帧**轮廓(静态轮廓 = 凑数)。
    // 生产者/消费者:`renderFrame` 把当前帧再渲一遍进小离屏纹理(`renderSilhouette`,不再 Update,
    // 避免与 display 帧叠加成 2× 速度)→ `addCompletedHandler` 读回 alpha → 缓存 `latestMask`;
    // `currentFrameAlphaMask` 返回上一帧缓存(1 帧延迟,与 sprite 同,设计 §B1 已验证无感)。
    // 仅下雪时(shell 调 `currentFrameAlphaMask` 置位 `occluderRequested`)才渲 + 读回,无雪零开销。

    private var occluderRequested = false
    private var desiredMaskSize = (w: 0, h: 0)
    private var silhouetteTexture: MTLTexture?
    private var silhouetteDepth: MTLTexture?
    private var latestMask: PetAlphaMask?

    public func currentFrameAlphaMask(cellSize: Float, maxDim: Int) -> PetAlphaMask? {
        guard cellSize > 0, maxDim > 0 else { return nil }
        // footprint = host view 尺寸(=pet 窗口),按 cellSize 下采样到 cell 数,单边 clamp maxDim。
        // 与 sprite 路径(SpriteSheetPetRenderer.currentFrameAlphaMask)同口径,保持 occluder 一致。
        let footW = max(1.0, Double(metalLayer.bounds.width))
        let footH = max(1.0, Double(metalLayer.bounds.height))
        let w = min(maxDim, max(1, Int((footW / Double(cellSize)).rounded(.up))))
        let h = min(maxDim, max(1, Int((footH / Double(cellSize)).rounded(.up))))
        desiredMaskSize = (w, h)
        occluderRequested = true
        return latestMask   // 1 帧延迟:首帧 nil(尚无读回),次帧起为真实轮廓
    }

    /// 离屏渲当前帧轮廓 + 异步读回 alpha。在 `renderFrame` 末尾、display commit 之后调。
    private func encodeSilhouetteReadback() {
        // 单次消费:本帧渲完即归零。下雪时 shell 每帧调 `currentFrameAlphaMask` 重新置位;
        // 雪停后 shell(applyPetOccluder enabled=false)不再调 → 标志保持 false → 无雪零开销
        // (修复:此前永不归零 → 雪停后仍每帧多渲一遍 + 读回 + Task)。
        occluderRequested = false
        let (w, h) = desiredMaskSize
        guard w > 0, h > 0 else { return }
        ensureSilhouetteTextures(w: w, h: h)
        guard let target = silhouetteTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        model.renderSilhouette(in: commandBuffer, targetTexture: target,
                               depthTexture: silhouetteDepth, width: Double(w), height: Double(h))

        let bytesPerRow = w * 4
        nonisolated(unsafe) let tex = target   // MTLTexture 非 Sendable;completion 在 GPU 内部线程读回
        commandBuffer.addCompletedHandler { _ in
            var raw = [UInt8](repeating: 0, count: bytesPerRow * h)
            raw.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                tex.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
            let mask = Live2DSilhouetteExtractor.extract(bgra: raw, width: w, height: h)
            if SnowDiagnostics.isEnabled {
                let covered = mask.mask.lazy.filter { $0 > 8 }.count   // 雪 overlay 不可截 → 日志验证轮廓真产出
                SnowDiagnostics.log("live2d occluder mask \(w)x\(h) covered=\(covered)/\(w * h)")
            }
            Task { @MainActor [weak self] in self?.latestMask = mask }
        }
        commandBuffer.commit()
    }

    /// 离屏轮廓纹理(.shared 让 CPU 可 `getBytes` 读回)+ 深度,尺寸变化时重建。
    private func ensureSilhouetteTextures(w: Int, h: Int) {
        if let t = silhouetteTexture, t.width == w, t.height == h { return }
        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        cd.usage = .renderTarget
        cd.storageMode = .shared          // 统一内存:render target + CPU 读回(目标机 Apple Silicon)
        silhouetteTexture = device.makeTexture(descriptor: cd)

        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .private
        silhouetteDepth = device.makeTexture(descriptor: dd)
    }
}
