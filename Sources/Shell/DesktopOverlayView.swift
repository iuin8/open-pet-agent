import AppKit
import Rendering

@MainActor
public final class DesktopOverlayView: NSView {
    public private(set) var isSnowPlaceholderVisible = false

    public var visibleSnowflakeCount: Int {
        snowflakeLabels.filter { $0.isHidden == false }.count
    }

    public private(set) var isSnowPlaceholderAnimating = false

    public var firstSnowflakeFrame: NSRect {
        snowflakeLabels[0].frame
    }

    public func snowflakeFrame(at index: Int) -> NSRect {
        snowflakeLabels[index].frame
    }

    private static let snowflakeGlyphs: [String] = ["❄", "❅", "❆", "❄︎", "✻", "•"]

    fileprivate static func snowflakeFontSize(for index: Int) -> CGFloat {
        7 + CGFloat(index % 4) * 1.5
    }

    public var snowflakeFontSizesForTesting: [CGFloat] {
        (0..<snowflakeLabels.count).map { Self.snowflakeFontSize(for: $0) }
    }
    private let snowflakeLabels: [NSTextField] = (0..<240).map { index in
        NSTextField(labelWithString: DesktopOverlayView.snowflakeGlyphs[index % DesktopOverlayView.snowflakeGlyphs.count])
    }
    private var animationFrameIndex: UInt32 = 0
    public private(set) var metalSnowLayerView: MetalSnowOverlayView?

    public var snowflakeGlyphsForTesting: [String] {
        snowflakeLabels.map(\.stringValue)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    public func setSnowPlaceholderVisible(_ isVisible: Bool, particles: [CGPoint] = []) {
        isSnowPlaceholderVisible = isVisible
        let metalActive = metalSnowLayerView != nil
        for (index, snowflakeLabel) in snowflakeLabels.enumerated() {
            let hasParticle = index < particles.count
            // Hide NSTextField glyph layer entirely when Metal renders the snow.
            // Otherwise they overlap with Metal's soft-edge points (NSTextField
            // glyphs sit at runtime point coordinates, Metal points sit in
            // bounds-space too — both visible at once reads as a double-image).
            snowflakeLabel.isHidden = metalActive || !isVisible || !hasParticle
            if isVisible && hasParticle {
                snowflakeLabel.setFrameOrigin(clampedSnowflakeOrigin(particles[index], for: snowflakeLabel))
            }
        }
        metalSnowLayerView?.isHidden = !isVisible

        if isVisible {
            startSnowPlaceholderAnimation()
        } else {
            stopSnowPlaceholderAnimation()
        }
    }

    // MARK: - Falling-sand CA path（唯一雪路径）

    /// 开/关 falling-sand 路径。on 时按 cellSize 建 driver（复用 overlay 的 device）。
    public func setFallingSandEnabled(_ enabled: Bool, cellSize: Float) {
        guard let metalView = metalSnowLayerView else { return }
        if enabled {
            metalView.enableFallingSandMode(cellSize: cellSize)
            for label in snowflakeLabels { label.isHidden = true }
        } else {
            metalView.disableFallingSandMode()
        }
    }

    /// 当前 falling-sand 网格尺寸（算窗口 floor 用）。
    public var fallingSandGridSize: (width: Int, height: Int)? {
        metalSnowLayerView?.fallingSandGridSize
    }

    /// 每帧按天气写 spawn/温度 + 窗口 floor + 触发重绘。
    public func tickFallingSand(spawnSnow: Bool, spawnRain: Bool, ambient: Float, rects: [SIMD4<Float>]) {
        metalSnowLayerView?.tickFallingSand(
            spawnSnow: spawnSnow, spawnRain: spawnRain, ambient: ambient, rects: rects)
    }

    /// 设置可调物理参数（设置 → 调试 面板）。
    public func setFallingSandTuning(_ tuning: FallingSandTuning) {
        metalSnowLayerView?.setFallingSandTuning(tuning)
    }

    /// 工作块 B1 —— 转发 pet alpha occluder（雪堆 pet 身上）。mask nil = 关。
    public func uploadPetOccluder(_ mask: PetAlphaMask?, originCellX: Int, originCellY: Int) {
        metalSnowLayerView?.uploadPetOccluder(mask, originCellX: originCellX, originCellY: originCellY)
    }

    /// 工作块 B2 —— 转发 pet 扬雪（AABB cell + 横速度）。sweep nil = 关。
    public func uploadPetSweep(_ sweep: FallingSandDriver.PetSweepFrame?) {
        metalSnowLayerView?.uploadPetSweep(sweep)
    }

    /// 清场：清空 falling-sand 积雪。
    public func clearFallingSand() {
        metalSnowLayerView?.clearFallingSand()
    }

    public func advanceSnowPlaceholderFrame() {
        guard isSnowPlaceholderVisible else {
            return
        }

        animationFrameIndex &+= 1
        let frameTime = Double(animationFrameIndex)

        for (index, snowflakeLabel) in snowflakeLabels.enumerated() {
            var origin = snowflakeLabel.frame.origin
            let fallSpeed = 0.6 + CGFloat(index % 5) * 0.45
            origin.y -= fallSpeed

            let driftPhase = frameTime * 0.05 + Double(index) * 0.7
            let driftAmplitude = 0.5 + CGFloat(index % 4) * 0.25
            origin.x += CGFloat(sin(driftPhase)) * driftAmplitude

            if origin.y + snowflakeLabel.frame.height < 0 {
                origin.y = bounds.height
                let respawnX = Int(animationFrameIndex &* 37 &+ UInt32(index) &* 53) % max(1, Int(bounds.width))
                origin.x = CGFloat(respawnX)
            }
            if bounds.width > 0 {
                if origin.x + snowflakeLabel.frame.width < bounds.minX {
                    origin.x = bounds.maxX - snowflakeLabel.frame.width
                } else if origin.x > bounds.maxX {
                    origin.x = bounds.minX
                }
            }
            snowflakeLabel.setFrameOrigin(origin)
        }
    }

    private func clampedSnowflakeOrigin(_ origin: CGPoint, for snowflakeLabel: NSTextField) -> CGPoint {
        let maxX = max(bounds.minX, bounds.maxX - snowflakeLabel.frame.width)
        let maxY = max(bounds.minY, bounds.maxY - snowflakeLabel.frame.height)
        return CGPoint(
            x: min(max(origin.x, bounds.minX), maxX),
            y: min(max(origin.y, bounds.minY), maxY)
        )
    }

    private func startSnowPlaceholderAnimation() {
        isSnowPlaceholderAnimating = true
    }

    private func stopSnowPlaceholderAnimation() {
        isSnowPlaceholderAnimating = false
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        if let metalView = MetalSnowOverlayView.make(frame: bounds) {
            metalView.autoresizingMask = [.width, .height]
            metalView.isHidden = true
            addSubview(metalView)
            metalSnowLayerView = metalView
        }

        for (index, snowflakeLabel) in snowflakeLabels.enumerated() {
            snowflakeLabel.font = .systemFont(
                ofSize: Self.snowflakeFontSize(for: index),
                weight: .regular
            )
            snowflakeLabel.textColor = NSColor.white.withAlphaComponent(0.55 + CGFloat(index % 3) * 0.1)
            snowflakeLabel.alignment = .center
            snowflakeLabel.sizeToFit()
            snowflakeLabel.isHidden = true
            addSubview(snowflakeLabel)
        }
    }
}
