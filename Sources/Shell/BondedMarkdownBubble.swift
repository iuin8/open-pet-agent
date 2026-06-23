import AppKit
import SwiftUI

/// Bonded 链中的 **assistant 富文本气泡** —— 内容区是 `NSHostingView<MarkdownTextView>`,
/// 支持 Markdown 富文本(bold / italic / inline code / 代码块 / 编号 ChoiceCard /
/// 表格 / header / 分隔线)。
///
/// 与 `BondedBubble`(单行 NSTextField label,user 输入与短消息用)平行存在:
/// - `BondedBubbleChain.appendUserMessage` 仍创建 `BondedBubble`
/// - `BondedBubbleChain.appendAssistantReply` 创建 `BondedMarkdownBubble`
/// - 两者都 conform `BondedBubblePresenting`,chain 内部统一存放
///
/// 关键差异:
/// - **可变 panel 尺寸**:每次 `setText` 后用 `hostingView.fittingSize` 重算 panel
///   `frame` + reposition。BondedBubble panel 是 init 时一次性算定,只支持单行。
/// - **SwiftUI 嵌入**:OpenPetAgent 唯一使用 SwiftUI 的子视图层(via NSHostingView)。
///   决策见 docs/companion-features-roadmap.md M3 方案 B。
@MainActor
public final class BondedMarkdownBubble: BondedBubblePresenting {

    // MARK: - Constants

    /// 内容区(不含 shadow margin)宽度下限 —— 短文本/单字回复也保持手感。
    public static let minContentWidth: CGFloat = 96
    /// 内容区宽度上限 —— 超过后 SwiftUI 自动换行,代码块横向滚动。
    /// 比 BondedBubble 的 240 略大,给代码块 / 表格更多展示空间。
    public static let maxContentWidth: CGFloat = 320
    /// 内容区高度下限。短文本时不至于成一条线。
    public static let minContentHeight: CGFloat = 40

    // MARK: - Stored

    public let kind: BondedBubble.Kind = .assistantReply
    public let panel: ChatBubblePanel
    public let bubbleView: BondedMarkdownBubbleView
    private weak var parentWindow: NSWindow?
    private var currentOffsetY: CGFloat = 0
    private var parentMoveObserver: NSObjectProtocol?

    /// 当前显示的 Markdown 源文本(`BondedBubblePresenting` conformance)。
    /// 由 init / `setText` 写入,测试断言 streaming 累积内容用。
    public private(set) var currentText: String = ""

    /// tail 在底边的百分比 —— 转发 `bubbleView.tailPercent`。
    public var tailPercent: CGFloat { bubbleView.tailPercent }

    /// tail 朝向 —— 转发 `bubbleView.bubbleTailSide`（主动建议气泡顶部装不下翻转为 `.top`）。
    public var tailSide: SpeechBubbleTailSide { bubbleView.bubbleTailSide }

    /// 是否为 pet 主动建议气泡。true 时 reposition 走「屏幕 clamp + tail 动态指向 pet」。
    private let isProactive: Bool

    // MARK: - Init

    /// - Parameters:
    ///   - text: 初始 Markdown 源文本(可为空,后续 `setText` 流式增量)。
    ///   - parent: pet 窗口。气泡 child window 挂在上面跟随 pet 移动。
    ///   - onChoiceSelected: 用户点击 ChoiceCard 时回调(传内容)。nil 时
    ///     ChoiceCard 退化为普通编号列表展示,无点击效果。
    ///   - isProactive: 是否为 pet 主动建议气泡。true 时换暖染色背景 + accent
    ///     橙细描边区分于用户问的中性白气泡；false（默认）几何与视觉 100% 不变。
    public init(
        text: String,
        attachedTo parent: NSWindow,
        onChoiceSelected: ((String) -> Void)? = nil,
        isProactive: Bool = false
    ) {
        self.parentWindow = parent
        self.currentText = text
        self.isProactive = isProactive

        let view = BondedMarkdownBubbleView(
            markdown: text,
            maxWidth: Self.maxContentWidth,
            tailPercent: BondedBubble.assistantTailPercent,
            onChoiceSelected: onChoiceSelected,
            isProactive: isProactive
        )
        self.bubbleView = view

        let contentSize = view.computeContentSize()
        let panelSize = Self.panelSize(forContent: contentSize)

        let panel = ChatBubblePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenPetAgent Bonded Markdown Bubble"
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isExcludedFromWindowsMenu = true
        // ChoiceCard 要可点击 → 不能 ignoresMouseEvents。但桌宠 drag 要穿透
        // 整片 SwiftUI 视图之外的区域(margin / tail / 圆角外)。
        // BondedBubbleView 自身的 hit-test 由 SwiftUI 内部处理(button 区域接事件,
        // 其他区域不接)。NSPanel 不 ignoresMouseEvents 让 button 可点。
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.alphaValue = 0

        view.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = view

        self.panel = panel

        parent.addChildWindow(panel, ordered: .above)
        repositionRelativeTo(parent, offsetY: 0)

        installParentMoveObserver(parent: parent)
    }

    deinit {
        if let token = parentMoveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - BondedBubblePresenting

    /// 更新 Markdown 内容。每次调用都重新计算 panel 尺寸,SwiftUI 视图自动
    /// re-render(NSHostingView.rootView 重新赋值即可)。
    public func setText(_ text: String) {
        currentText = text
        bubbleView.updateMarkdown(text)
        resizePanelToContent()
    }

    public func show() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.snappy
            ctx.allowsImplicitAnimation = false
            panel.animator().alphaValue = 1.0
        }
    }

    public func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.smooth
            ctx.allowsImplicitAnimation = false
            panel.animator().alphaValue = 0.0
        }
    }

    /// x 中心对齐 pet 中心,y 让 panel 底缘略低于 pet 顶 + offsetY。
    /// **主动建议气泡**额外做：屏幕左右边缘 clamp（防气泡出屏）+ tail 动态指向 pet
    /// （气泡因 clamp 左右平移后,尖尖按 pet 实际位置重算 tailPercent 继续戳中 pet）。
    public func repositionRelativeTo(_ parent: NSWindow, offsetY: CGFloat = 0) {
        currentOffsetY = offsetY
        let parentFrame = parent.frame
        let panelW = panel.frame.width
        let panelH = panel.frame.height
        let petMidX = parentFrame.midX
        var originX = petMidX - panelW / 2
        // 默认：气泡在 pet 上方，底缘略低于 pet 顶（tail 朝下）。
        var originY = parentFrame.maxY - 4 + offsetY

        guard isProactive else {
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
            return
        }

        // 屏幕左右 clamp（max(minX, min(x, maxX-w))），留 8pt 边距。
        let pad: CGFloat = 8
        if let screen = parent.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            if vis.width > panelW + 2 * pad {
                originX = max(vis.minX + pad, min(originX, vis.maxX - panelW - pad))
            }
            // **Y 翻转**：气泡在 pet 上方若顶出屏幕上缘 → 翻到 pet 下方（tail 朝上）。
            let topIfAbove = originY + panelH                 // 上方摆放时气泡顶缘
            if topIfAbove > vis.maxY - pad,
               parentFrame.minY - panelH - pad >= vis.minY {  // 且下方放得下
                bubbleView.setTailSide(.top)
                originY = parentFrame.minY + 4 - panelH        // 气泡顶缘略高于 pet 底（tail 朝上戳 pet）
            } else {
                bubbleView.setTailSide(.bottom)
                // 上方摆放时也别顶出上缘（下方放不下的兜底）。
                originY = min(originY, vis.maxY - pad - panelH)
            }
        }

        // tail 动态指向 pet：tailPercent = (pet 中心 - 气泡内容左缘) / 内容宽度。
        let margin = ChatBubbleTheme.shadowMargin
        let contentW = max(panelW - 2 * margin, 1)
        let rawPercent = (petMidX - (originX + margin)) / contentW
        // clamp 防 tail 落到圆角/边角外（留 r + tailW/2 的边）。
        let tailEdge = (ChatBubbleTheme.cornerRadius + ChatBubbleTheme.tailWidth / 2) / contentW
        bubbleView.setTailPercent(max(tailEdge, min(rawPercent, 1 - tailEdge)))

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - Sizing

    /// 用 SwiftUI fittingSize 算出内容区 size,加 shadow margin 后即 panel size。
    public static func panelSize(forContent content: NSSize) -> NSSize {
        let margin = ChatBubbleTheme.shadowMargin
        return NSSize(
            width: content.width + 2 * margin,
            height: content.height + 2 * margin
        )
    }

    /// 重算 panel 尺寸并 reposition(保持 offsetY)。
    /// streaming token 累积时频繁调用,SwiftUI fittingSize 是 O(layout),性能 OK。
    private func resizePanelToContent() {
        let contentSize = bubbleView.computeContentSize()
        let newPanelSize = Self.panelSize(forContent: contentSize)

        var frame = panel.frame
        // 保持左下角不变是错的 —— 我们希望 panel 中心跟着 pet 中心走。
        // 因此先设 size,再走 reposition 重算 origin。
        frame.size = newPanelSize
        panel.setFrame(frame, display: true)
        bubbleView.frame = NSRect(origin: .zero, size: newPanelSize)
        bubbleView.needsDisplay = true
        if let parent = parentWindow {
            repositionRelativeTo(parent, offsetY: currentOffsetY)
        }
    }

    // MARK: - Parent-move observer (与 BondedBubble 同模式)

    private func installParentMoveObserver(parent: NSWindow) {
        parentMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parent,
            queue: .main
        ) { [weak self, weak parent] _ in
            MainActor.assumeIsolated {
                guard let self, let parent else { return }
                self.repositionRelativeTo(parent, offsetY: self.currentOffsetY)
            }
        }
    }
}

// MARK: - BondedMarkdownBubbleView (SpeechBubbleShape mask + NSHostingView)

/// NSView 子类,持有 NSHostingView<MarkdownTextView> + 绘制 SpeechBubbleShape
/// mask + shadow。镜像 `BondedBubbleView` 的 mask / shadowPath / isFlipped 模式,
/// 差异是内容区是 SwiftUI hostingView 而非 NSTextField。
@MainActor
public final class BondedMarkdownBubbleView: NSView {

    private let hostingView: NSHostingView<MarkdownTextView>
    private let bubbleMaskLayer = CAShapeLayer()
    /// 主动建议气泡的 accent 橙描边 layer（仅 isProactive 时挂上 path）。
    private let borderLayer = CAShapeLayer()

    /// 是否为 pet 主动建议气泡 —— 决定背景染色 + 是否画 accent 描边。
    private let isProactive: Bool

    /// tail 在底边的百分比(assistant 默认 0.20 → tail 偏左)。主动建议气泡在 reposition
    /// 时按 pet 实际位置动态改写（让尖尖始终指向 pet），故为 var。
    public private(set) var tailPercent: CGFloat

    /// 动态改写 tail 横向位置(主动建议气泡屏幕 clamp 后让尖尖继续指 pet)。变化才重绘。
    func setTailPercent(_ p: CGFloat) {
        guard abs(p - tailPercent) > 0.001 else { return }
        tailPercent = p
        needsDisplay = true
    }

    /// tail 朝向。默认 `.bottom`(气泡在 pet 上方、尖尖朝下)。主动建议气泡在 pet 贴屏幕顶
    /// 装不下时翻转为 `.top`(气泡改到 pet 下方、尖尖朝上)。仅主动建议气泡用 symmetric tail
    /// 预留(见 configure)，故翻转只换形状不动布局。
    private(set) var bubbleTailSide: SpeechBubbleTailSide = .bottom

    /// 动态翻转 tail 朝向(主动建议气泡顶部装不下时改到 pet 下方)。变化才重绘 + 重排内边距
    /// （tail 预留换到新尾巴侧 → 文字始终居中在卡片区）。
    func setTailSide(_ side: SpeechBubbleTailSide) {
        guard side != bubbleTailSide else { return }
        bubbleTailSide = side
        let (top, bottom) = tailInsets()
        hostingTopConstraint?.constant = top
        hostingBottomConstraint?.constant = -bottom
        needsDisplay = true
    }

    /// hostingView 的上/下内边距：tail 预留只放在尾巴那一侧（非对称），其余侧只留 margin+6。
    /// chat（非 proactive）永远 .bottom 尾，等价于原行为。
    private func tailInsets() -> (top: CGFloat, bottom: CGFloat) {
        let margin = ChatBubbleTheme.shadowMargin
        let base = margin + 6
        let tailTop = (isProactive && bubbleTailSide == .top) ? tailHeight : 0
        let tailBottom = (bubbleTailSide == .bottom) ? tailHeight : 0
        return (base + tailTop, base + tailBottom)
    }

    private var hostingTopConstraint: NSLayoutConstraint?
    private var hostingBottomConstraint: NSLayoutConstraint?

    /// 内容区宽度上限,SwiftUI 自动 wrap;hostingView fittingSize 不超过此值。
    private let maxContentWidth: CGFloat

    /// 当前 onChoiceSelected callback,updateMarkdown 时复用注入到新 rootView。
    private var onChoiceSelected: ((String) -> Void)?

    /// 当前文本。主动建议气泡（纯短句、无 markdown 块）走 Core Text
    /// `NSAttributedString.boundingRect` 确定性测高，不依赖 SwiftUI fittingSize。
    private var markdownText: String

    private let cornerRadius: CGFloat = ChatBubbleTheme.cornerRadius
    private let tailHeight: CGFloat = ChatBubbleTheme.tailHeight
    private let tailWidth: CGFloat = ChatBubbleTheme.tailWidth

    init(
        markdown: String,
        maxWidth: CGFloat,
        tailPercent: CGFloat,
        onChoiceSelected: ((String) -> Void)?,
        isProactive: Bool = false
    ) {
        self.tailPercent = tailPercent
        self.maxContentWidth = maxWidth
        self.onChoiceSelected = onChoiceSelected
        self.isProactive = isProactive
        self.markdownText = markdown

        let rootView = MarkdownTextView(
            content: markdown,
            tint: Color(ChatBubbleTheme.textPrimary),
            maxWidth: maxWidth - 16,   // 内容换行宽度 = 渲染宽度(hostingView 比 content 区窄 16pt)
            baseFont: isProactive ? Font(ChatBubbleTheme.bodyFont) : nil,  // 渲染字体对齐 boundingRect 测量字体
            onChoiceSelected: onChoiceSelected
        )
        self.hostingView = NSHostingView(rootView: rootView)
        // 气泡是固定浅色卡（白卡 / 主动建议暖奶油），强制 .aqua 外观 → SwiftUI 语义色
        // (.primary/.secondary) 始终按浅色渲染成深色字，避免系统暗色模式下正文走白色 → 浅底白字看不清。
        hostingView.appearance = NSAppearance(named: .aqua)
        // sizingOptions = [] 防 SwiftUI 反向把 NSWindow 撑全屏（HermesPet 决策 #6）。
        // chat 富文本气泡走 fittingSize 测高（保持原状）；主动建议气泡改走 Core Text
        // boundingRect 确定性测高（见 computeContentSize），不再依赖 fittingSize。
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// 替换 rootView 触发 SwiftUI re-render。callback 沿用之前 init 注入的实例。
    func updateMarkdown(_ text: String) {
        self.markdownText = text
        let rootView = MarkdownTextView(
            content: text,
            tint: Color(ChatBubbleTheme.textPrimary),
            maxWidth: maxContentWidth - 16,   // 内容换行宽度 = 渲染宽度
            baseFont: isProactive ? Font(ChatBubbleTheme.bodyFont) : nil,  // 渲染字体对齐测量字体
            onChoiceSelected: onChoiceSelected
        )
        hostingView.rootView = rootView
    }

    /// 算内容区 size（clamp 到 [min, max]），含底部 tail 高度预留。
    ///
    /// **主动建议气泡**（纯短句）走 `proactiveContentSize()` —— Core Text
    /// `NSAttributedString.boundingRect` 确定性测高，不依赖 SwiftUI fittingSize
    /// （后者对 `NSHostingView<MarkdownTextView>` + `sizingOptions=[]` 测不出多行高，
    /// 反复踩坑 7 次的真根因）。**chat 富文本气泡**仍走 fittingSize（保持原行为）。
    func computeContentSize() -> NSSize {
        let hInset: CGFloat = 16  // hostingView 比 content 区窄 16pt（leading/trailing 各超 margin 8pt）
        if isProactive {
            return proactiveContentSize(hInset: hInset)
        }
        // chat 路径：fittingSize（原行为不变）。
        hostingView.frame = NSRect(x: 0, y: 0, width: maxContentWidth, height: 0)
        let fitting = hostingView.fittingSize
        let width = min(max(fitting.width, BondedMarkdownBubble.minContentWidth), maxContentWidth)
        let height = max(fitting.height + tailHeight + 12, BondedMarkdownBubble.minContentHeight)
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// 主动建议气泡：用 Core Text `CTFramesetterSuggestFrameSizeWithConstraints` 按渲染宽度
    /// 确定性测量纯文本「紧贴尺寸」。boundingRect 对多行文本的 `.width` 返回的是**约束宽度**
    /// 而非实际最长行宽 → 气泡偏宽、右侧留白；CTFramesetter 返回**真实最长行宽 + 换行总高**，
    /// 宽高都紧贴内容。不依赖 SwiftUI 布局时机 → 无头可测、绝不截断/留白。
    private func proactiveContentSize(hInset: CGFloat) -> NSSize {
        let renderWidth = maxContentWidth - hInset
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(
            string: markdownText,
            attributes: [.font: ChatBubbleTheme.bodyFont, .paragraphStyle: para]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        var fitRange = CFRange()
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attr.length),
            nil,
            CGSize(width: renderWidth, height: .greatestFiniteMagnitude),
            &fitRange
        )
        // 宽度：真实最长行宽（≤ renderWidth）+ hInset → content 宽度（紧贴，无右侧留白）。
        let contentWidth = min(max(ceil(fit.width) + hInset, BondedMarkdownBubble.minContentWidth), maxContentWidth)
        // 高度：换行总高 + tail 预留（仅尾巴那一侧，非对称）+ 内边距各 6 + 2pt 余量。
        // 文字居中在卡片区（panel 减去尾巴侧），不再偏向尾巴。
        let height = max(
            ceil(fit.height) + tailHeight + 12 + 2,
            BondedMarkdownBubble.minContentHeight
        )
        return NSSize(width: contentWidth.rounded(), height: height.rounded())
    }

    private func configure() {
        wantsLayer = true
        // 主动建议 → 暖染卡背景；普通 assistant → 纯白卡（像素级不变）。
        layer?.backgroundColor = (isProactive
            ? ChatBubbleTheme.proactiveCardBackground
            : ChatBubbleTheme.cardBackground).cgColor
        layer?.mask = bubbleMaskLayer

        // accent 橙描边只在主动建议时挂上（path 在 updateLayer 里随 mask 同步）。
        // 非 proactive 时 borderLayer 不 addSublayer、path 保持 nil → 视觉零变。
        if isProactive {
            borderLayer.fillColor = NSColor.clear.cgColor
            borderLayer.strokeColor = ChatBubbleTheme.proactiveBorder.cgColor
            borderLayer.lineWidth = 0.8
            layer?.addSublayer(borderLayer)
        }

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        let margin = ChatBubbleTheme.shadowMargin
        // tail 预留**只放在尾巴那一侧**（非对称）→ 文字居中在卡片区，不偏向尾巴。
        // 翻转（setTailSide）时更新这两个约束的 constant。chat 永远 .bottom。
        let (top, bottom) = tailInsets()
        let topC = hostingView.topAnchor.constraint(equalTo: topAnchor, constant: top)
        let bottomC = hostingView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottom)
        hostingTopConstraint = topC
        hostingBottomConstraint = bottomC
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin + 8),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(margin + 8)),
            topC,
            bottomC,
        ])
    }

    public override var wantsUpdateLayer: Bool { true }
    public override var isFlipped: Bool { true }

    public override func updateLayer() {
        super.updateLayer()
        let margin = ChatBubbleTheme.shadowMargin
        let bubbleRect = bounds.insetBy(dx: margin, dy: margin)
        let localPath = SpeechBubbleShape.path(
            in: CGRect(origin: .zero, size: bubbleRect.size),
            cornerRadius: cornerRadius,
            tailSide: bubbleTailSide,
            tailPercent: tailPercent,
            tailHeight: tailHeight,
            tailWidth: tailWidth
        )
        var xform = CGAffineTransform(translationX: bubbleRect.minX, y: bubbleRect.minY)
        let path = localPath.copy(using: &xform) ?? localPath
        bubbleMaskLayer.path = path
        bubbleMaskLayer.frame = bounds
        // 主动建议描边：与 mask / shadowPath 同 path（含 tail），随尺寸刷新。
        if isProactive {
            borderLayer.path = path
            borderLayer.frame = bounds
        }
        layer?.shadowPath = path
        layer?.shadowColor = ChatBubbleTheme.shadowColor.cgColor
        layer?.shadowOffset = ChatBubbleTheme.shadowOffset
        layer?.shadowRadius = ChatBubbleTheme.shadowRadius
        layer?.shadowOpacity = 1.0
        layer?.masksToBounds = false
    }
}
