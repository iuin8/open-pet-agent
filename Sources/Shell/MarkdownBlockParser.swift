import Foundation

/// Markdown 块级解析器 —— 把一段 Markdown 文本切分成结构化的 `MarkdownBlock` 数组。
///
/// 参考 HermesPet (https://github.com/basionwang-bot/HermesPet) 的 `parseBlocks` 算法,
/// 提炼为纯算法 Swift 实现(无 SwiftUI 依赖,可单测)。简化范围:
/// - 保留:text / codeBlock / header / choices / divider / table
/// - 去掉:taskList(依赖 HermesPet 业务模型,留待 N2 Tool Mode 引入后再实现)
///
/// 关键设计:
/// - **流式友好**:GFM table 要求 header + separator 两行都到位才识别(避免半截表格抖动)
/// - **choices 防误触**:编号列表 ≥ 2 项才识别为 ChoiceCard(单项当普通文本)
/// - **块解析独立于渲染**:同一份 Block 数组可被 SwiftUI / AppKit / 测试 fixture 复用
public enum MarkdownBlockParser {

    // MARK: - Block model

    public enum Block: Equatable, Sendable {
        case text(String)
        case codeBlock(language: String, code: String)
        case divider
        case header(level: Int, text: String)
        /// 连续编号列表(≥ 2 项),由 UI 层决定是否渲染成 ChoiceCard
        case choices(items: [String])
        /// GFM 表格:header 行 + 数据行 + 每列对齐
        case table(headers: [String], alignments: [TableColumnAlignment], rows: [[String]])
    }

    public enum TableColumnAlignment: Equatable, Sendable {
        case leading, center, trailing
    }

    // MARK: - Public API

    /// 把 Markdown 文本切分为块序列。空字符串返回空数组。
    public static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code block fence (```)
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(
                    language: language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Horizontal rule
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            // GFM 表格:header + separator 都到位才识别(流式期间半截表格仍按文本走)
            if i + 1 < lines.count,
               isLikelyTableRow(line),
               let aligns = parseTableSeparator(lines[i + 1]),
               !aligns.isEmpty {
                let headerCells = parseTableRow(line)
                let colCount = min(headerCells.count, aligns.count)
                let headers = Array(headerCells.prefix(colCount))
                let alignments = Array(aligns.prefix(colCount))
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, isLikelyTableRow(lines[j]) {
                    var cells = parseTableRow(lines[j])
                    if cells.count < colCount {
                        cells.append(contentsOf: Array(repeating: "", count: colCount - cells.count))
                    } else if cells.count > colCount {
                        cells = Array(cells.prefix(colCount))
                    }
                    rows.append(cells)
                    j += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                i = j
                continue
            }

            // Header(`# / ## / ### ...`,1-6 级)
            let hashCount = line.prefix(while: { $0 == "#" }).count
            if hashCount > 0, hashCount <= 6,
               line.count > hashCount,
               line[line.index(line.startIndex, offsetBy: hashCount)] == " " {
                let headerText = String(line.dropFirst(hashCount + 1))
                blocks.append(.header(level: hashCount, text: headerText))
                i += 1
                continue
            }

            // 编号列表(≥ 2 项才识别为 choices)
            if numberedItemContent(of: line) != nil {
                var items: [String] = []
                var consumed = 0
                while i + consumed < lines.count,
                      let item = numberedItemContent(of: lines[i + consumed]) {
                    items.append(item)
                    consumed += 1
                }
                if items.count >= 2 {
                    blocks.append(.choices(items: items))
                    i += consumed
                    continue
                }
                // 只有 1 项 → 当普通文本走
            }

            blocks.append(.text(line))
            i += 1
        }

        return blocks
    }

    // MARK: - GFM table helpers

    /// 一行**看起来像**表格数据行 —— 至少 2 个未转义的 `|` 且 trim 后非空。
    public static func isLikelyTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var count = 0
        var prev: Character = " "
        for ch in trimmed {
            if ch == "|", prev != "\\" { count += 1 }
            prev = ch
        }
        return count >= 2
    }

    /// 解析 separator 行(`|---|:---:|---:|`)→ 每列对齐数组;不是合法 separator 返回 nil。
    /// 每个 cell 必须由 `:` 和 `-` 组成,且至少含 3 个 `-`(避免误识别普通行)。
    public static func parseTableSeparator(_ line: String) -> [TableColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [TableColumnAlignment] = []
        for raw in cells {
            let cell = raw.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return nil }
            let dashes = cell.filter { $0 == "-" }.count
            guard dashes >= 3,
                  cell.allSatisfy({ $0 == ":" || $0 == "-" }) else { return nil }
            let startsColon = cell.hasPrefix(":")
            let endsColon = cell.hasSuffix(":")
            switch (startsColon, endsColon) {
            case (true, true):   aligns.append(.center)
            case (false, true):  aligns.append(.trailing)
            default:             aligns.append(.leading)
            }
        }
        return aligns
    }

    /// 切表格一行的单元格 —— 按未转义的 `|` 切,去掉首尾空 cell(GFM `|a|b|` → ["a","b"]);
    /// 转义 `\|` 还原成 `|`;每个 cell trim 首尾空白。
    public static func parseTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var prev: Character = " "
        for ch in line {
            if ch == "|", prev != "\\" {
                cells.append(current)
                current = ""
            } else if ch == "|", prev == "\\" {
                current.removeLast()
                current.append("|")
            } else {
                current.append(ch)
            }
            prev = ch
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Numbered list

    /// 解析编号列表项("1. xxx" / "12. xxx" / "  3. xxx"):去掉前缀后返回内容;
    /// 不是编号项返回 nil。数字最多 3 位。
    public static func numberedItemContent(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let firstChar = trimmed.first, firstChar.isNumber,
              let dotIdx = trimmed.firstIndex(of: ".")
        else { return nil }
        let numPart = trimmed[..<dotIdx]
        guard numPart.allSatisfy({ $0.isNumber }),
              numPart.count <= 3 else { return nil }
        let afterDot = trimmed.index(after: dotIdx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return String(trimmed[trimmed.index(after: afterDot)...])
            .trimmingCharacters(in: .whitespaces)
    }
}
