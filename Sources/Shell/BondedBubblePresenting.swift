import AppKit

/// 统一 `BondedBubble`(单行 NSTextField label,user 输入 / 短消息用)与
/// `BondedMarkdownBubble`(SwiftUI MarkdownTextView,assistant 富文本回复用)的接口。
///
/// `BondedBubbleChain` 内部以 `any BondedBubblePresenting` 存 `currentRound`,
/// 屏蔽具体实现差异;append* 方法按 kind 路由到具体类。
///
/// 设计原则:
/// - protocol 只暴露 chain 真正用到的 API(panel / show / hide / setText /
///   repositionRelativeTo / kind),不暴露视觉细节(tail / mask / sizing)
/// - 现有 `BondedBubble` 已天然满足这个 protocol,只需 extension 声明 conformance
@MainActor
public protocol BondedBubblePresenting: AnyObject {
    /// 气泡角色(用户消息 / 输入 / AI 回复)。chain 用来判断添加 / 排序。
    var kind: BondedBubble.Kind { get }
    /// 底层 NSPanel。chain 用来挂 child window / observe move / remove。
    var panel: ChatBubblePanel { get }
    /// 更新内容文本。BondedBubble 是单行 String;BondedMarkdownBubble 是
    /// Markdown 源文本(内部 parse + re-render)。
    func setText(_ text: String)
    /// 淡入显示。
    func show()
    /// 淡出隐藏。
    func hide()
    /// 重新定位相对 parent 窗口。chain 在 user message 之后 append assistant
    /// 时用 offsetY 把 assistant 叠在 user 上方。
    func repositionRelativeTo(_ parent: NSWindow, offsetY: CGFloat)
    /// 当前显示的文本(BondedBubble 是 NSTextField.stringValue;
    /// BondedMarkdownBubble 是上次 `setText` 传入的 Markdown 源文本)。
    /// 测试用来断言 setText 后的内容。
    var currentText: String { get }
    /// tail 在底边的百分比(user 0.80 偏右 / assistant 0.20 偏左)。
    var tailPercent: CGFloat { get }
}

// MARK: - BondedBubble conformance

extension BondedBubble: BondedBubblePresenting {}
