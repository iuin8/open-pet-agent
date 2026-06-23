import AppKit
import CoreGraphics
import ImageIO
import PetBehavior
import QuartzCore
import Rendering

/// 原始帧驱动的 Shimeji 形象 renderer:持 `ShimejiMascotEngine`,host 每帧 `advance` 一拍 →
/// 渲当前帧图到 CALayer + 算出 NSWindow frame(host 据此摆窗口)。引擎自管 anchor + 行为,
/// 故位置每帧由引擎产出(与 PetMotionController 路径互斥,host 检测 Shimeji 形象时让位)。
///
/// 落点 App 侧胶合 target(非 Vivarium/Rendering)—— 同时用 PetRenderer(Rendering)+ 引擎
/// (PetBehavior)+ AppKit,避免 Rendering 反依赖 PetBehavior/JSC。
@MainActor
public final class ShimejiPetRenderer: PetRenderer {
    private let engine: ShimejiMascotEngine
    private let imageDirectory: URL
    private var imageCache: [String: CGImage] = [:]
    private let spriteLayer = CALayer()
    private var paused = false
    /// PF6 全局大小因子(1=原始);每帧 present 时缩放窗口+锚点。host 经 `applyScale` 注入。
    private var petScale: Double = 1

    public var contentLayer: CALayer { spriteLayer }

    /// 行为图/动作库不完整(缺 conf 或 img)→ nil,host 回退 `SpriteSheetPetRenderer`。
    public init?(packDir: URL, anchor: BehaviorPoint, environment: BehaviorEnvironment, seed: UInt64 = 0x5EED) {
        guard let pack = ShimejiRuntimePackLoader.load(packDir: packDir) else { return nil }
        imageDirectory = pack.imageDirectory
        engine = ShimejiMascotEngine(
            graph: pack.graph, library: pack.library, anchor: anchor, environment: environment, seed: seed)
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.isOpaque = false
    }

    // MARK: - PetRenderer

    /// Shimeji 情绪未映射(诚实 no-op)—— Shimeji 行为由 behaviors.xml 驱动,非 chat 情绪态。
    public func updateForState(_ state: PetEmotionState) {}

    public func pauseDisplayLink() { paused = true }
    public func resumeDisplayLink() { paused = false }

    /// 引擎自管 anchor + 每帧摆窗 → host 位置驱动让位。
    /// `drivesOwnWindowPosition` 由协议 extension 从 `driveModel` 派生（`.autonomousEngine` → true）。
    public var driveModel: PetDriveModel { .autonomousEngine }

    /// 左键按下 → Dragged 行为(抓起跟手,anchor=cursor+offset)。
    public func handlePointerDown() { engine.pointerPressed() }

    /// 左键释放 → Thrown 行为(甩出,初速=光标半衰速度)。
    public func handlePointerUp() { engine.pointerReleased() }

    /// PF6:host 注入全局大小因子(0.5–2.0)。下一帧 present 即按新 scale 出帧(绕 anchor 等比放大)。
    public func applyScale(_ scale: CGFloat) { petScale = Double(scale) }

    // MARK: - host 驱动

    /// host 每帧调:tick 引擎一拍 → 渲当前帧 + 返回 NSWindow frame(bottom-origin)。
    /// 暂停时返回 nil(host 不动窗口)。
    public func advance(environment: BehaviorEnvironment) -> CGRect? {
        guard !paused else { return nil }
        let frame = engine.tick(environment: environment)
        return present(frame, screenHeight: environment.screen.bottom)
    }

    /// 当前世界 anchor(host 出屏/诊断用)。
    public var anchor: BehaviorPoint { engine.anchor }
    public var behaviorName: String? { engine.behaviorName }

    // MARK: - 多宠互动(Hug 等)host 协调接口

    /// 当前广播的 affordance(host 把广播者匹配给扫描者的 scanTarget)。
    public var offeredAffordance: String? { engine.offeredAffordance }
    /// 当前寻找的 affordance(host 据此匹配广播者)。
    public var seekingAffordance: String? { engine.seekingAffordance }
    /// 配对到达后,host 取出「目标 pet id + 应切到的行为」→ 对目标 renderer 调 `triggerBehavior`。读即清。
    public func consumeOutgoingPairing() -> (targetID: String, behavior: String)? { engine.consumeOutgoingPairing() }
    /// host 强制本 pet 切到指定行为(配对:目标被切到 TargetBehavior)。
    public func triggerBehavior(named name: String) { engine.triggerBehavior(named: name) }

    // MARK: - 渲染

    private func present(_ frame: ShimejiMascotFrame, screenHeight: Double) -> CGRect? {
        // 选图:lookRight 且有专用右图 → 用右图(锚点不镜像);lookRight 无右图 → 左图水平翻转 + 锚点 x 镜像。
        let useRight = frame.lookRight && frame.imageRight != nil
        let mirror = frame.lookRight && frame.imageRight == nil
        let baseName = useRight ? frame.imageRight : frame.image
        guard let baseName, let base = loadImage(baseName) else { return nil }   // 无图保持上帧
        let display = mirror ? (flippedHorizontally(base) ?? base) : base
        spriteLayer.contents = display

        let w = Double(base.width), h = Double(base.height)
        let anchorX = mirror ? (w - frame.imageAnchorX) : frame.imageAnchorX
        return ShimejiWindowGeometry.windowFrame(
            anchor: frame.anchor, imageAnchorX: anchorX, imageAnchorY: frame.imageAnchorY,
            imageWidth: w, imageHeight: h, screenHeight: screenHeight, scale: petScale)
    }

    private func loadImage(_ name: String) -> CGImage? {
        if let cached = imageCache[name] { return cached }
        let url = imageDirectory.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        imageCache[name] = img
        return img
    }

    /// 水平翻转(左向原图 → 右向显示)。失败返回 nil(调用方退回原图)。
    private func flippedHorizontally(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
