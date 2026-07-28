import AppKit
import Orchestrator
import SwiftUI

/// composer(SwiftUI 层)驱动编辑器的句柄:接受 mention 候选 / 唤起焦点。
/// `@State` 持有,representable 建 coordinator 时填实现。
@MainActor
final class ChatComposerEditorProxy {
    var acceptImpl: ((MentionOption) -> Void)?
    var focusImpl: (() -> Void)?

    func accept(_ option: MentionOption) { acceptImpl?(option) }
    func focus() { focusImpl?() }
}

/// 高度自适应的 scroll 容器:intrinsicContentSize.height = 量出的内容高(1...4 行 clamp,
/// 超出内部滚动)。高度变化才 invalidate(prev 比对在 coordinator),防布局抖动。
final class ChatComposerScrollView: NSScrollView {
    var measuredHeight: CGFloat = 0 {
        didSet {
            if abs(oldValue - measuredHeight) > 0.5 { invalidateIntrinsicContentSize() }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }
}

/// P7.1:composer 编辑器 —— `ChatComposerTextView`(NSTextView)的 SwiftUI 桥。
///
/// **双向投影**(parts 是唯一事实源):
/// - parts → attributedString(mention → U+FFFC chip + 自定义 attribute)渲染;
/// - delegate textDidChange → 从 textStorage 全量重建 parts 回写 model;
/// - 自身编辑已同步进 `lastRenderedParts`,updateNSView 比对跳过 → 不重置光标。
///
/// IME marked text 期间:不重建 parts、不判定 @、按键全交系统(见 `ChatComposerTextView`)。
struct ChatComposerEditor: NSViewRepresentable {
    /// composer 内容(parts ↔ `ChatCardState.composerParts`)。
    @Binding var parts: [ComposerPart]
    /// mention 候选(chip 渲染查 label/logo/isSoul)。
    let mentionOptions: [MentionOption]
    /// 当前钉住的引擎 trigger(接受候选时判定 chip 深浅色)。
    let pinnedMentionTrigger: String?
    let placeholder: String
    /// composer 持有的驱动句柄(accept/focus)。
    let proxy: ChatComposerEditorProxy
    /// Enter(无 Shift)→ composer 决定发送 / 接受候选。
    var onSubmit: () -> Void
    /// Esc → true = 已处理。
    var onEscape: () -> Bool
    /// 上下箭头 → true = 已处理(picker 导航)。
    var onArrow: (Int) -> Bool
    /// 光标前「当前键入段」的 @ query 变化(picker 数据源;nil = 不在 mention 输入中)。
    var onQueryChange: (String?) -> Void
    /// chip 菜单「钉住」回调。
    var onPinMention: (String) -> Void
    /// chip 菜单「取消钉住 / 移除钉住 chip」回调。
    var onUnpinMention: () -> Void
    /// 焦点变化(didBegin/EndEditing;composer 描边高亮用)。
    var onFocusChange: (Bool) -> Void
    /// P7.2:粘贴/拖拽进来一张图(已经 `ChatImageIngest` 重编码 PNG + 5MB 过滤)。
    var onImage: (ChatImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatComposerScrollView {
        let coordinator = context.coordinator
        let scrollView = ChatComposerScrollView()
        let textView = ChatComposerTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 20))

        // 文本系统:纵向可伸缩、横向跟随(1...4 行自适应 + 内部滚动的基础)。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainerInset = NSSize(width: 0, height: 1)

        textView.delegate = coordinator
        textView.drawsBackground = false
        textView.isRichText = true            // attachment 渲染需要;粘贴已强制纯文本
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFindBar = false
        // P7.2:拖拽收窄到 纯文本 + 文件 URL + 图像数据(图片走 `ChatImageIngest` 附件通道)。
        textView.registerForDraggedTypes([.string, .fileURL, .png, .tiff])
        textView.typingAttributes = ComposerTextStyle.bodyAttributes
        textView.insertionPointColor = ChatBubbleTheme.textPrimary
        textView.placeholder = placeholder

        // 键盘/菜单回调全部经 coordinator(拿最新 parent)。
        textView.onSubmit = { [weak coordinator] in coordinator?.parent.onSubmit() }
        textView.onEscape = { [weak coordinator] in coordinator?.parent.onEscape() ?? false }
        textView.onArrow = { [weak coordinator] delta in coordinator?.parent.onArrow(delta) ?? false }
        textView.mentionMenuProvider = { [weak coordinator] hit, _ in
            coordinator?.mentionMenu(for: hit)
        }
        textView.onImage = { [weak coordinator] image in coordinator?.parent.onImage(image) }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        coordinator.textView = textView
        coordinator.scrollView = scrollView
        proxy.acceptImpl = { [weak coordinator] option in coordinator?.acceptMention(option) }
        proxy.focusImpl = { [weak coordinator] in coordinator?.focusWhenReady() }

        coordinator.render(parts)
        coordinator.focusWhenReady()
        return scrollView
    }

    func updateNSView(_ scrollView: ChatComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let normalized = ComposerParts.normalized(parts)
        if coordinator.lastRenderedParts != normalized {
            // 外部写入(prefill/clear/pin 同步)→ 重渲染(光标去末尾)。
            coordinator.render(parts)
        } else if coordinator.lastOptions != mentionOptions, normalized.contains(where: \.isMention) {
            // 候选刷新(可用性/展示名变化)→ chip 换脸,保光标。
            coordinator.render(parts, cursorToEnd: false)
        }
        coordinator.lastOptions = mentionOptions
        if coordinator.textView?.placeholder != placeholder {
            coordinator.textView?.placeholder = placeholder
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerEditor
        weak var textView: ChatComposerTextView?
        weak var scrollView: ChatComposerScrollView?
        /// 最近一次渲染/重建的 parts(双向投影一致性比对)。
        var lastRenderedParts: [ComposerPart] = []
        var lastOptions: [MentionOption] = []
        /// 程序化渲染标记(textDidChange 不重建,防自旋)。
        var isRendering = false
        private var lastQuery: String?

        init(_ parent: ChatComposerEditor) { self.parent = parent }

        // MARK: 渲染 parts → textStorage

        func render(_ parts: [ComposerPart], cursorToEnd: Bool = true) {
            guard let textView, let storage = textView.textStorage else { return }
            isRendering = true
            storage.setAttributedString(ComposerParts.attributedString(
                from: parts, options: parent.mentionOptions, bodyAttributes: ComposerTextStyle.bodyAttributes
            ))
            isRendering = false
            lastRenderedParts = ComposerParts.normalized(parts)
            if cursorToEnd {
                textView.selectedRange = NSRange(location: storage.length, length: 0)
            } else {
                let clamped = min(textView.selectedRange().location, storage.length)
                textView.selectedRange = NSRange(location: clamped, length: 0)
            }
            textView.typingAttributes = ComposerTextStyle.bodyAttributes
            textView.needsDisplay = true
            updateHeight()
            updateQuery()
        }

        // MARK: 焦点(pill 描边高亮)

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        // MARK: textDidChange:textStorage → parts 重建回写

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            textView.needsDisplay = true   // placeholder 显隐
            updateHeight()
            guard !isRendering, !textView.hasMarkedText() else { return }   // IME 组字期间不重建
            let rebuilt = ComposerParts.parts(from: storage)
            if rebuilt != lastRenderedParts {
                lastRenderedParts = rebuilt
                parent.parts = rebuilt
            }
            updateQuery()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !textView.hasMarkedText() else { return }
            updateQuery()
            sanitizeTypingAttributes()
        }

        /// 防 typing-attributes 泄漏:光标贴 chip 时键入会继承 chip attribute → 重置回正文属性。
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            sanitizeTypingAttributes()
            return true
        }

        private func sanitizeTypingAttributes() {
            guard let textView, textView.typingAttributes[.composerMentionTrigger] != nil else { return }
            textView.typingAttributes = ComposerTextStyle.bodyAttributes
        }

        // MARK: @ query 判定(光标前「当前键入段」:到上一个 chip / 换行 / 文首)

        /// 当前是否处于 @ mention 输入中;是 → (已键入前缀, 键入段 range)。
        /// chip 边界后允许前导空格(chip 自带尾随空格,链式输入仍触发 picker);
        /// 换行/文首边界走 `MentionAutocomplete.query` 原始行首语义。
        func currentTypedQuery() -> (query: String, segment: NSRange)? {
            guard let textView, let storage = textView.textStorage,
                  textView.selectedRange().length == 0 else { return nil }
            let cursor = textView.selectedRange().location
            guard cursor <= storage.length else { return nil }
            let ns = storage.string as NSString
            var boundary = -1
            var boundaryIsChip = false
            var i = cursor - 1
            while i >= 0 {
                if ns.character(at: i) == 0x0A { boundary = i; break }
                if storage.attribute(.composerMentionTrigger, at: i, effectiveRange: nil) != nil,
                   ns.substring(with: NSRange(location: i, length: 1)) == "\u{FFFC}" {
                    boundary = i
                    boundaryIsChip = true
                    break
                }
                i -= 1
            }
            let start = boundary + 1
            let segmentRange = NSRange(location: start, length: cursor - start)
            let raw = ns.substring(with: segmentRange)
            let source = boundaryIsChip ? String(raw.drop(while: { $0 == " " || $0 == "\t" })) : raw
            guard let query = MentionAutocomplete.query(in: source) else { return nil }
            return (query, segmentRange)
        }

        private func updateQuery() {
            let query = currentTypedQuery()?.query
            guard query != lastQuery else { return }
            lastQuery = query
            let callback = parent.onQueryChange
            // 异步派发:render/textDidChange 可能发生在 SwiftUI update 周期内,
            // 同步写 composer @State 会触发「modifying state during view update」。
            DispatchQueue.main.async { callback(query) }
        }

        // MARK: picker 接受:chip 替换已键入 @query 段 + 尾随空格

        func acceptMention(_ option: MentionOption) {
            guard let textView, let storage = textView.textStorage,
                  let typed = currentTypedQuery() else { return }
            // 行首 chip 链让位:键入段紧跟行首 chip 链 → 整链移除,新 mention 独占行首
            // (tray「重选/一次性顶掉钉住」语义;与 ComposerParts.insertingMention 同规则)。
            let leadRun = leadingChipRunLength()
            let takesLeadSlot = leadRun > 0 && typed.segment.location == leadRun
            let isPinned = !option.isSoul && option.trigger == parent.pinnedMentionTrigger
            let insertion = NSMutableAttributedString(attributedString: ComposerParts.attributedString(
                from: [.mention(trigger: option.trigger, isPinned: isPinned)],
                options: parent.mentionOptions,
                bodyAttributes: ComposerTextStyle.bodyAttributes
            ))
            insertion.append(NSAttributedString(string: " ", attributes: ComposerTextStyle.bodyAttributes))

            var segment = typed.segment
            storage.beginEditing()
            if takesLeadSlot {
                storage.replaceCharacters(in: NSRange(location: 0, length: leadRun), with: "")
                segment.location -= leadRun
            }
            storage.replaceCharacters(in: segment, with: insertion)
            storage.endEditing()
            // textDidChange 已重建 parts 回写;光标落到 chip + 尾随空格之后。
            textView.selectedRange = NSRange(location: segment.location + insertion.length, length: 0)
            textView.typingAttributes = ComposerTextStyle.bodyAttributes
        }

        /// 文首起连续 chip 字符数(行首 chip 链长度)。
        private func leadingChipRunLength() -> Int {
            guard let storage = textView?.textStorage else { return 0 }
            let ns = storage.string as NSString
            var count = 0
            while count < storage.length,
                  storage.attribute(.composerMentionTrigger, at: count, effectiveRange: nil) != nil,
                  ns.substring(with: NSRange(location: count, length: 1)) == "\u{FFFC}" {
                count += 1
            }
            return count
        }

        // MARK: chip 点击菜单

        func mentionMenu(for hit: MentionChipHit) -> NSMenu? {
            let option = parent.mentionOptions.first { $0.trigger == hit.trigger }
            let isSoul = option?.isSoul ?? false
            let actions = ComposerParts.chipMenuActions(
                isLeading: hit.isLeading, isPinned: hit.isPinned, isSoul: isSoul
            )
            let menu = NSMenu()
            for action in actions {
                switch action {
                case .togglePin:
                    let item = NSMenuItem(
                        title: hit.isPinned ? "取消钉住" : "钉住 @\(hit.trigger)",
                        action: #selector(chipMenuTogglePin(_:)), keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = hit
                    menu.addItem(item)
                case .remove:
                    let item = NSMenuItem(
                        title: "移除",
                        action: #selector(chipMenuRemove(_:)), keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = hit
                    menu.addItem(item)
                }
            }
            return menu.items.isEmpty ? nil : menu
        }

        /// 钉/取消钉:都走 App 回环(pin → UD + engine 装配 → pinnedTrigger 刷新 →
        /// syncPinnedChip 把行首 chip 转深色;unpin → chip 移除)。
        @objc private func chipMenuTogglePin(_ item: NSMenuItem) {
            guard let hit = item.representedObject as? MentionChipHit else { return }
            if hit.isPinned {
                parent.onUnpinMention()
            } else {
                parent.onPinMention(hit.trigger)
            }
        }

        /// 移除:行首钉住 chip = 取消钉住(与 P6.2 tray × 语义一致,走 App 回环);
        /// 一次性 chip = 本地删字符(textDidChange 重建 parts)。
        @objc private func chipMenuRemove(_ item: NSMenuItem) {
            guard let hit = item.representedObject as? MentionChipHit else { return }
            if hit.isPinned, hit.isLeading {
                parent.onUnpinMention()
                return
            }
            guard let storage = textView?.textStorage, hit.characterIndex < storage.length else { return }
            storage.deleteCharacters(in: NSRange(location: hit.characterIndex, length: 1))
        }

        // MARK: 高度自适应(1...4 行,超出内部滚动;变化才 invalidate)

        func updateHeight() {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let inset = textView.textContainerInset.height * 2
            let lineHeight = layoutManager.defaultLineHeight(for: ComposerTextStyle.bodyFont)
            let content = layoutManager.usedRect(for: container).height + inset
            let clamped = min(max(content, lineHeight + inset), lineHeight * 4 + inset)
            scrollView.measuredHeight = clamped   // 0.5pt 比对在 didSet
        }

        // MARK: 焦点(窗口未挂载时有限重试)

        func focusWhenReady(attempts: Int = 8) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let textView = self.textView else { return }
                if let window = textView.window {
                    if window.firstResponder !== textView {
                        window.makeFirstResponder(textView)
                    }
                } else if attempts > 0 {
                    self.focusWhenReady(attempts: attempts - 1)
                }
            }
        }
    }
}
