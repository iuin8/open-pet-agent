import Foundation
import os

/// 对**单个 jsonl 文件**做增量 tail:只读自上次以来追加的完整行,半行缓冲到下次拼回,
/// 文件被截断/轮换(size < 已读 offset)则重置从头读。
///
/// 增量 tail 思路(offset + partialLine + 截断检测)用纯 Swift 实现一遍。
/// **纯文件 I/O,不解析 JSON** —— 产出原始行,
/// 交给 `ClaudeTranscriptParser` / `CodexTranscriptParser` 解析。
///
/// 行切分逻辑抽成 `static split` 纯函数,可无头单测;I/O 薄壳套在外面。
public struct FileTailer: Sendable {
    public let url: URL
    private var offset: UInt64
    private var partialLine: String

    private static let log = Logger(subsystem: "io.openpetagent", category: "AgentSensing.tail")

    /// `startAtEnd` = 首次遇到大文件时跳过历史(只感知「此刻起」的新行),感知场景必为 true。
    public init(url: URL, startAtEnd: Bool) {
        self.url = url
        self.partialLine = ""
        self.offset = startAtEnd ? (Self.fileSize(url) ?? 0) : 0
    }

    /// 读取自上次以来新追加的完整行。不完整尾行留缓冲,下次追加时拼回。
    ///
    /// 错误处理纪律(防静默数据丢失 / 重复重放):
    /// - **属性读失败**(`fileSize` nil)→ 不动 offset、不误判截断,下轮重试(否则会把
    ///   暂时的属性失败当成 0 字节 → 误判截断回退 → 整段历史重放)。
    /// - **读失败**(`readToEnd` nil)→ **不推进 offset**,下轮从同一位置重试(否则未读字节永丢)。
    /// - offset 按**实读字节数**推进(非 stat 出的 size)→ 读取期间文件继续增长也不会重复读。
    public mutating func readNewLines() -> [String] {
        guard let size = Self.fileSize(url) else { return [] }   // 属性失败:按兵不动,下轮再来
        if size < offset {           // 文件被截断 / 轮换 → 从头来
            offset = 0
            partialLine = ""
        }
        guard size > offset else { return [] }
        let name = url.lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            Self.log.error("打开会话文件失败: \(name, privacy: .public)")
            return []
        }
        defer { try? handle.close() }
        let seekTo = offset
        do {
            try handle.seek(toOffset: seekTo)
        } catch {
            Self.log.error("seek 失败 @\(seekTo): \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }  // 读失败:不推进 offset
        offset += UInt64(data.count)                            // 实读字节推进,不用 stat size
        // 非失败解码:坏字节(罕见的跨读多字节切断)→ U+FFFD,该行解析自然返回 nil,下次自愈。
        let chunk = String(decoding: data, as: UTF8.self)
        let (lines, remainder) = Self.split(buffer: partialLine, incoming: chunk)
        partialLine = remainder
        return lines
    }

    // MARK: - 纯行切分(无 I/O,好测)

    /// 把「上次半行缓冲 + 本次新数据」切成完整行 + 新的半行余量。
    /// `"a\nb\n"` → (["a","b"], "");`"a\nb"` → (["a"], "b")。空行被丢弃。
    static func split(buffer: String, incoming: String) -> (lines: [String], remainder: String) {
        let combined = buffer + incoming
        guard !combined.isEmpty else { return ([], "") }
        var parts = combined.components(separatedBy: "\n")
        let remainder: String
        if combined.hasSuffix("\n") {
            parts.removeLast()        // 丢掉结尾 "\n" 产生的空串
            remainder = ""
        } else {
            remainder = parts.popLast() ?? ""   // 最后一段没换行 = 半行,留着
        }
        let lines = parts.filter { !$0.isEmpty }
        return (lines, remainder)
    }

    // MARK: - 文件属性

    static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
    }
}
