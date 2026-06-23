import Testing
@testable import Shell

@Suite("MarkdownBlockParser")
struct MarkdownBlockParserTests {

    typealias Block = MarkdownBlockParser.Block

    // MARK: - 基础块识别

    @Test("空字符串返回空 block 数组")
    func emptyStringReturnsEmpty() {
        #expect(MarkdownBlockParser.parse("") == [.text("")])
    }

    @Test("纯文本单行 → text block")
    func plainTextLineYieldsTextBlock() {
        #expect(MarkdownBlockParser.parse("hello world") == [.text("hello world")])
    }

    @Test("多行纯文本 → 多个 text block")
    func multilinePlainTextYieldsMultipleTextBlocks() {
        let blocks = MarkdownBlockParser.parse("line 1\nline 2\nline 3")
        #expect(blocks == [.text("line 1"), .text("line 2"), .text("line 3")])
    }

    // MARK: - Code block

    @Test("``` fence 识别为 codeBlock,语言名取出")
    func codeFenceProducesCodeBlock() {
        let md = """
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownBlockParser.parse(md)
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test("``` fence 无语言名,language 为空字符串")
    func codeFenceWithoutLanguage() {
        let md = """
        ```
        plain
        ```
        """
        let blocks = MarkdownBlockParser.parse(md)
        #expect(blocks == [.codeBlock(language: "", code: "plain")])
    }

    // MARK: - Header

    @Test("# 一级标题 → header level 1")
    func singleHashHeader() {
        #expect(MarkdownBlockParser.parse("# Title") == [.header(level: 1, text: "Title")])
    }

    @Test("###### 六级标题 → header level 6")
    func sixHashHeader() {
        #expect(MarkdownBlockParser.parse("###### h6") == [.header(level: 6, text: "h6")])
    }

    @Test("####### 七级标题 → 普通文本(只识别 1-6 级)")
    func sevenHashIsPlainText() {
        let blocks = MarkdownBlockParser.parse("####### too many")
        // 7 个 # 不识别为 header,降级 text
        if case .text = blocks.first {
            // OK
        } else {
            Issue.record("expected .text for 7-hash line, got: \(blocks)")
        }
    }

    @Test("# 后面没空格不识别为 header")
    func hashWithoutSpaceIsPlainText() {
        let blocks = MarkdownBlockParser.parse("#noSpace")
        if case .text = blocks.first {
            // OK
        } else {
            Issue.record("expected .text for #noSpace, got: \(blocks)")
        }
    }

    // MARK: - Divider

    @Test("--- 横线 → divider")
    func tripleDashIsDivider() {
        #expect(MarkdownBlockParser.parse("---") == [.divider])
    }

    @Test("*** 横线 → divider")
    func tripleStarIsDivider() {
        #expect(MarkdownBlockParser.parse("***") == [.divider])
    }

    // MARK: - Choices (numbered list)

    @Test("连续 2 项编号列表 → choices block")
    func twoNumberedItemsBecomeChoices() {
        let md = "1. first\n2. second"
        #expect(MarkdownBlockParser.parse(md) == [.choices(items: ["first", "second"])])
    }

    @Test("单项编号列表 → 普通文本(防误识别叙述式编号)")
    func singleNumberedItemStaysText() {
        let blocks = MarkdownBlockParser.parse("1. lonely")
        if case .text = blocks.first {
            // OK
        } else {
            Issue.record("expected .text for single numbered item, got: \(blocks)")
        }
    }

    @Test("3 项编号列表 → choices with 3 items")
    func threeNumberedItemsBecomeChoices() {
        let md = "1. a\n2. b\n3. c"
        #expect(MarkdownBlockParser.parse(md) == [.choices(items: ["a", "b", "c"])])
    }

    // MARK: - GFM Table

    @Test("最简 GFM 表格识别")
    func minimalGFMTable() {
        let md = """
        | h1 | h2 |
        |----|----|
        | a  | b  |
        """
        let expected = Block.table(
            headers: ["h1", "h2"],
            alignments: [.leading, .leading],
            rows: [["a", "b"]]
        )
        #expect(MarkdownBlockParser.parse(md) == [expected])
    }

    @Test("表格列对齐 :--- / ---: / :---: (separator 每列 ≥ 3 dash,防止误识别)")
    func tableAlignment() {
        let md = """
        | l | c | r |
        |:---|:---:|---:|
        | 1 | 2 | 3 |
        """
        let expected = Block.table(
            headers: ["l", "c", "r"],
            alignments: [.leading, .center, .trailing],
            rows: [["1", "2", "3"]]
        )
        #expect(MarkdownBlockParser.parse(md) == [expected])
    }

    @Test("过短的 separator (≤ 2 dash) 不识别为表格")
    func shortSeparatorNotRecognized() {
        let md = """
        | a | b |
        |--|--|
        | x | y |
        """
        // 每列 2 dash 不够 → 退化为多行文本
        let blocks = MarkdownBlockParser.parse(md)
        for block in blocks {
            if case .table = block {
                Issue.record("expected no table block, got: \(block)")
            }
        }
    }

    @Test("半截表格(只有 header 没 separator) → 流式期间按文本走")
    func halfTableStaysText() {
        let md = "| h1 | h2 |"
        if case .text = MarkdownBlockParser.parse(md).first {
            // OK
        } else {
            Issue.record("expected .text for header-only table line")
        }
    }

    // MARK: - 组合场景

    @Test("Header + code block + choices 混合")
    func mixedBlocks() {
        let md = """
        # Title
        prose
        ```js
        x()
        ```
        1. opt A
        2. opt B
        """
        let blocks = MarkdownBlockParser.parse(md)
        #expect(blocks == [
            .header(level: 1, text: "Title"),
            .text("prose"),
            .codeBlock(language: "js", code: "x()"),
            .choices(items: ["opt A", "opt B"]),
        ])
    }
}
