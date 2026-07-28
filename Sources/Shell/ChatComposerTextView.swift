import AppKit
import Orchestrator

/// composer 文本样式(AppKit 侧,与 `ChatCardTheme` 的 SwiftUI token 对齐)。
@MainActor
enum ComposerTextStyle {
    /// 正文 13pt rounded(= `ChatCardTheme.body`)。
    static let bodyFont = rounded(size: 13, weight: .regular)
    /// chip 名字 10pt semibold rounded(= P6.2 tray 标签字号)。
    static let chipLabelFont = rounded(size: 10, weight: .semibold)

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: ChatBubbleTheme.textPrimary]
    }
    static var placeholderAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: ChatBubbleTheme.textPrimary.withAlphaComponent(0.4)]
    }

    static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// chip 点击命中信息(菜单构建 + 删除定位用)。
struct MentionChipHit {
    let trigger: String
    let isPinned: Bool
    /// 是否行首 chip(= 文本位置 0;对应 `ComposerParts.leadingMention` 的路由目标)。
    let isLeading: Bool
    /// chip 字符在 textStorage 中的位置(U+FFFC 单字符)。
    let characterIndex: Int
}

/// P7.1:composer 编辑器 —— `NSTextView` 富文本(mention chip 经 attachment 内嵌文本流)。
///
/// - **IME 专项**:`hasMarkedText()` 为 true 时所有按键直接 super(Enter 绝不发送,
///   中文拼音组字确认不被劫持);marked 期间 coordinator 也不重建 parts / 不判定 @。
/// - Enter = 提交(`onSubmit`,picker 可见时 composer 转成接受候选);Shift+Enter = 换行;
///   Esc / 上下箭头先问回调(picker 导航),未处理才 super。
/// - `paste:` 一律转 `pasteAsPlainText:`(防富文本 / chip attribute 粘进来);拖拽注册类型
///   同样收窄到纯文本。
/// - 空时自绘 placeholder(与正文同字体,40% 深靛)。
final class ChatComposerTextView: NSTextView {

    var placeholder: String = ""

    /// Enter(无 Shift,非组字)→ 提交。
    var onSubmit: (() -> Void)?
    /// Esc → 返回 true 表示已处理(picker 关闭),false 走默认。
    var onEscape: (() -> Bool)?
    /// 上下箭头(delta -1/+1)→ 返回 true 表示已处理(picker 导航)。
    var onArrow: ((Int) -> Bool)?
    /// chip 点击 → 要弹的菜单(命中信息, 点击点 view 坐标);nil = 不弹。
    var mentionMenuProvider: ((MentionChipHit, NSPoint) -> NSMenu?)?
    /// P7.2:粘贴/拖拽进来一张图(PNG 重编码 + 5MB 过滤已在 `ChatImageIngest` 做过)。
    var onImage: ((ChatImage) -> Void)?

    // MARK: - 按键

    override func keyDown(with event: NSEvent) {
        // IME 组字中:全部按键交系统(Enter 确认拼音,绝不发送)。
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76:  // Return / 小键盘 Enter
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)   // Shift+Enter = 换行
            } else {
                onSubmit?()
            }
        case 53:    // Esc
            if onEscape?() != true { super.keyDown(with: event) }
        case 126:   // ↑
            if onArrow?(-1) != true { super.keyDown(with: event) }
        case 125:   // ↓
            if onArrow?(1) != true { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 粘贴 / 拖拽(图片 → 附件;其余纯文本)

    /// P7.2:pasteboard 有图片(截图/图片文件)→ 转附件,不进文本;无图 → 纯文本粘贴
    /// (防富文本 / chip attribute 粘进来)。大段文本粘贴折叠留后续里程碑,原文原样粘贴。
    override func paste(_ sender: Any?) {
        let images = ChatImageIngest.images(from: .general)
        if !images.isEmpty {
            images.forEach { onImage?($0) }
            return
        }
        pasteAsPlainText(sender)
    }

    /// P7.2:拖拽图片文件/内联图像 → 附件;非图片 → 默认(文本插入)。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ChatImageIngest.canReadImages(from: sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = ChatImageIngest.images(from: sender.draggingPasteboard)
        if !images.isEmpty {
            images.forEach { onImage?($0) }
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - chip 点击 → 菜单

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = mentionHit(at: point),
           let menu = mentionMenuProvider?(hit, point) {
            menu.popUp(positioning: nil, at: point, in: self)
            return
        }
        super.mouseDown(with: event)
    }

    /// 点击点是否命中 chip 字符(探测插入索引及其前一字符,并用 glyph 矩形校验)。
    private func mentionHit(at point: NSPoint) -> MentionChipHit? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let ns = textStorage.string as NSString
        for candidate in [index, index - 1] where candidate >= 0 && candidate < textStorage.length {
            guard let trigger = textStorage.attribute(.composerMentionTrigger, at: candidate, effectiveRange: nil) as? String,
                  ns.substring(with: NSRange(location: candidate, length: 1)) == "\u{FFFC}" else { continue }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: candidate)
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer
            )
            guard glyphRect.insetBy(dx: -2, dy: -4).contains(containerPoint) else { continue }
            let pinned = (textStorage.attribute(.composerMentionPinned, at: candidate, effectiveRange: nil) as? Bool) ?? false
            return MentionChipHit(trigger: trigger, isPinned: pinned, isLeading: candidate == 0, characterIndex: candidate)
        }
        return nil
    }

    // MARK: - placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !placeholder.isEmpty, textStorage?.length == 0 else { return }
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
        (placeholder as NSString).draw(
            at: NSPoint(x: x, y: textContainerOrigin.y),
            withAttributes: ComposerTextStyle.placeholderAttributes
        )
    }
}
