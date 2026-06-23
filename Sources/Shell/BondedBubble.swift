import AppKit

/// 一颗 **Bonded 陪伴模式** 气泡：桌宠原位长出的弹力气泡，tail 指向桌宠下方，
/// 整轮对话垂直堆叠在 pet 头顶（详见 `docs/chat-input-redesign.md` §2）。
///
/// **A.5.3 phase 3 v2 设计**（用户拍板）：
///   - **同一列垂直堆叠** —— 所有气泡 x 对齐 pet 中心，user 紧贴 pet 头顶
///     （低位），assistant 在 user 上方（高位）。
///   - **只用 tail 区分左右** —— user (含 input + message) tail 偏右
///     (`tailPercent = 0.80`) 表"用户在右"；assistant tail 偏左
///     (`tailPercent = 0.20`) 表"AI 在左"。tail 朝向都 `.bottom`。
///   - panel 通过 child-window 关系跟随 pet 移动；同时挂
///     `NSWindow.didMoveNotification` observer 兜底，物理引擎若不走
///     `NSWindow.setFrameOrigin` 而直接位移 layer 时也能同步。
///
/// MVP 视觉范围：
///   - 静态卡片 + tail + tight shadow + 单行 label
///   - 0.15s fade in / 0.2s fade out
///   - `panel.ignoresMouseEvents = true`，桌宠 drag 必须穿透
///
/// 自动消失 + hover-pause 由 `BondedBubbleChain` 统一管理（一整轮一起消）。
@MainActor
public final class BondedBubble {

    // MARK: - Kind

    /// 气泡链里某一颗的角色定位。tail 朝向由 kind 决定。
    public enum Kind: Sendable {
        /// 旧用户输入气泡(历史命名,等价于 `.userMessage`,仍保留以维持
        /// `BondedBubble.Kind` 序列化 / 测试兼容)。用户输入入口由对话卡片
        /// `ChatCardWindowController` 承担,头顶气泡链只服务 pet 主动智能输出
        /// — 因此本 case 在新代码中不应再被创建。
        case userInput
        /// 用户发送后的静态消息气泡（tail 偏右指 pet 右下）。
        case userMessage
        /// 助手回答气泡（tail 偏左指 pet 左下方向）。
        case assistantReply
    }

    // MARK: - Layout constants

    /// 内容区最小宽度（短文本如 "嗯"、"是" 也保持手感）。
    private static let minContentWidth: CGFloat = 96
    /// 内容区最大宽度（超过即换行；后续 phase 接入"吹气球"动画时上限即此）。
    private static let maxContentWidth: CGFloat = 240
    /// 内容区高度（含底部 `ChatBubbleTheme.tailHeight` 的 tail 预留）。MVP 单行；
    /// 多行高度计算等 phase 2 wire streaming 再加。
    static let contentHeight: CGFloat = 40
    /// 左右内边距（数值匹配 PetEmotionBubble 视觉节奏）。
    private static let horizontalInset: CGFloat = 12

    /// 按 kind 算内容区高度。当前所有 kind 都带 tail，统一用 `contentHeight`
    /// （40，含 8pt tail 预留）。保留 kind 参数以维持调用点签名稳定。
    static func contentHeight(for kind: Kind) -> CGFloat {
        contentHeight
    }

    /// tail tip 落在 pet.maxY 上方的 gap（pt）。`BondedBubble` tail 指向 pet
    /// 的下方锚点，所以气泡底缘略低于 pet 顶缘几像素，让视觉"连"在 pet 上。
    static let petTopGap: CGFloat = 8

    /// userMessage / userInput 的 tailPercent。用户气泡 tail 偏右 4/5 处
    /// （底边从左数 80%），表"用户在右"。
    public static let userTailPercent: CGFloat = 0.80
    /// assistantReply 的 tailPercent。AI 气泡 tail 偏左 1/5 处
    /// （底边从左数 20%），表"AI 在左"。
    public static let assistantTailPercent: CGFloat = 0.20

    // MARK: - Stored

    public let kind: Kind
    public let tailPercent: CGFloat
    public let panel: ChatBubblePanel
    public let bubbleView: BondedBubbleView
    private weak var parentWindow: NSWindow?
    /// 当前相对 pet 头顶的垂直偏移（pt）。`appendUserMessage` 用 0，
    /// `appendAssistantReply` 由 chain 推算让 assistant 叠在 user 上方。
    /// observer 重新算位置时需要复用这个值。
    private var currentOffsetY: CGFloat = 0

    /// `NSWindow.didMoveNotification` 观察 token。pet 通过 layer / 渲染层位移
    /// （不走 `NSWindow.setFrameOrigin`）时 child-window 不自动同步——这条
    /// observer 兜底再算一次相对位置。token 在 deinit 时移除。
    private var parentMoveObserver: NSObjectProtocol?

    // MARK: - Init

    /// - Parameters:
    ///   - kind: 气泡角色。决定 tailPercent 默认值。
    ///   - text: 初始正文。后续可通过 `setText` 替换。
    ///   - parent: pet 窗口。气泡作为 child window 挂在上面，跟随 pet 移动。
    ///   - tailPercent: 可选显式指定 tail 在底边的百分比 (0..1)。nil 时按
    ///     kind 推断（userInput/userMessage → 0.80；assistantReply → 0.20）。
    public init(
        kind: Kind,
        text: String,
        attachedTo parent: NSWindow,
        tailPercent: CGFloat? = nil
    ) {
        self.kind = kind
        self.parentWindow = parent
        let resolvedTailPercent = tailPercent ?? Self.defaultTailPercent(for: kind)
        self.tailPercent = resolvedTailPercent

        let contentWidth = Self.contentWidth(forText: text)
        let bubbleSize = NSSize(width: contentWidth, height: Self.contentHeight(for: kind))
        let margin = ChatBubbleTheme.shadowMargin
        let panelSize = NSSize(
            width: bubbleSize.width + 2 * margin,
            height: bubbleSize.height + 2 * margin
        )

        let panel = ChatBubblePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenPetAgent Bonded Bubble"
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
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.alphaValue = 0

        let view = BondedBubbleView(
            frame: NSRect(origin: .zero, size: panelSize),
            kind: kind,
            tailPercent: resolvedTailPercent
        )
        view.setText(text)
        panel.contentView = view

        self.panel = panel
        self.bubbleView = view

        parent.addChildWindow(panel, ordered: .above)
        repositionRelativeTo(parent, offsetY: 0)

        installParentMoveObserver(parent: parent)
    }

    deinit {
        if let token = parentMoveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public API

    /// 替换气泡正文。MVP 不重新计算 panel 宽度（避免在 phase 1 写一半的
    /// resize 动画）—— 字宽变化由 phase 3 的"吹气球"扩张动画处理。
    public func setText(_ text: String) {
        bubbleView.setText(text)
    }

    /// 当前显示文本(`BondedBubblePresenting` conformance)。
    public var currentText: String { bubbleView.currentText }

    /// 淡入显示（`AnimTok.snappy`，对齐 PetEmotionBubble 的入场节奏）。
    public func show() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.snappy
            ctx.allowsImplicitAnimation = false
            panel.animator().alphaValue = 1.0
        }
    }

    /// 淡出隐藏（`AnimTok.smooth`，比入场略慢 —— 上浮链消失时给用户更多扫读时间）。
    public func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.smooth
            ctx.allowsImplicitAnimation = false
            panel.animator().alphaValue = 0.0
        }
    }

    /// 重新计算 panel origin（同列垂直堆叠版）。
    ///
    /// 几何：
    ///   - x：panel 中心对齐 pet 中心 → `panel.minX = pet.midX - panel.width/2`
    ///   - y：panel 底边略低于 pet 顶 (`pet.maxY - 4 + offsetY`)，offsetY 让
    ///     assistant 叠在 user 上方。`offsetY = 0` 时 tail tip 戳到 pet 顶。
    public func repositionRelativeTo(_ parent: NSWindow, offsetY: CGFloat = 0) {
        currentOffsetY = offsetY
        let parentFrame = parent.frame
        let panelFrame = panel.frame
        let originX = parentFrame.midX - panelFrame.width / 2
        let originY = parentFrame.maxY - 4 + offsetY
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - Defaults

    private static func defaultTailPercent(for kind: Kind) -> CGFloat {
        switch kind {
        case .userInput, .userMessage: return userTailPercent
        case .assistantReply: return assistantTailPercent
        }
    }

    // MARK: - Sizing

    /// 根据文本长度估算 content 宽度。MVP 是静态测量；phase 3 接"吹气球"
    /// 动画时换成 per-keystroke `NSLayoutManager` 实测宽度。
    private static func contentWidth(forText text: String) -> CGFloat {
        let font = ChatBubbleTheme.bodyFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes).width
        let withPadding = measured + 2 * horizontalInset + 4
        let clamped = max(minContentWidth, min(maxContentWidth, withPadding))
        return clamped.rounded()
    }

    // MARK: - Parent-move observer

    /// 监听 parent window 的 `didMoveNotification`，物理引擎不走
    /// `NSWindow.setFrameOrigin`（例如直接位移 layer）时，child window 不
    /// 自动同步。这里观察到 parent move 就 re-reposition 当前 offsetY。
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

// MARK: - BondedBubbleView

/// `NSView` 渲染 Bonded 气泡的形状、阴影、mask、正文 label。
///
/// 镜像 `PetEmotionBubbleView` 的 layer mask + shadowPath 模式 —— 差异点：
///   - 字号用 `bodyFont`（13pt，对话级），不是 `captionFont`（10pt，状态级）
///   - tail 方向永远 `.bottom`（指向下方的 pet），tailPercent 按 kind 推断
///     （user 0.80、assistant 0.20），构造时由 `BondedBubble` 注入。
///   - 圆角用 `cornerRadius`（14pt，对话级），不是 `cornerRadiusSmall`（10pt）
@MainActor
public final class BondedBubbleView: NSView {

    private let label = NSTextField(labelWithString: "")
    private let bubbleMaskLayer = CAShapeLayer()
    private let kind: BondedBubble.Kind
    /// tail 在底边的百分比。`BondedBubble` 构造时按 kind 决定并注入。
    let tailPercent: CGFloat

    private let cornerRadius: CGFloat = ChatBubbleTheme.cornerRadius
    private let tailHeight: CGFloat = ChatBubbleTheme.tailHeight
    private let tailWidth: CGFloat = ChatBubbleTheme.tailWidth

    public init(frame: NSRect, kind: BondedBubble.Kind, tailPercent: CGFloat) {
        self.kind = kind
        self.tailPercent = tailPercent
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        self.kind = .userInput
        self.tailPercent = BondedBubble.userTailPercent
        super.init(coder: coder)
        configure()
    }

    public func setText(_ text: String) {
        label.stringValue = text
    }

    public var currentText: String { label.stringValue }

    /// tail 朝向：所有 Bonded 气泡都 `.bottom`（同列垂直堆叠 + tail 永远指向
    /// 下方的 pet，靠 tailPercent 左/右偏移区分语义身份）。
    public var tailSide: SpeechBubbleTailSide { .bottom }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = ChatBubbleTheme.cardBackground.cgColor
        layer?.mask = bubbleMaskLayer

        label.font = ChatBubbleTheme.bodyFont
        label.textColor = ChatBubbleTheme.textPrimary
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let margin = ChatBubbleTheme.shadowMargin
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -tailHeight / 2
            ),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin + 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(margin + 8)),
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
            tailSide: tailSide,
            tailPercent: tailPercent,
            tailHeight: tailHeight,
            tailWidth: tailWidth
        )
        var xform = CGAffineTransform(translationX: bubbleRect.minX, y: bubbleRect.minY)
        let path = localPath.copy(using: &xform) ?? localPath
        bubbleMaskLayer.path = path
        bubbleMaskLayer.frame = bounds
        layer?.shadowPath = path
        layer?.shadowColor = ChatBubbleTheme.shadowColor.cgColor
        layer?.shadowOffset = ChatBubbleTheme.shadowOffset
        layer?.shadowRadius = ChatBubbleTheme.shadowRadius
        layer?.shadowOpacity = 1.0
        layer?.masksToBounds = false
    }
}
