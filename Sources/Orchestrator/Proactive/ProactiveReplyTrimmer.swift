// Sources/Orchestrator/Proactive/ProactiveReplyTrimmer.swift

/// 主动建议生成后的「长度兜底」纯函数（借鉴 HermesPet IntentCopyWriter.truncate，但按句界优雅截断）。
///
/// 三层长度防线的第 3 层（prompt 硬约束 → 生成后截断）：模型偶尔不守 prompt 的字数约束时，
/// 在显示前把回复压到 charLimit 以内——优先在最后一个句末标点处截（读起来是完整一句），
/// 没有就硬截 + 「…」。同时把换行折成单空格（主动气泡是一句话，不分行）。
public enum ProactiveReplyTrimmer {
    /// 句末标点（中英）——截断时优先在这些字符后切，保住「一句话」的完整感。
    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "…", ".", "!", "?", "；", ";"]

    /// 「模型把提示词要求当正文复述」的英文 meta 关键词（小写比较）。
    /// pet 一句话是纯中文口语，正常绝不会出现这些词。
    private static let metaMarkers = [
        "sentence", "character", "chinese", "bullet", "we need", "we should",
        "requirement", "no more than", "single line", "less than", "as an ai", "i should",
    ]

    /// 判定回复是否像「模型复述要求」的废话（英文 meta / 几乎无中文）。命中 → 引擎静默跳过这条
    /// （宁可不出，也不给用户弹一句英文要求复述；见 Image #9 反馈）。这是 prompt 重设计之外的
    /// 第二道兜底——few-shot 已大幅降低概率，此处只兜极端情况。
    public static func isLikelyMetaEcho(_ reply: String) -> Bool {
        let flat = flatten(reply)
        guard !flat.isEmpty else { return true }
        // 1) 零中文却有拉丁字母 → 整句英文（含纯要求复述）。正常 pet 句必含中文。
        let cjkCount = flat.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let latinCount = flat.filter { $0.isLetter && $0.isASCII }.count
        if cjkCount == 0 && latinCount >= 3 { return true }
        // 2) 含明显的英文「要求复述」标志词（兜中英混杂的复述）。
        let lowered = flat.lowercased()
        if metaMarkers.contains(where: { lowered.contains($0) }) { return true }
        return false
    }

    /// 把多行/首尾空白压成一行。
    private static func flatten(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 截断到 `limit` 字以内。`limit <= 0` 视为不限制（原样返回 flatten 结果）。
    public static func trim(_ reply: String, toCharLimit limit: Int) -> String {
        let flat = flatten(reply)
        guard limit > 0, flat.count > limit else { return flat }

        let prefix = Array(flat.prefix(limit))
        // 在 prefix 后半段找最后一个句末标点 → 在它之后切（保留标点，读着是完整句）。
        // 只接受落在 limit 一半之后的标点，避免截得过短（如只剩两三个字）。
        let minKeep = max(1, limit / 2)
        if let lastEnderIdx = prefix.lastIndex(where: { sentenceEnders.contains($0) }), lastEnderIdx + 1 >= minKeep {
            return String(prefix[0...lastEnderIdx])
        }
        // 没有合适句界 → 硬截 + 省略号（省略号本身占位，故截到 limit-1）。
        return String(flat.prefix(max(1, limit - 1))) + "…"
    }
}
