import Foundation

/// 清洗 LLM 回复里泄漏的「推理过程」。
///
/// 某些网关 / 思考模型（用户的 Antigravity 网关 → gemini）会把 chain-of-thought 当正文吐出来：
/// `<think>…</think>` 包裹，或裸的英文元叙述（`User asks "…" The assistant should… Provide concise
/// answer.我基于…`）后才接真正答案。参考 HermesPet `ReasoningProxy`（它过滤独立的 `reasoning_content`
/// SSE 字段；这里处理**混进 content** 的情况，因为我们的 provider 只读 `delta.content`）。
public enum ChatReplyCleaner {
    /// 英文「推理 / 元叙述」标志词（小写比较）。pet 的正常中文回答不会出现这些。
    private static let reasoningMarkers = [
        "user asks", "the assistant", "we can mention", "we should", "we need to",
        "provide concise", "according to system", "respond in chinese", "the user wants",
        "let me ", "i should ", "i need to ", "final answer", "as an ai",
    ]

    /// 清洗规则：
    /// 1. 剥 `<think>…</think>` / `<thinking>…</thinking>`（含未闭合的尾部，供流式中段用）。
    /// 2. 不含推理标志词 → 原样（仅 trim）。
    /// 3. 含推理标志词且后面已出现真正中文 → 去掉英文前言，从第一个 CJK 字符起返回
    ///    （注意推理里的 `\uXXXX` 是 ASCII 转义，不是 CJK，不会误判）。
    /// 4. 含推理标志词但还没出现中文（纯推理阶段）→ 返回 ""，让 UI 先显示「思考中」打点，
    ///    不把英文推理流式出来。
    public static func clean(_ reply: String) -> String {
        let stripped = stripThinkBlocks(reply)
        let lowered = stripped.lowercased()
        guard reasoningMarkers.contains(where: { lowered.contains($0) }) else {
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let cjk = stripped.firstIndex(where: Self.isCJK) {
            return String(stripped[cjk...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 剥 `<think>` / `<thinking>` 块：闭合的整删；未闭合的开标签从它删到末尾（流式中段）。
    private static func stripThinkBlocks(_ text: String) -> String {
        var s = text
        for tag in ["think", "thinking"] {
            while let open = s.range(of: "<\(tag)>", options: .caseInsensitive),
                  let close = s.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            }
            if let open = s.range(of: "<\(tag)>", options: .caseInsensitive) {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        return s
    }

    /// 是否为基本汉字（CJK Unified Ideographs）。
    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
