import AppKit
import Testing
@testable import Shell

/// 主动建议气泡「按文字自适应高度」的无头回归测试。
///
/// 背景：截断 bug 反复出现（`fittingSize` 对 `NSHostingView<MarkdownTextView>` +
/// `sizingOptions=[]` 测不出多行高 → panel 过矮 → 文字截断）。这个测试直接断言
/// 「长文本气泡的 panel 高度 ≥ 能容纳多行的下限」，把视觉验收变成确定性单测，
/// 不再依赖人工截图。
@MainActor
@Suite("BondedMarkdownBubble 自适应高度")
struct BondedMarkdownBubbleSizingTests {
    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    /// 一行内容区高度的保守估计（13pt 正文 CJK 行高 ~20pt）。
    private let oneLineApprox: CGFloat = 18

    @Test("长文本(~90 字必换 4+ 行)→ panel 高度容得下多行，不退化到单行/minHeight")
    func multiLineTextGrowsPanel() {
        let win = makeWindow()
        // ~90 字中文，在 304pt 渲染宽度（~23 字/行）下至少换 4 行。
        let long = "下午好呀，看你在写代码摸鱼也挺久了吧，有什么想查的文档或者卡住的地方都可以随时叫我一声，我帮你查查最新的用法和踩坑点，省得你自己一个个翻文档浪费时间啦"
        let bubble = BondedMarkdownBubble(text: long, attachedTo: win, isProactive: true)
        let h = bubble.panel.frame.height
        // 4 行内容（~72pt）+ shadow margin 40 + tail 8 + padding → 至少 ~120pt。
        // 若退化到 minHeight(约 80)，这条必失败 —— 正是截断 bug 特征。
        #expect(h >= 120, "长文本 panel 高度 \(h) 偏小，疑似未按多行测高 → 截断")
    }

    @Test("短文本(单行)→ panel 不会被撑得过高")
    func shortTextStaysCompact() {
        let win = makeWindow()
        let bubble = BondedMarkdownBubble(text: "嗨", attachedTo: win, isProactive: true)
        let h = bubble.panel.frame.height
        // 单字不该超过 ~2 行的高度（防 headroom/估算把短气泡撑过头）。
        #expect(h <= 2 * oneLineApprox + 120, "短文本 panel 高度 \(h) 偏大，留白过多")
    }

    @Test("短文本 → 气泡宽度紧贴内容（不按约束宽度撑满 → 无右侧大片留白）")
    func shortTextWidthIsTight() {
        let win = makeWindow()
        let bubble = BondedMarkdownBubble(text: "你好呀", attachedTo: win, isProactive: true)
        // panel width = contentWidth + 2*margin(40)。短文本 contentWidth ≈ minContentWidth(96)
        // → panel ~136。若按约束宽度算会接近 maxContentWidth(320)+40=360 → 右侧大片留白。
        #expect(bubble.panel.frame.width < 200,
                "短文本气泡宽度 \(bubble.panel.frame.width) 偏大，疑似按约束宽度而非实际行宽 → 右侧留白")
    }

    @Test("pet 居中 → tail 指向中间（≈0.5，戳中 pet）")
    func tailPointsAtCenteredPet() throws {
        let screen = try #require(NSScreen.main)
        let vis = screen.visibleFrame
        let petW: CGFloat = 72
        let win = NSWindow(contentRect: NSRect(x: vis.midX - petW / 2, y: vis.midY, width: petW, height: petW),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        let bubble = BondedMarkdownBubble(text: "测试一下主动建议气泡的尾巴指向", attachedTo: win, isProactive: true)
        #expect(abs(bubble.tailPercent - 0.5) < 0.12, "居中 pet tail=\(bubble.tailPercent) 应≈0.5")
    }

    @Test("pet 贴左边缘 → 气泡不出屏 + tail 左移继续指向 pet")
    func clampLeftEdgeAndTailFollows() throws {
        let screen = try #require(NSScreen.main)
        let vis = screen.visibleFrame
        let petW: CGFloat = 72
        let win = NSWindow(contentRect: NSRect(x: vis.minX, y: vis.midY, width: petW, height: petW),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        let bubble = BondedMarkdownBubble(text: "测试主动建议气泡贴左边缘时的 clamp 与尾巴朝向", attachedTo: win, isProactive: true)
        #expect(bubble.panel.frame.minX >= vis.minX - 1, "气泡 minX=\(bubble.panel.frame.minX) 出屏(screen minX=\(vis.minX))")
        #expect(bubble.tailPercent < 0.45, "贴左缘 tail=\(bubble.tailPercent) 应明显 <0.5 指向左侧 pet")
    }

    @Test("pet 贴屏幕顶 → 气泡翻到 pet 下方（tailSide .top）+ 不出屏顶")
    func flipsBelowWhenPetNearTop() throws {
        let screen = try #require(NSScreen.main)
        let vis = screen.visibleFrame
        let petW: CGFloat = 72
        // pet 紧贴屏幕顶缘（pet 顶 = 屏幕顶）。
        let win = NSWindow(contentRect: NSRect(x: vis.midX - petW / 2, y: vis.maxY - petW, width: petW, height: petW),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        let bubble = BondedMarkdownBubble(text: "测试 pet 贴屏幕顶部时气泡翻转到下方且尾巴朝上戳中 pet 的情况要够长换行", attachedTo: win, isProactive: true)
        #expect(bubble.tailSide == .top, "贴顶应翻转 tailSide=.top，实际 \(bubble.tailSide)")
        #expect(bubble.panel.frame.maxY <= vis.maxY + 1, "气泡顶 maxY=\(bubble.panel.frame.maxY) 出屏顶(\(vis.maxY))")
    }

    @Test("pet 在屏幕中部 → 气泡仍在上方（tailSide .bottom，不乱翻转）")
    func staysAboveWhenPetCentered() throws {
        let screen = try #require(NSScreen.main)
        let vis = screen.visibleFrame
        let petW: CGFloat = 72
        let win = NSWindow(contentRect: NSRect(x: vis.midX - petW / 2, y: vis.midY, width: petW, height: petW),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        let bubble = BondedMarkdownBubble(text: "中部 pet 气泡应在上方", attachedTo: win, isProactive: true)
        #expect(bubble.tailSide == .bottom, "中部 pet 不该翻转，tailSide 应 .bottom 实际 \(bubble.tailSide)")
    }

    @Test("更长文本比更短文本 panel 更高（高度真随内容单调增长）")
    func longerTextIsTaller() {
        let win = makeWindow()
        let shortB = BondedMarkdownBubble(text: "你好", attachedTo: win, isProactive: true)
        let longB = BondedMarkdownBubble(
            text: "你好你好你好你好你好你好你好你好你好你好你好你好你好你好你好你好你好你好你好你好",
            attachedTo: win, isProactive: true
        )
        #expect(longB.panel.frame.height > shortB.panel.frame.height,
                "长文本(\(longB.panel.frame.height)) 未比短文本(\(shortB.panel.frame.height)) 更高 → 高度没随内容增长")
    }
}
