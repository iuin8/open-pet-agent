import SwiftUI

// MARK: - MarkdownTextView (SwiftUI 富文本渲染)
//
// OpenPetAgent 严格以 AppKit 为壳层,**但 chat 气泡内的富文本是 OpenPetAgent 唯一使用
// SwiftUI 的子视图层** —— 通过 `NSHostingView<MarkdownTextView>` 嵌进 `BondedBubble`。
// 决策依据见 docs/companion-features-roadmap.md M3 方案 B(2026-05-21 user pick)。
//
// 参考 HermesPet (https://github.com/basionwang-bot/HermesPet) 的 SwiftUI 视图层
// (parser 已独立到 `MarkdownBlockParser.swift`,这里只接收 Block 数组渲染)。
//
// 简化范围(MVP):
// - 跳过 TaskCard(依赖 HermesPet 业务模型,留 N2 Tool Mode 引入后)
// - 跳过 chatFontScale Environment(固定字号,设置面板字号控制留后续)
// - tint 用调用方注入,默认 .accentColor

/// SwiftUI 富文本渲染器。给定 Markdown 字符串,内部 parse + 渲染成:
/// - 内联 markdown(bold / italic / inline code / links)走 `AttributedString`
/// - 代码块(```fence)→ 等宽字体 + 复制按钮
/// - 编号列表 ≥ 2 项 → 可点击 ChoiceCard,**点击 = 填到输入框不直接发送**
///   (HermesPet 决策 #17:防止 AI 用编号列表纯叙述时被误触发送)
/// - GFM 表格 → SwiftUI Grid,自动按 :--- / ---: / :---: 对齐
/// - Header(# ~ ######)→ 字号递减,加粗
/// - 横线(--- / *** / ___)→ Divider
public struct MarkdownTextView: View {

    /// 原始 Markdown 字符串。每次变化都重新 parse(parse 是纯算法,流式期间安全)。
    public let content: String

    /// 点击 ChoiceCard 时回调,调用方应把内容填到输入框(不直接发送)。
    /// nil 时 ChoiceCard 退化为普通编号列表展示。
    public var onChoiceSelected: ((String) -> Void)?

    /// ChoiceCard / 表格 / 代码块的强调色(跟当前 chat / mode 联动)。
    public var tint: Color

    /// 内容换行宽度上限。**关键**：宿主 `NSHostingView` 配了 `sizingOptions = []`
    /// 解耦了 frame→intrinsic 的回传，导致仅靠 hostingView.frame 约束宽度时 `fittingSize`
    /// 不反映换行后的多行高度（按近单行算 → 气泡截断）。在 SwiftUI 内容层显式
    /// `.frame(maxWidth:)` 让布局引擎知道换行边界，`fittingSize` 才报准多行高度。
    public var maxWidth: CGFloat

    /// 正文基准字体。主动建议气泡传 `ChatBubbleTheme.bodyFont`（SF Rounded 13pt）
    /// 让渲染字体 == boundingRect 测量字体（否则纯文本走 SwiftUI 默认 SF Pro，
    /// 多行累积差行 → 测高与渲染不符 → 截断）。nil 时用 SwiftUI 默认（chat 原行为）。
    public var baseFont: Font?

    public init(
        content: String,
        tint: Color = .accentColor,
        maxWidth: CGFloat = .infinity,
        baseFont: Font? = nil,
        onChoiceSelected: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.tint = tint
        self.maxWidth = maxWidth
        self.baseFont = baseFont
        self.onChoiceSelected = onChoiceSelected
    }

    public var body: some View {
        let blocks = MarkdownBlockParser.parse(content)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .font(baseFont)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlockParser.Block) -> some View {
        switch block {
        case .text(let text):
            InlineMarkdownView(text: text)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .divider:
            Divider().padding(.vertical, 2)

        case .header(let level, let text):
            headerView(level: level, text: text)

        case .choices(let items):
            if let callback = onChoiceSelected {
                ChoiceCardList(items: items, tint: tint, onSelect: callback)
            } else {
                plainListView(items: items)
            }

        case .table(let headers, let alignments, let rows):
            TableBlockView(headers: headers, alignments: alignments, rows: rows)
        }
    }

    @ViewBuilder
    private func headerView(level: Int, text: String) -> some View {
        let size: CGFloat = switch level {
        case 1: 19
        case 2: 17
        case 3: 15
        default: 14
        }
        let topPadding: CGFloat = switch level {
        case 1: 4
        case 2: 3
        default: 2
        }
        InlineMarkdownView(text: text)
            .font(.system(size: size, weight: .bold))
            .padding(.top, topPadding)
    }

    @ViewBuilder
    private func plainListView(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(idx + 1).")
                        .foregroundStyle(.secondary)
                    InlineMarkdownView(text: item)
                }
            }
        }
    }
}

// MARK: - Inline Markdown (bold / italic / inline code / links)

fileprivate struct InlineMarkdownView: View {
    let text: String

    var body: some View {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnly)
        ) {
            Text(attributed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Code Block (语言标签 + 复制按钮 + 等宽)

fileprivate struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Spacer()
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(copied ? "已复制" : "复制")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .background(.primary.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - Choice Card (编号选项,点击=填到输入框不直发)

fileprivate struct ChoiceCardList: View {
    let items: [String]
    let tint: Color
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                ChoiceCard(index: idx + 1, text: item, tint: tint) {
                    onSelect(item)
                }
            }
        }
        .padding(.top, 4)
    }
}

fileprivate struct ChoiceCard: View {
    let index: Int
    let text: String
    let tint: Color
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isHovering ? Color.white : tint)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(isHovering ? tint : tint.opacity(0.15))
                    )

                InlineMarkdownView(text: text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHovering {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 10))
                        .foregroundStyle(tint)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? tint.opacity(0.55) : .primary.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("填入输入框:\(text)")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

// MARK: - GFM Table

fileprivate struct TableBlockView: View {
    let headers: [String]
    let alignments: [MarkdownBlockParser.TableColumnAlignment]
    let rows: [[String]]

    private var columnCount: Int { headers.count }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            // 表头
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    cell(text: h, align: alignmentFor(idx), isHeader: true)
                }
            }
            .background(Color.primary.opacity(0.08))

            // hairline 分隔
            GridRow {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 0.5)
                    .gridCellColumns(max(columnCount, 1))
            }

            // 数据行
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cellText in
                        cell(text: cellText, align: alignmentFor(colIdx), isHeader: false)
                    }
                }
                .background(rowIdx % 2 == 1 ? Color.primary.opacity(0.025) : Color.clear)

                if rowIdx < rows.count - 1 {
                    GridRow {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                            .gridCellColumns(max(columnCount, 1))
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cell(
        text: String,
        align: MarkdownBlockParser.TableColumnAlignment,
        isHeader: Bool
    ) -> some View {
        let frameAlign: Alignment = switch align {
        case .leading:  .leading
        case .center:   .center
        case .trailing: .trailing
        }
        let textAlign: TextAlignment = switch align {
        case .leading:  .leading
        case .center:   .center
        case .trailing: .trailing
        }
        Group {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(" ")
            } else {
                InlineMarkdownView(text: text)
                    .multilineTextAlignment(textAlign)
            }
        }
        .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
        .frame(maxWidth: .infinity, alignment: frameAlign)
        .padding(.horizontal, 10)
        .padding(.vertical, isHeader ? 7 : 6)
    }

    private func alignmentFor(_ idx: Int) -> MarkdownBlockParser.TableColumnAlignment {
        idx < alignments.count ? alignments[idx] : .leading
    }
}
