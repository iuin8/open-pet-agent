import AppKit
import Rendering
import RuntimeBridge

@MainActor
public final class ChatShellView: NSView {
    public typealias ReplyHandler = @MainActor (String) async -> String

    /// Read-only rendered conversation. Each completed turn appends to the
    /// transcript so the user can scroll through the full history — earlier
    /// versions overwrote the field on every send, leaving only the latest
    /// turn visible. Internally the view tracks committed turns plus an
    /// in-progress streaming turn separately.
    public var transcript: String { renderedTranscript }

    /// Initial greeting shown until the user sends their first message.
    private static let initialGreeting = "OpenPetAgent 已就绪。"

    /// Committed (user, assistant) pairs in chronological order. The view
    /// rebuilds `renderedTranscript` from this list every update.
    private var historyTurns: [(user: String, assistant: String)] = []

    /// The currently streaming turn, if any. Cleared once the stream
    /// finishes and the turn is pushed into `historyTurns`.
    private var streamingTurn: (user: String, assistant: String)?

    private var renderedTranscript: String = ChatShellView.initialGreeting {
        didSet {
            transcriptTextView.string = renderedTranscript
            // Auto-scroll to bottom so the latest streaming token / long
            // reply is always in view. Without this, long answers vanish
            // below the fold and the user has to scroll manually each turn.
            transcriptTextView.scrollToEndOfDocument(nil)
        }
    }

    private func refreshTranscript() {
        if historyTurns.isEmpty && streamingTurn == nil {
            renderedTranscript = Self.initialGreeting
            return
        }
        var blocks: [String] = []
        blocks.reserveCapacity(historyTurns.count + 1)
        for turn in historyTurns {
            blocks.append("你：\(turn.user)\nOpenPetAgent：\(turn.assistant)")
        }
        if let streaming = streamingTurn {
            blocks.append("你：\(streaming.user)\nOpenPetAgent：\(streaming.assistant)")
        }
        renderedTranscript = blocks.joined(separator: "\n\n")
    }

    public var inputText: String {
        get { inputField.stringValue }
        set { inputField.stringValue = newValue }
    }

    public var companionBehaviorText: String {
        statusLabel.stringValue
    }

    /// True when the input field's action target is wired back to this view,
    /// so pressing Return / Enter fires the send action. Exposed for tests.
    internal var inputFieldTargetIsSelf: Bool {
        (inputField.target as AnyObject?) === self
    }

    /// The selector wired to the input field's Return-key action, or nil
    /// when none is set. Exposed for tests.
    internal var inputFieldAction: Selector? {
        inputField.action
    }

    /// When true, the input field commits its action on focus loss as well
    /// as on Return. We want this to be **false** — only Return should send,
    /// otherwise tabbing/clicking away would send a half-typed message.
    internal var inputFieldSendsActionOnEndEditing: Bool {
        (inputField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing ?? false
    }

    /// True when the transcript view is hosted inside an NSScrollView with
    /// vertical scrolling enabled. Exposed for tests that verify long
    /// replies don't get clipped off the bottom of the chat window.
    internal var transcriptIsScrollable: Bool {
        transcriptScrollView.documentView === transcriptTextView
            && transcriptScrollView.hasVerticalScroller
    }

    public func updateCompanionBehavior(_ behavior: CompanionBehavior) {
        statusLabel.stringValue = "状态：" + Self.label(for: behavior)
    }

    private static func label(for behavior: CompanionBehavior) -> String {
        switch behavior {
        case .idle: "闲庭信步"
        case .tracking: "追踪光标"
        case .snowing: "下雪中"
        }
    }

    /// A.1.3: Streaming reply handler. When set, `sendCurrentMessage` takes
    /// the streaming path instead of the atomic `replyHandler` path.
    ///
    /// Returns an `AsyncThrowingStream<String, Error>` where each yielded value is
    /// an **incremental delta** (new token text). The view accumulates deltas and
    /// updates the transcript after each chunk.
    public typealias StreamingReplyHandler = @MainActor (String) -> AsyncThrowingStream<String, Error>

    /// When non-nil, `sendCurrentMessage` routes through the streaming path.
    /// Set by `MinimalAppDelegate` after launch to wire streaming from the orchestrator.
    /// Matches the `onSendBegan` mutable-property pattern for consistency.
    public var streamingReplyHandler: StreamingReplyHandler?

    /// Called synchronously before the reply handler is awaited.
    /// Used by A.3.2 wiring to fire `.chatSendBegan` into the state machine
    /// the moment the user commits a message.
    public var onSendBegan: @MainActor () -> Void = {}

    private let replyHandler: ReplyHandler
    private var latestSendIdentifier = 0
    private let bubbleMaskLayer = CAShapeLayer()
    private let transcriptTextView = NSTextView()
    private let transcriptScrollView = NSScrollView()

    /// Tail edge for the speech bubble. Bottom-left by default — the
    /// chat panel sits to the right of the pet (default layout: chat origin
    /// = pet.maxX + 40), so a tail anchored on the lower-left edge of the
    /// bubble visually points back at the pet, not at empty space.
    /// `tailPercent = 0.20` matches the visual centre-of-mass on the
    /// pet-side of the panel; 0.80 is the mirror case (pet on the right).
    /// Future phase 2 will flip side dynamically.
    private let bubbleTailSide: SpeechBubbleTailSide = .bottom
    private let bubbleTailPercent: CGFloat = 0.20
    private let bubbleTailHeight: CGFloat = ChatBubbleTheme.tailHeight

    /// Test-only accessor confirming the bubble mask is wired.
    internal var bubbleMaskPathIsSet: Bool {
        bubbleMaskLayer.path != nil
    }
    private let statusLabel = NSTextField(labelWithString: "状态：闲庭信步")
    private let inputBackgroundView = NSView()
    private let inputField = NSTextField(string: "")
    private lazy var sendButton = NSButton(
        title: "发送",
        target: self,
        action: #selector(sendButtonClicked)
    )

    public init(
        frame frameRect: NSRect = .zero,
        replyHandler: @escaping ReplyHandler = { message in
            "我听到“\(message)”了。"
        }
    ) {
        self.replyHandler = replyHandler
        super.init(frame: frameRect)
        configureView()
    }

    public required init?(coder: NSCoder) {
        self.replyHandler = { message in
            "我听到“\(message)”了。"
        }
        super.init(coder: coder)
        configureView()
    }

    public func sendCurrentMessage() async {
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false else {
            return
        }

        inputText = ""
        latestSendIdentifier += 1
        let sendIdentifier = latestSendIdentifier
        onSendBegan()

        if let streamHandler = streamingReplyHandler {
            // A.1.3: Streaming path — transcript updates incrementally.
            // Mark the in-progress turn so refreshTranscript can render
            // history + this turn while deltas accumulate.
            streamingTurn = (user: message, assistant: "")
            refreshTranscript()
            var accumulated = ""
            do {
                for try await delta in streamHandler(message) {
                    guard !delta.isEmpty else { continue }
                    accumulated += delta
                    guard sendIdentifier == latestSendIdentifier else {
                        streamingTurn = nil
                        refreshTranscript()
                        return
                    }
                    streamingTurn = (user: message, assistant: accumulated)
                    refreshTranscript()
                }
            } catch {
                // Stream error: retain whatever partial text was accumulated
                // by committing it as the final turn. User can re-send to retry.
            }
            guard sendIdentifier == latestSendIdentifier else {
                streamingTurn = nil
                refreshTranscript()
                return
            }
            streamingTurn = nil
            if !accumulated.isEmpty {
                historyTurns.append((user: message, assistant: accumulated))
            }
            refreshTranscript()
        } else {
            // Atomic path — reply arrives in one chunk.
            let reply = await replyHandler(message)
            guard sendIdentifier == latestSendIdentifier else { return }
            historyTurns.append((user: message, assistant: reply))
            refreshTranscript()
        }
    }

    /// Clears the in-view transcript back to the initial greeting.
    /// Does not touch the backing `ConversationStore` — that's a separate
    /// concern handled by `CompanionOrchestrator`.
    public func clearTranscript() {
        historyTurns.removeAll()
        streamingTurn = nil
        refreshTranscript()
    }

    @objc private func sendButtonClicked() {
        Task { @MainActor in
            await sendCurrentMessage()
        }
    }

    // MARK: - Key equivalents (Cmd+V / C / X / A / Z)

    /// Accessory apps (LSUIElement / setActivationPolicy(.accessory)) ship
    /// without a standard main menu, so the default Edit-menu key equivalents
    /// for paste/copy/cut/select-all/undo never reach the focused field's
    /// editor. Mirror the SettingsContentView fix: route Cmd-shortcuts via
    /// NSApp.sendAction so AppKit walks the responder chain and lands on
    /// the field editor (NSText implements all four selectors).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ESC and ⌘W dismiss the bubble. Raycast / Spotlight muscle memory:
        // hit ESC to drop the overlay without alt-tabbing. ⌘W mirrors the
        // standard Close-Window shortcut even though we never wire one in
        // the menu (accessory app has no menu).
        if Self.isDismissKey(event) {
            window?.orderOut(nil)
            return true
        }
        if let selector = Self.editingSelector(for: event),
           NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// True if `event` is ESC or ⌘W. Extracted so tests can verify the
    /// key map without a running `NSApplication`.
    internal static func isDismissKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // `kVK_Escape` = 53. ⌘W: chars == "w" with .command flag set.
        if event.keyCode == 53 { return true }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            return true
        }
        return false
    }

    /// Map a Cmd-key event to the standard editing selector
    /// (paste:/copy:/cut:/selectAll:/undo:/redo:) or nil. Extracted so tests
    /// don't need a running NSApplication to verify the mapping.
    internal static func editingSelector(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers?.lowercased()
        else { return nil }

        let shift = event.modifierFlags.contains(.shift)
        switch chars {
        case "v": return #selector(NSText.paste(_:))
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        default:  return nil
        }
    }

    public override var wantsUpdateLayer: Bool { true }

    /// Flip the view's coordinate system so y=0 is the visual top edge,
    /// matching `SpeechBubbleShape`'s CoreGraphics-style path math
    /// (tail-bottom path puts the tip at `y = rect.height`). Without
    /// this flip, the default NSView bottom-origin geometry renders the
    /// "bottom" tail at the visual top — the bug user reported as
    /// "气泡是反的". Autolayout anchors (`topAnchor` / `bottomAnchor`)
    /// continue to refer to visual top/bottom regardless.
    public override var isFlipped: Bool { true }

    public override func updateLayer() {
        super.updateLayer()
        // The bubble itself occupies `bounds` minus a shadow margin on each
        // edge so `CALayer.shadowPath` has somewhere to render around the
        // shape. Without this margin the shadow gets clipped at the
        // contentView edge and the bubble reads as a rounded rect with no
        // depth — that was the "looks just like before" problem.
        let inset = ChatBubbleTheme.shadowMargin
        let bubbleRect = bounds.insetBy(dx: inset, dy: inset)
        let localPath = SpeechBubbleShape.path(
            in: CGRect(origin: .zero, size: bubbleRect.size),
            cornerRadius: ChatBubbleTheme.cornerRadius,
            tailSide: bubbleTailSide,
            tailPercent: bubbleTailPercent,
            tailHeight: bubbleTailHeight,
            tailWidth: ChatBubbleTheme.tailWidth
        )
        var xform = CGAffineTransform(translationX: bubbleRect.minX, y: bubbleRect.minY)
        let path = localPath.copy(using: &xform) ?? localPath
        bubbleMaskLayer.path = path
        bubbleMaskLayer.frame = bounds
        // CALayer.shadowPath = same bubble outline. The shadow lives in the
        // 20pt margin between the bubble and the contentView edge. Crisp
        // tight HUD-like style: 3pt radius, y=2, 22% indigo.
        layer?.shadowPath = path
        layer?.shadowColor = ChatBubbleTheme.shadowColor.cgColor
        layer?.shadowOffset = ChatBubbleTheme.shadowOffset
        layer?.shadowRadius = ChatBubbleTheme.shadowRadius
        layer?.shadowOpacity = 1.0
        layer?.masksToBounds = false
    }

    private func configureView() {
        wantsLayer = true
        // White paper-like card. The previous translucent teal made the
        // bubble feel like a system HUD; an off-white card reads as a real
        // speech bubble that lives on the desktop.
        layer?.backgroundColor = ChatBubbleTheme.cardBackground.cgColor
        // Speech-bubble mask: clips the layer (incl. its background) to the
        // rounded-card-with-tail path so the tail visibly extends past the
        // rectangular bounds and points at the pet. The mask is updated
        // alongside the shadow path inside `updateLayer()`.
        layer?.mask = bubbleMaskLayer

        configureTranscriptView()
        configureStatusLabel()
        configureInputField()
        configureSendButton()

        addSubview(transcriptScrollView)
        addSubview(statusLabel)
        addSubview(inputBackgroundView)
        addSubview(inputField)
        addSubview(sendButton)

        let padding = ChatBubbleTheme.cardPadding
        let gap = ChatBubbleTheme.stackGap
        // All subviews live inside the bubble area, which is inset by the
        // shadow margin so the bubble has room around it for the layer
        // shadow to render. Bottom padding additionally reserves the tail
        // strip so the tail extends into dead space below the input row.
        let shadowMargin = ChatBubbleTheme.shadowMargin
        let topPadding = shadowMargin + padding
        let sidePadding = shadowMargin + padding
        let bottomPadding = shadowMargin + padding + bubbleTailHeight

        NSLayoutConstraint.activate([
            transcriptScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sidePadding),
            transcriptScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding),
            transcriptScrollView.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
            transcriptScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -gap),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sidePadding),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding),
            statusLabel.bottomAnchor.constraint(equalTo: inputBackgroundView.topAnchor, constant: -6),

            inputBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sidePadding),
            inputBackgroundView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPadding),
            inputBackgroundView.heightAnchor.constraint(equalToConstant: 30),

            // The visible text field sits inside the pill-shaped background.
            inputField.leadingAnchor.constraint(equalTo: inputBackgroundView.leadingAnchor, constant: 10),
            inputField.trailingAnchor.constraint(equalTo: inputBackgroundView.trailingAnchor, constant: -10),
            inputField.centerYAnchor.constraint(equalTo: inputBackgroundView.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding),
            sendButton.centerYAnchor.constraint(equalTo: inputBackgroundView.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 56),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func configureStatusLabel() {
        statusLabel.font = ChatBubbleTheme.captionFont
        statusLabel.textColor = ChatBubbleTheme.textMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureInputField() {
        // Plain bezel-less field on a custom pill background. Default
        // NSTextField bezels read as system Forms; a soft tinted fill makes
        // the field disappear into the bubble until focused.
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = ChatBubbleTheme.inputFont
        inputField.textColor = ChatBubbleTheme.textPrimary
        inputField.placeholderAttributedString = NSAttributedString(
            string: "给 OpenPetAgent 发消息",
            attributes: [
                .foregroundColor: ChatBubbleTheme.textHint,
                .font: ChatBubbleTheme.inputFont,
            ]
        )
        inputField.translatesAutoresizingMaskIntoConstraints = false
        // Return / Enter commits the message just like clicking 发送.
        // NSTextField fires its action when the user presses Return as long
        // as sendsActionOnEndEditing stays false (the default) — that way
        // tabbing away or clicking elsewhere doesn't accidentally send.
        inputField.target = self
        inputField.action = #selector(sendButtonClicked)
        (inputField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false

        inputBackgroundView.wantsLayer = true
        inputBackgroundView.layer?.backgroundColor = ChatBubbleTheme.inputFill.cgColor
        // Small corner radius (10) — was 8, slightly too tight.
        inputBackgroundView.layer?.cornerRadius = ChatBubbleTheme.cornerRadiusSmall
        inputBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSendButton() {
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = ChatBubbleTheme.accent.cgColor
        // The orange CTA uses the card corner radius (14) so the button reads
        // as part of the bubble's geometry, not a foreign control. Was 8 = too
        // pill-y.
        sendButton.layer?.cornerRadius = ChatBubbleTheme.cornerRadius
        // Signature primary-button trick: a **static** 4pt drop shadow in the
        // darker orange `#C94A01`. Zero blur radius — it's a crisp depth band,
        // not a soft halo. SwiftUI: `.shadow(color: orangeShadow, radius: 0, x: 0, y: 4)`.
        // This is what gives the CTA its tactile "press me" feel.
        // We render via CALayer.shadowPath so the depth band tracks the
        // button's rounded outline rather than its rectangular layer bounds.
        sendButton.layer?.shadowColor = ChatBubbleTheme.accentShadow.cgColor
        sendButton.layer?.shadowOffset = CGSize(width: 0, height: 4)
        sendButton.layer?.shadowRadius = 0
        sendButton.layer?.shadowOpacity = 1.0
        sendButton.layer?.masksToBounds = false
        sendButton.contentTintColor = .white
        sendButton.attributedTitle = NSAttributedString(
            string: "发送",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: ChatBubbleTheme.buttonFont,
            ]
        )
        sendButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTranscriptView() {
        // NSTextView (rather than the old NSTextField label) so long replies
        // (e.g. a 500-character poem) become scrollable instead of clipped.
        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = true   // user can copy AI replies
        transcriptTextView.drawsBackground = false
        transcriptTextView.backgroundColor = .clear
        transcriptTextView.textColor = ChatBubbleTheme.textPrimary
        transcriptTextView.font = ChatBubbleTheme.bodyFont
        transcriptTextView.string = transcript
        transcriptTextView.textContainerInset = NSSize(width: 0, height: 4)
        transcriptTextView.textContainer?.lineFragmentPadding = 0
        transcriptTextView.textContainer?.widthTracksTextView = true

        transcriptScrollView.documentView = transcriptTextView
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.hasHorizontalScroller = false
        transcriptScrollView.autohidesScrollers = true
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.scrollerStyle = .overlay
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
    }
}
