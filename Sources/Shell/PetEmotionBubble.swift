import AppKit
import Orchestrator

/// Tiny speech bubble that floats above the pet and reflects the current
/// `ChatBehaviorState` as a one-or-two-character emotional cue ("嗯？" /
/// "想想…" / "好啦" / "嗯？？"). The big chat panel handles long replies;
/// this is the "桌宠灵魂" channel — the pet *reacts* without stealing the
/// stage.
///
/// Implementation:
/// - Hosted in its own `ChatBubblePanel` (same `.nonactivatingPanel`
///   pattern as the chat bubble — ignores mouse, never grabs focus).
/// - Attached as a *child window* of the pet window so it follows the pet
///   when the user drags or the runtime updates the pet's position. No
///   manual reposition loop required.
/// - Driven by `ChatBehaviorStateMachine.onStateChanged`. `.idle` hides
///   the bubble; every other state shows the matching emotion text.
@MainActor
public final class PetEmotionBubble {

    // MARK: - State → text mapping

    /// Returns the bubble copy for `state`, or `nil` to indicate the
    /// bubble should be hidden. Centralised so tests can verify the
    /// mapping without a window.
    public static func text(for state: ChatBehaviorState) -> String? {
        switch state {
        case .idle:     return nil
        case .watching: return "嗯？"
        case .thinking: return "想想…"
        case .talking:  return "好啦"
        case .confused: return "嗯？？"
        }
    }

    // MARK: - Stored

    public let panel: ChatBubblePanel
    private let bubbleView: PetEmotionBubbleView
    private weak var parentWindow: NSWindow?

    // MARK: - Init

    public init(attachedTo parent: NSWindow) {
        self.parentWindow = parent

        let bubbleSize = NSSize(width: 96, height: 32)
        let margin = ChatBubbleTheme.shadowMargin
        let size = NSSize(
            width: bubbleSize.width + 2 * margin,
            height: bubbleSize.height + 2 * margin
        )

        let panel = ChatBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenPetAgent Pet Emotion"
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
        // Critical: never intercept clicks. The pet sits under this panel
        // and must keep getting mouseDown for drag + showChat.
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.alphaValue = 0  // start hidden; first state change fades in

        let view = PetEmotionBubbleView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = view

        self.panel = panel
        self.bubbleView = view

        parent.addChildWindow(panel, ordered: .above)
        repositionAbovePet()
    }

    // MARK: - Public API

    /// Apply the bubble copy for `state`, fading in or out as needed.
    public func updateForState(_ state: ChatBehaviorState) {
        if let copy = Self.text(for: state) {
            show(text: copy)
        } else {
            hide()
        }
    }

    /// Re-position the panel above the parent window. Called on init and
    /// whenever the pet moves enough that the child-window auto-follow
    /// isn't sufficient (e.g. after `setFrameOrigin` programmatic moves).
    public func repositionAbovePet() {
        guard let parent = parentWindow else { return }
        let petFrame = parent.frame
        let panelFrame = panel.frame
        // Centre horizontally over the pet; place the panel so the
        // bubble's tail sits just above the pet's head. The `-4` offset
        // overlaps the tail tip with the pet top by a couple of pixels
        // so the bubble looks "connected" rather than floating away.
        let originX = petFrame.midX - panelFrame.width / 2
        let originY = petFrame.maxY - 4
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - Internal helpers

    private func show(text: String) {
        bubbleView.setText(text)
        repositionAbovePet()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.snappy
            ctx.allowsImplicitAnimation = false
            panel.animator().alphaValue = 1.0
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AnimTok.smooth
            ctx.allowsImplicitAnimation = false
            panel.animator().alphaValue = 0.0
        }
    }
}

// MARK: - PetEmotionBubbleView

/// Tiny `NSView` rendering the emotion bubble's background, mask, shadow,
/// and centred label. Mirrors `ChatShellView`'s shadow-path + mask pattern
/// but with smaller dimensions and a single label child.
@MainActor
final class PetEmotionBubbleView: NSView {

    private let label = NSTextField(labelWithString: "")
    private let bubbleMaskLayer = CAShapeLayer()

    // Compact bubble — corner 10 (`cornerRadiusSmall`), tail 8h × 14w.
    // Tail dimensions intentionally match the chat bubble (`tailHeight`/
    // `tailWidth`) so the two surfaces feel like one design language; only
    // the corner radius differs to keep this reading as a "label" not a
    // "panel" (chat = 14, emotion = 10).
    private let cornerRadius: CGFloat = ChatBubbleTheme.cornerRadiusSmall
    private let tailHeight: CGFloat = ChatBubbleTheme.tailHeight
    private let tailWidth: CGFloat = ChatBubbleTheme.tailWidth

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func setText(_ text: String) {
        label.stringValue = text
    }

    /// Test accessor.
    var currentText: String { label.stringValue }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = ChatBubbleTheme.cardBackground.cgColor
        layer?.mask = bubbleMaskLayer

        label.font = ChatBubbleTheme.captionFont
        label.textColor = ChatBubbleTheme.textPrimary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let margin = ChatBubbleTheme.shadowMargin
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Vertically centre the label inside the bubble area
            // (the bubble occupies `bounds.insetBy(margin, margin)` and
            // we want to bias slightly up so the tail doesn't crowd the
            // text — half-tail-height up from centre).
            label.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -tailHeight / 2
            ),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin + 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(margin + 6)),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    /// See `ChatShellView.isFlipped` — same fix. Without `isFlipped`, the
    /// `.bottom` tail (intended to point down at the pet) renders pointing
    /// up away from the pet because NSView default geometry has y=0 at
    /// the visual bottom, opposite of the path math.
    override var isFlipped: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let margin = ChatBubbleTheme.shadowMargin
        let bubbleRect = bounds.insetBy(dx: margin, dy: margin)
        let localPath = SpeechBubbleShape.path(
            in: CGRect(origin: .zero, size: bubbleRect.size),
            cornerRadius: cornerRadius,
            tailSide: .bottom,
            tailPercent: 0.5,
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
