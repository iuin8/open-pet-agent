import AppKit
import SwiftUI

/// P7.1:mention chip 的 NSTextAttachment —— 文本流内嵌胶囊(logo + 名字),
/// 单字符 U+FFFC 天然原子删除;trigger/pinned 经自定义 attribute 挂在该字符上,
/// 编辑器重建 parts 时按 attribute 识别。
///
/// 色谱与 P6.2 tray 逐项对齐:钉住 = accent 85% 深底白字;一次性 = accent 14% 浅底
/// accent 字(引擎用品牌色 logo,soul 用 pawprint.fill)。

/// chip 字符上的自定义 attribute key(与 `.attachment` 并存;重建 parts 的数据源)。
extension NSAttributedString.Key {
    /// mention trigger(如 "codex");值 String。
    static let composerMentionTrigger = NSAttributedString.Key("composerMentionTrigger")
    /// 钉住态;值 Bool。
    static let composerMentionPinned = NSAttributedString.Key("composerMentionPinned")
}

/// mention chip 附件:自绘胶囊 NSImage + 基线对齐。
@MainActor
final class MentionChipTextAttachment: NSTextAttachment {
    let trigger: String
    let isPinned: Bool

    /// 相对正文字体(13pt)的基线下移:正文 span [-3.27, 12.38] 中点 4.55,chip 高 16 → y ≈ -3.5。
    private static let baselineOffset: CGFloat = -3.5

    init(trigger: String, isPinned: Bool, option: MentionOption?) {
        self.trigger = trigger
        self.isPinned = isPinned
        super.init(data: nil, ofType: nil)
        self.image = MentionChipRenderer.image(trigger: trigger, isPinned: isPinned, option: option)
    }

    required init?(coder: NSCoder) {
        // composer 不做持久化/剪贴板富文本,归档路径不支持(返回占位)。
        self.trigger = ""
        self.isPinned = false
        super.init(coder: coder)
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let size = image?.size ?? NSSize(width: 40, height: MentionChipRenderer.height)
        return CGRect(x: 0, y: Self.baselineOffset, width: size.width, height: size.height)
    }
}

/// chip 胶囊光栅化:圆角底 + 左 logo/symbol + 名字。
@MainActor
enum MentionChipRenderer {
    static let height: CGFloat = 16
    private static let iconSize: CGFloat = 11
    private static let hPadding: CGFloat = 7
    private static let iconGap: CGFloat = 4

    static func image(trigger: String, isPinned: Bool, option: MentionOption?) -> NSImage {
        let label = option?.label ?? trigger
        let fg: NSColor = isPinned ? .white : ChatBubbleTheme.accent
        let bg = ChatBubbleTheme.accent.withAlphaComponent(isPinned ? 0.85 : 0.14)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: ComposerTextStyle.chipLabelFont,
            .foregroundColor: fg,
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        let width = ceil(hPadding + iconSize + iconGap + labelSize.width + hPadding)
        let size = NSSize(width: width, height: height)
        return NSImage(size: size, flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let iconRect = NSRect(
                x: hPadding, y: (rect.height - iconSize) / 2,
                width: iconSize, height: iconSize
            )
            // 图标色与 P6.2 tray 一致:钉住白;一次性引擎用品牌色,soul 用 accent。
            let iconColor: NSColor
            if isPinned {
                iconColor = .white
            } else if let logo = option?.brandLogo {
                iconColor = NSColor(logo.defaultColor)
            } else {
                iconColor = ChatBubbleTheme.accent
            }
            if let logo = option?.brandLogo {
                drawLogo(logo, in: iconRect, color: iconColor)
            } else {
                drawSymbol(option?.systemImage ?? "pawprint.fill", in: iconRect, color: iconColor)
            }
            (label as NSString).draw(
                at: NSPoint(x: hPadding + iconSize + iconGap, y: (rect.height - labelSize.height) / 2),
                withAttributes: labelAttrs
            )
            return true
        }
    }

    /// 品牌 logo:SwiftUI `Path`(y 向下)→ 翻进 y 向上的目标 rect → NSBezierPath 填充。
    /// fill-rule 按 SVG 原样(OpenAI 花朵/opencode 方框镂空必须 evenodd)。
    private static func drawLogo(_ logo: BrandLogo, in rect: NSRect, color: NSColor) {
        let uiPath = BrandLogoShape(logo: logo).path(in: CGRect(origin: .zero, size: rect.size))
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.minY + rect.height)
        let cgPath = uiPath.cgPath.copy(using: &flip) ?? uiPath.cgPath
        let bezier = NSBezierPath(cgPath: cgPath)
        bezier.windingRule = logo.fillRule.isEOFilled ? .evenOdd : .nonZero
        color.setFill()
        bezier.fill()
    }

    /// SF Symbol(soul 爪印):绘出后 `sourceAtop` 染色。
    private static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let configured = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        ) ?? base
        NSGraphicsContext.saveGraphicsState()
        configured.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - parts ↔ NSAttributedString 双向桥(编辑器唯一渲染/解析路径)

@MainActor
extension ComposerParts {
    /// parts → 编辑器富文本:mention → 单字符 U+FFFC + attachment + 自定义 attribute。
    static func attributedString(
        from parts: [ComposerPart],
        options: [MentionOption],
        bodyAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for part in normalized(parts) {
            switch part {
            case .text(let s):
                out.append(NSAttributedString(string: s, attributes: bodyAttributes))
            case .mention(let trigger, let isPinned):
                let option = options.first { $0.trigger == trigger }
                var attrs = bodyAttributes
                attrs[.attachment] = MentionChipTextAttachment(trigger: trigger, isPinned: isPinned, option: option)
                attrs[.composerMentionTrigger] = trigger
                attrs[.composerMentionPinned] = isPinned
                out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            }
        }
        return out
    }

    /// textStorage → parts:walk `composerMentionTrigger` attribute,chip 归 mention,
    /// 间隙拼 text(规范化合并)。
    ///
    /// 防 typing-attributes 泄漏:attribute 落在非 U+FFFC 字符上(贴着 chip 键入继承)时
    /// 按纯文本处理 —— 只有「U+FFFC 单字符 + attribute」才算 chip。
    static func parts(from attributed: NSAttributedString) -> [ComposerPart] {
        let ns = attributed.string as NSString
        var mentions: [(range: NSRange, trigger: String, pinned: Bool)] = []
        attributed.enumerateAttribute(
            .composerMentionTrigger,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let trigger = value as? String, !trigger.isEmpty,
                  range.length == 1, ns.substring(with: range) == "\u{FFFC}" else { return }
            let pinned = (attributed.attribute(.composerMentionPinned, at: range.location, effectiveRange: nil) as? Bool) ?? false
            mentions.append((range, trigger, pinned))
        }
        var out: [ComposerPart] = []
        var cursor = 0
        for m in mentions.sorted(by: { $0.range.location < $1.range.location }) {
            if m.range.location > cursor {
                out.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            out.append(.mention(trigger: m.trigger, isPinned: m.pinned))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(.text(ns.substring(from: cursor)))
        }
        return normalized(out)
    }
}
