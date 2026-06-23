import AppKit
import SwiftUI

/// S3 Pin 卡片单窗 —— 一张被钉到桌面的 Markdown 卡片。
///
/// 视觉:复用 `ChatBubbleTheme` 的白底 + 深靛色 + 紧凑阴影。
/// 内容:`NSHostingView<MarkdownTextView>` 渲染原始 Markdown 源(复用 M3.2 SwiftUI 组件)。
///
/// 行为:
/// - 独立 `NSPanel`(non-activating + floating + canJoinAllSpaces),跟 Bonded
///   bubble 同层级,但**不**作为 pet child window —— pin 是"钉到桌面"语义,
///   pet 移动时 pin 不跟。
/// - `isMovableByWindowBackground = true` 让用户拖动整个 panel,
///   移动结束通过 `NSWindow.didMoveNotification` 回调 controller 持久化新 origin。
/// - 右上角 ✕ 按钮关闭(回调 controller 走 `PinStore.remove`)。
///
/// 尺寸:固定宽 320pt,高度按 SwiftUI fittingSize 自适应,clamp 到 [120, 400]pt。
@MainActor
public final class PinCardWindow {

    // MARK: - Constants

    /// 卡片宽度(包含 shadow margin)。
    public static let cardWidth: CGFloat = 320

    /// 内容最小 / 最大高度(不含 shadow margin)。
    public static let minContentHeight: CGFloat = 80
    public static let maxContentHeight: CGFloat = 360

    /// 内边距(围绕 hostingView 一圈,留给 close 按钮 + 视觉呼吸)。
    private static let contentInset: CGFloat = 12

    /// close 按钮的边长 + 距 panel 右上角的内边距。
    private static let closeButtonSize: CGFloat = 18
    private static let closeButtonInset: CGFloat = 8

    // MARK: - Stored

    public let pinID: UUID
    public let panel: NSPanel
    private let containerView: PinCardContainerView
    private let hostingView: NSHostingView<MarkdownTextView>
    private let closeButton: NSButton
    private var moveObserver: NSObjectProtocol?

    /// 用户拖动结束后(`didMoveNotification`)的回调,传新 origin。
    /// 由 controller 注入,转写到 `PinStore.updateOrigin`。
    private let onMoved: @MainActor (NSPoint) -> Void

    /// ✕ 关闭按钮点击回调。由 controller 注入。
    private let onClose: @MainActor () -> Void

    // MARK: - Init

    public init(
        pinID: UUID,
        content: String,
        origin: NSPoint,
        onMoved: @escaping @MainActor (NSPoint) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.pinID = pinID
        self.onMoved = onMoved
        self.onClose = onClose

        // 1. SwiftUI hosting view —— 复用 MarkdownTextView(无 ChoiceCard 交互)
        let rootView = MarkdownTextView(
            content: content,
            tint: Color(ChatBubbleTheme.textPrimary),
            onChoiceSelected: nil
        )
        let hosting = NSHostingView(rootView: rootView)
        // 决策 #6:禁掉 SwiftUI 反向请求 NSWindow.setFrame —— 在 CA transaction
        // commit 期间撞 setFrame 会 SIGABRT。
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        self.hostingView = hosting

        // 2. Close 按钮 —— 圆形 ✕,左上角小尺寸
        let close = NSButton(frame: .zero)
        close.bezelStyle = .regularSquare
        close.isBordered = false
        close.title = ""
        let xImage = NSImage(systemSymbolName: "xmark.circle.fill",
                             accessibilityDescription: "关闭 pin")
        close.image = xImage
        close.contentTintColor = ChatBubbleTheme.textMuted
        close.imagePosition = .imageOnly
        close.toolTip = "关闭"
        self.closeButton = close

        // 3. Container view —— 负责绘制圆角背景 + 阴影
        let container = PinCardContainerView(frame: .zero)
        self.containerView = container

        // 4. 算出窗口尺寸
        // 给 hostingView 一个 width hint 让 SwiftUI 知道 wrap 边界
        let contentWidth = Self.cardWidth - 2 * Self.contentInset - 2 * ChatBubbleTheme.shadowMargin
        hosting.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 0)
        let fitting = hosting.fittingSize
        let contentHeight = min(
            max(fitting.height, Self.minContentHeight),
            Self.maxContentHeight
        )
        let panelHeight = contentHeight
            + 2 * Self.contentInset
            + 2 * ChatBubbleTheme.shadowMargin

        let panelRect = NSRect(
            origin: origin,
            size: NSSize(width: Self.cardWidth, height: panelHeight.rounded())
        )

        // 5. NSPanel 配置 —— 跟 BondedMarkdownBubble 一致的层级和行为
        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenPetAgent Pin Card"
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
        ]
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true  // 用户可拖动整个 panel
        panel.contentView = container
        self.panel = panel

        // 6. 子视图 layout(手动 frame,避免 autoresizing 在 setFrame 期间反推)
        container.frame = NSRect(origin: .zero, size: panelRect.size)
        let margin = ChatBubbleTheme.shadowMargin
        container.contentInset = Self.contentInset
        container.cornerRadius = ChatBubbleTheme.cornerRadius
        container.fillColor = ChatBubbleTheme.cardBackground
        container.shadowColor = ChatBubbleTheme.shadowColor
        container.shadowOffset = ChatBubbleTheme.shadowOffset
        container.shadowRadius = ChatBubbleTheme.shadowRadius
        container.shadowMargin = margin

        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: margin + Self.contentInset
            ),
            hosting.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -(margin + Self.contentInset)
            ),
            hosting.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: margin + Self.contentInset
            ),
            hosting.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -(margin + Self.contentInset)
            ),
        ])

        close.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(close)
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
            close.heightAnchor.constraint(equalToConstant: Self.closeButtonSize),
            close.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -(margin + Self.closeButtonInset)
            ),
            close.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: margin + Self.closeButtonInset
            ),
        ])

        // 7. 按钮事件 —— closure-based action via target/selector trampoline
        let trampoline = ClosureActionTrampoline { [weak self] in
            self?.onClose()
        }
        // 把 trampoline 存到 panel.associated 上保活
        objc_setAssociatedObject(close, &Self.trampolineKey, trampoline, .OBJC_ASSOCIATION_RETAIN)
        close.target = trampoline
        close.action = #selector(ClosureActionTrampoline.invoke)

        // 8. 拖动监听 —— didMoveNotification 触发持久化
        installMoveObserver()
    }

    deinit {
        if let token = moveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Lifecycle

    /// 显示 panel(不抢焦点)。
    public func show() {
        panel.orderFrontRegardless()
    }

    /// 隐藏 + 摘除。controller 会在 remove 流程里调。
    public func close() {
        if let token = moveObserver {
            NotificationCenter.default.removeObserver(token)
            moveObserver = nil
        }
        panel.orderOut(nil)
    }

    /// 当前 origin(屏幕坐标系)。
    public var origin: NSPoint {
        panel.frame.origin
    }

    // MARK: - Private

    private func installMoveObserver() {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // 决策 #5: @MainActor closure 给 NotificationCenter 时用 assumeIsolated hop
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onMoved(self.panel.frame.origin)
            }
        }
    }

    /// 关联对象 key —— trampoline 保活。
    private static var trampolineKey: UInt8 = 0
}

// MARK: - PinCardContainerView (圆角背景 + shadow)

/// 容器 NSView,负责画卡片底色 + 阴影 mask。子视图(hostingView / closeButton)
/// 通过 autolayout 摆位。
@MainActor
final class PinCardContainerView: NSView {

    var cornerRadius: CGFloat = 14
    var fillColor: NSColor = .white
    var shadowColor: NSColor = .black
    var shadowOffset: CGSize = .zero
    var shadowRadius: CGFloat = 4
    var shadowMargin: CGFloat = 20
    var contentInset: CGFloat = 12

    private let bgLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func configure() {
        wantsLayer = true
        layer?.addSublayer(bgLayer)
    }

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { false }

    override func updateLayer() {
        super.updateLayer()
        let rect = bounds.insetBy(dx: shadowMargin, dy: shadowMargin)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        bgLayer.path = path
        bgLayer.frame = bounds
        bgLayer.fillColor = fillColor.cgColor
        bgLayer.shadowColor = shadowColor.cgColor
        bgLayer.shadowOffset = shadowOffset
        bgLayer.shadowRadius = shadowRadius
        bgLayer.shadowOpacity = 1.0
        bgLayer.shadowPath = path
        bgLayer.masksToBounds = false
    }
}

// MARK: - ClosureActionTrampoline
//
// NSButton.target/action 需要 NSObject + Selector。Swift closure 不能直接当 target,
// 用一个小 trampoline 转一道。controller 通过 associated object 保活 trampoline。

@MainActor
private final class ClosureActionTrampoline: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}
