import Foundation
import Testing
import AgentMode
@testable import Shell

// P7.1:composer part 模型纯逻辑单测 —— 序列化(wire format)、leadingMention、hasContent、
// insert/remove/togglePin、chip 菜单动作,以及与 `AgentMention.parse` 的 round-trip
// (序列化结果 = P6.2 烘焙产物同格式,行首路由语义不变)。

@Suite("ComposerParts 序列化(wire format)")
struct ComposerPartsSerializationTests {

    @Test("text 原样;空 parts → 空串")
    func textOnly() {
        #expect(ComposerParts.serialized([]) == "")
        #expect(ComposerParts.serialized([.text("你好")]) == "你好")
        #expect(ComposerParts.serialized([.text("a\nb")]) == "a\nb")
    }

    @Test("行首 chip → '@trigger ' 前缀(带一个尾随空格)")
    func leadingChip() {
        #expect(ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: true), .text("看日志"),
        ]) == "@codex 看日志")
        #expect(ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: true),
        ]) == "@codex ")
    }

    @Test("行中 chip → 落在文本流原位(纯文本语义)")
    func midChip() {
        #expect(ComposerParts.serialized([
            .text("找 "), .mention(trigger: "codex", isPinned: false), .text("帮忙"),
        ]) == "找 @codex 帮忙")
    }

    @Test("多 chip 顺序序列化")
    func multiChip() {
        #expect(ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: true),
            .mention(trigger: "pet", isPinned: false),
            .text("聊"),
        ]) == "@codex @pet 聊")
    }

    @Test("chip 拥有空格:mention 后 text 前导空白折叠(防双空格);换行不属于管辖,保留")
    func spaceCollapse() {
        #expect(ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: false), .text("  看日志"),
        ]) == "@codex 看日志")
        #expect(ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: false), .text("\t看日志"),
        ]) == "@codex 看日志")
        #expect(ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: false), .text("\n看日志"),
        ]) == "@codex \n看日志")
    }
}

@Suite("ComposerParts leadingMention / hasContent")
struct ComposerPartsRoutingTests {

    @Test("leadingMention:首个 part 是 mention → 路由目标;否则 nil")
    func leading() {
        let lead = ComposerParts.leadingMention([
            .mention(trigger: "codex", isPinned: true), .text("x"),
        ])
        #expect(lead?.trigger == "codex")
        #expect(lead?.isPinned == true)
        #expect(ComposerParts.leadingMention([.text("@codex x")]) == nil)
        #expect(ComposerParts.leadingMention([]) == nil)
    }

    @Test("hasContent:text 去空白非空才可发送;只有 chip 不算")
    func content() {
        #expect(ComposerParts.hasContent([.text("hi")]))
        #expect(ComposerParts.hasContent([.mention(trigger: "codex", isPinned: true), .text("hi")]))
        #expect(!ComposerParts.hasContent([.mention(trigger: "codex", isPinned: true)]))
        #expect(!ComposerParts.hasContent([.mention(trigger: "codex", isPinned: true), .text("  \n ")]))
        #expect(!ComposerParts.hasContent([]))
    }

    @Test("sendable:有正文或有图即可发送;只有 chip 无图不算")
    func sendable() {
        #expect(ComposerParts.sendable([.text("hi")], imageCount: 0))
        #expect(ComposerParts.sendable([], imageCount: 1))                       // 纯图片消息
        #expect(ComposerParts.sendable([.mention(trigger: "codex", isPinned: true)], imageCount: 2))
        #expect(!ComposerParts.sendable([], imageCount: 0))
        #expect(!ComposerParts.sendable([.mention(trigger: "codex", isPinned: true)], imageCount: 0))
    }

    @Test("pickerLeading:对齐光标,左右越界 clamp 在容器内")
    func pickerLeading() {
        // 正常:跟光标
        #expect(ComposerParts.pickerLeading(caretMinX: 100, containerWidth: 400, pickerWidth: 260) == 100)
        // 左越界 → margin
        #expect(ComposerParts.pickerLeading(caretMinX: 2, containerWidth: 400, pickerWidth: 260) == 8)
        // 右越界 → containerWidth - width - margin(400-260-8=132)
        #expect(ComposerParts.pickerLeading(caretMinX: 300, containerWidth: 400, pickerWidth: 260) == 132)
        // 容器比 picker 还窄 → 兜底 margin(不出负数)
        #expect(ComposerParts.pickerLeading(caretMinX: 50, containerWidth: 200, pickerWidth: 260) == 8)
    }

    @Test("pickerTop:上方放得下弹上方;越顶翻转光标下方")
    func pickerTop() {
        // 上方空间足:caretTop 100 - gap 6 - 高 39 = 55
        #expect(ComposerParts.pickerTop(caretTop: 100, caretBottom: 120, pickerHeight: 39) == 55)
        // 上方空间不足(caretTop 20)→ 翻转到 caretBottom + gap
        #expect(ComposerParts.pickerTop(caretTop: 20, caretBottom: 38, pickerHeight: 39) == 44)
        // 恰好贴 margin(50-6-36=8 ≥ 8)→ 仍弹上方
        #expect(ComposerParts.pickerTop(caretTop: 50, caretBottom: 68, pickerHeight: 36) == 8)
    }
}

@Suite("ComposerParts 纯函数操作")
struct ComposerPartsOpsTests {

    @Test("insertingMention:新鲜输入 '@co' → chip 替换键入段")
    func insertFresh() {
        #expect(ComposerParts.insertingMention(
            [.text("@co")], trigger: "codex", isPinned: false, replacingTypedQuery: "co"
        ) == [.mention(trigger: "codex", isPinned: false)])
    }

    @Test("insertingMention:键入段带正文前缀 → chip 落在键入位置(非行首)")
    func insertAfterText() {
        #expect(ComposerParts.insertingMention(
            [.text("你好\n@co")], trigger: "codex", isPinned: false, replacingTypedQuery: "co"
        ) == [.text("你好\n"), .mention(trigger: "codex", isPinned: false)])
    }

    @Test("insertingMention:紧跟行首钉住 chip 键入 → 行首 chip 让位,独占行首(paw 逃逸/重选)")
    func insertReplacesLeadingChip() {
        #expect(ComposerParts.insertingMention(
            [.mention(trigger: "codex", isPinned: true), .text("@p")],
            trigger: "pet", isPinned: false, replacingTypedQuery: "p"
        ) == [.mention(trigger: "pet", isPinned: false)])
    }

    @Test("insertingMention:行首 chip 链 → 整链让位")
    func insertReplacesLeadingChain() {
        #expect(ComposerParts.insertingMention(
            [
                .mention(trigger: "codex", isPinned: true),
                .mention(trigger: "claude", isPinned: false),
                .text("@o"),
            ],
            trigger: "opencode", isPinned: false, replacingTypedQuery: "o"
        ) == [.mention(trigger: "opencode", isPinned: false)])
    }

    @Test("insertingMention:行首 chip + 已写正文 → 键入段在正文后,行首 chip 不动")
    func insertKeepsLeadingChipWhenTextBetween() {
        #expect(ComposerParts.insertingMention(
            [.mention(trigger: "codex", isPinned: true), .text("看 @c")],
            trigger: "claude", isPinned: false, replacingTypedQuery: "c"
        ) == [
            .mention(trigger: "codex", isPinned: true),
            .text("看 "),
            .mention(trigger: "claude", isPinned: false),
        ])
    }

    @Test("insertingMention:找不到键入段(数据已变)→ 兜底插到末尾")
    func insertFallbackAppends() {
        #expect(ComposerParts.insertingMention(
            [.text("你好")], trigger: "codex", isPinned: true, replacingTypedQuery: "co"
        ) == [.text("你好"), .mention(trigger: "codex", isPinned: true)])
    }

    @Test("removingMention:移除指定 chip;相邻 text 合并;越界/非 mention 原样")
    func remove() {
        #expect(ComposerParts.removingMention(at: 0, in: [
            .mention(trigger: "codex", isPinned: true), .text("x"),
        ]) == [.text("x")])
        #expect(ComposerParts.removingMention(at: 1, in: [
            .text("a"), .mention(trigger: "codex", isPinned: false), .text("b"),
        ]) == [.text("ab")])
        #expect(ComposerParts.removingMention(at: 5, in: [.text("x")]) == [.text("x")])
        #expect(ComposerParts.removingMention(at: 0, in: [.text("x")]) == [.text("x")])
    }

    @Test("togglingPin:钉住态切换;非 mention 原样")
    func toggle() {
        #expect(ComposerParts.togglingPin(at: 0, in: [
            .mention(trigger: "codex", isPinned: false),
        ]) == [.mention(trigger: "codex", isPinned: true)])
        #expect(ComposerParts.togglingPin(at: 0, in: [
            .mention(trigger: "codex", isPinned: true),
        ]) == [.mention(trigger: "codex", isPinned: false)])
        #expect(ComposerParts.togglingPin(at: 0, in: [.text("x")]) == [.text("x")])
    }

    @Test("chipMenuActions:行首引擎 chip [togglePin, remove];soul / 非行首 [remove]")
    func menuActions() {
        #expect(ComposerParts.chipMenuActions(isLeading: true, isPinned: true, isSoul: false) == [.togglePin, .remove])
        #expect(ComposerParts.chipMenuActions(isLeading: true, isPinned: false, isSoul: false) == [.togglePin, .remove])
        #expect(ComposerParts.chipMenuActions(isLeading: true, isPinned: false, isSoul: true) == [.remove])
        #expect(ComposerParts.chipMenuActions(isLeading: false, isPinned: false, isSoul: false) == [.remove])
    }
}

// MARK: - 与 AgentMention.parse 的 round-trip(wire format 契约)

@Suite("ComposerParts ↔ AgentMention.parse round-trip")
struct ComposerPartsParseRoundTripTests {

    @Test("行首引擎 chip → 路由到对应 engine,prompt 为剥离后的正文")
    func engineRoute() {
        let wire = ComposerParts.serialized([
            .mention(trigger: "codex", isPinned: true), .text("看下构建"),
        ])
        let parsed = AgentMention.parse(wire)
        #expect(parsed.target == .engine(.codex))
        #expect(parsed.prompt == "看下构建")
    }

    @Test("行首 soul chip → .soul(钉住时的单条逃逸)")
    func soulRoute() {
        let wire = ComposerParts.serialized([
            .mention(trigger: "pet", isPinned: false), .text("聊聊"),
        ])
        #expect(AgentMention.parse(wire).target == .soul)
    }

    @Test("行中 chip 不触发路由(行中 @ 是纯文本)")
    func midChipNoRoute() {
        let wire = ComposerParts.serialized([
            .text("找 "), .mention(trigger: "codex", isPinned: false), .text("帮忙"),
        ])
        #expect(AgentMention.parse(wire).target == nil)
    }

    @Test("只有 chip 无正文 → 不触发路由(parse 要求 mention 后有正文,与 hasContent 对齐)")
    func chipOnlyNoRoute() {
        let wire = ComposerParts.serialized([.mention(trigger: "codex", isPinned: true)])
        #expect(AgentMention.parse(wire).target == nil)
    }
}

// MARK: - chip attributed 双向桥(AppKit;U+FFFC + 自定义 attribute)

@MainActor
@Suite("MentionChipAttachment 双向桥")
struct MentionChipBridgeTests {

    private let options = [
        MentionOption(trigger: "codex", label: "Codex", systemImage: "x", brandLogo: .codex, available: true),
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
    ]

    @Test("parts → attributed → parts round-trip:trigger/pinned 保真,emoji/换行/引号无损")
    func roundTrip() {
        let parts: [ComposerPart] = [
            .mention(trigger: "codex", isPinned: true),
            .text("看 \"日志\" 🐾\n第二行"),
            .mention(trigger: "pet", isPinned: false),
            .text("尾巴"),
        ]
        let attr = ComposerParts.attributedString(
            from: parts, options: options, bodyAttributes: ComposerTextStyle.bodyAttributes
        )
        #expect(ComposerParts.parts(from: attr) == parts)
    }

    @Test("typing-attributes 泄漏防御:attribute 落在非 U+FFFC 字符上 → 按纯文本处理")
    func leakedAttributeTreatedAsText() {
        let attr = NSAttributedString(string: "codex", attributes: [
            .composerMentionTrigger: "codex",
            .composerMentionPinned: true,
        ])
        #expect(ComposerParts.parts(from: attr) == [.text("codex")])
    }

    @Test("chip 附件自绘图像:高 16,宽随 label 非零")
    func chipImageSize() {
        let attachment = MentionChipTextAttachment(trigger: "codex", isPinned: true, option: options[0])
        #expect(attachment.image != nil)
        #expect(attachment.image?.size.height == 16)
        #expect((attachment.image?.size.width ?? 0) > 20)
    }
}
