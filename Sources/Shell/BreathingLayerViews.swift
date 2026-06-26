import AppKit
import SwiftUI

// 「呼吸」动效的 CALayer 实现 —— 替代 SwiftUI `withAnimation(.repeatForever)`。
//
// 为什么不用 SwiftUI 动画:`.repeatForever` 在 onAppear 给 `@State` 注册一个时间驱动的
// AttributeGraph 属性,使整棵承载它的 view graph(ChatCardView)每个 runloop flush 都被标脏
// → 真 runTransaction 重评整棵卡片树(实测开聊天卡片时 SwiftUI flush 占主线程 ~3800 样本 /
// 进程 ~65% CPU)。改用 CALayer + CABasicAnimation:动画在 render server(CA)跑,**完全不进
// SwiftUI AttributeGraph**,卡片树静止时 flush 立即空返回。详见 docs/lessons-learned §6.4。
//
// 动画在 `viewDidMoveToWindow`(进窗口)启动、离窗口时移除,且加 `animation(forKey:)==nil` 闸
// 避免重复 layout 反复重启(视觉抖动)。离屏 measuring 的 NSHostingView 无 window → 不会起动画。

/// 进行中脉冲点(呼吸式 accent 圆点,6×6)。
struct PulseDot: NSViewRepresentable {
    func makeNSView(context: Context) -> BreathingDotNSView { BreathingDotNSView() }
    func updateNSView(_ nsView: BreathingDotNSView, context: Context) {}
}

/// accent 圆点,opacity 在 0.95↔0.3 间 0.7s 呼吸往返(CA 驱动)。
final class BreathingDotNSView: NSView {
    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.backgroundColor = ChatBubbleTheme.accent.cgColor
        dot.cornerRadius = 3   // 6×6 → 圆
        dot.opacity = 0.95
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 6) }

    override func layout() {
        super.layout()
        dot.frame = CGRect(x: (bounds.width - 6) / 2, y: (bounds.height - 6) / 2, width: 6, height: 6)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { dot.removeAnimation(forKey: "breathe"); return }
        guard dot.animation(forKey: "breathe") == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.95
        a.toValue = 0.3
        a.duration = 0.7
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(a, forKey: "breathe")
    }
}

/// 源行 halo:accent 脉冲圆环(白托底环 + teal 内环),呼吸式在「细+亮 ↔ 粗+淡」间往返,
/// 指示「正在侧宽卡里看这一行」。`isHighlighted` 时以 overlay 插入,收起侧卡即移除。
struct HaloRing: NSViewRepresentable {
    func makeNSView(context: Context) -> BreathingHaloNSView { BreathingHaloNSView() }
    func updateNSView(_ nsView: BreathingHaloNSView, context: Context) {}
}

/// 双层 rounded-rect 描边环,opacity+lineWidth 在 `AnimTok.breathe`(1.8s)呼吸往返(CA 驱动)。
final class BreathingHaloNSView: NSView {
    private let outer = CAShapeLayer()   // 白环托底(让 selection 在 accent 橙底 user 行也可见)
    private let inner = CAShapeLayer()   // teal 内环(白/奶白底 assistant 行清晰)
    /// 与 `ChatCardTheme.selectionHalo`(Color(red:0,green:0.702,blue:0.643))等值。
    private static let teal = NSColor(srgbRed: 0.0, green: 0.702, blue: 0.643, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outer.fillColor = nil
        outer.strokeColor = NSColor.white.cgColor
        outer.opacity = 0.9
        outer.lineWidth = 3
        inner.fillColor = nil
        inner.strokeColor = Self.teal.cgColor
        inner.opacity = 1.0
        inner.lineWidth = 1.5
        layer?.addSublayer(outer)
        layer?.addSublayer(inner)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        for l in [outer, inner] { l.frame = bounds; l.path = path }
        startBreathing()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startBreathing() }
        else { outer.removeAnimation(forKey: "breathe"); inner.removeAnimation(forKey: "breathe") }
    }

    private func startBreathing() {
        guard window != nil else { return }
        // 与旧 SwiftUI HaloRing 同参:outer opacity 0.9↔0.5 + lineWidth 3↔4;inner opacity 1.0↔0.4 + lineWidth 1.5↔2。
        addBreathe(to: outer, opacityTo: 0.5, lineWidthTo: 4)
        addBreathe(to: inner, opacityTo: 0.4, lineWidthTo: 2)
    }

    private func addBreathe(to l: CAShapeLayer, opacityTo: Float, lineWidthTo: CGFloat) {
        guard l.animation(forKey: "breathe") == nil else { return }
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = l.opacity
        op.toValue = opacityTo
        let lw = CABasicAnimation(keyPath: "lineWidth")
        lw.fromValue = l.lineWidth
        lw.toValue = lineWidthTo
        let group = CAAnimationGroup()
        group.animations = [op, lw]
        group.duration = AnimTok.breathe
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(group, forKey: "breathe")
    }
}
