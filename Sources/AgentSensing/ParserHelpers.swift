import Foundation

/// 两个 transcript parser(Claude / Codex)共用的纯文本/时间小工具。无副作用,好测。
enum ParserHelpers {

    /// 截断长文本到一行摘要(去换行,超 limit 加省略号)。
    static func snippet(_ text: String, limit: Int = 80) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= limit { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }

    /// ISO8601 formatter 初始化开销重(CFDateFormatter + ICU)→ 缓存成单例,别每行新建。
    /// `date(from:)` 只读、线程安全;解析也都在 `AgentSensingService` actor 内串行,无竞争。
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 时间串 → Date;缺失/非法 → `Date(timeIntervalSince1970: 0)`(让调用方可判旧)。
    static func parseTimestamp(_ raw: String?) -> Date {
        guard let raw else { return Date(timeIntervalSince1970: 0) }
        return isoWithFraction.date(from: raw)
            ?? isoPlain.date(from: raw)
            ?? Date(timeIntervalSince1970: 0)
    }

    /// 一句话「看起来像在问用户」—— Codex 文本模式判「等用户」:末尾 `?`/`？` 或含 `[question-issued]` 标记。
    /// 现仅 `CodexTranscriptParser` 的 `task_complete` 分支用(末句问号 → 唯一 awaiting 信号);agent_message/
    /// response_item-assistant 的提升已删(同句双发被映射成不同 kind 致重复渲染,见 lessons §7.4)。
    static func looksLikeQuestion(_ text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return false }
        return trimmed.hasSuffix("?") || trimmed.hasSuffix("？") || trimmed.contains("[question-issued]")
    }

    // MARK: - 详情全文(给会话流「展开看详情」P3.7;两个 parser 共用)

    /// 详情全文上限(防超大工具输出吃内存;详情卡内部滚动看)。
    static let detailCap = 16_384

    /// 截断超长详情(超过 `detailCap` 留前缀 + 标记)。空 → nil。
    static func capped(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > detailCap ? String(text.prefix(detailCap)) + "\n…(已截断)" : text
    }

    /// 字典 → 稳定排序的 pretty JSON 文本(详情展开用)。空字典 / 不可序列化 → nil。
    static func prettyJSON(_ obj: [String: Any]) -> String? {
        guard !obj.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - Claude 消息噪音过滤 / 清洗(参考 claude-devtools (https://github.com/matt1398/claude-devtools) 的消息标签 + 内容清洗)
    //
    // Claude Code transcript 的 `type:"user"` 行**双用途**:既有真实用户 prompt,也夹杂大量 harness 注入
    // (中断标记 / 命令输出 / 系统提醒 / 任务通知 / bash io)。旧 parser 无条件把 string 当 userPrompt → 整段
    // XML 噪音冒充用户消息。这里集中判定:整条丢弃的硬噪音 + slash 命令清洗成可读 `/cmd`。

    /// 整条丢弃的硬噪音标签前缀(harness 注入,非对话)。用户手输内容不以这些开头(slash 走 command-name 单独清洗)。
    static let claudeHardNoisePrefixes = [
        "<local-command-caveat>", "<system-reminder>", "<task-notification>",
        "<local-command-stdout>", "<local-command-stderr>",
        "<bash-input>", "<bash-stdout>", "<bash-stderr>",
    ]

    /// 用户打断 agent 的标记 —— **不丢弃**,升 `.interrupted` 标记轮(P1-6,调用方先于 `isClaudeHardNoise` 判定)。
    static func isInterruption(_ text: String) -> Bool {
        text.hasPrefix("[Request interrupted by user")
    }

    /// 该字符串是否「整条丢弃」的 harness 噪音(硬噪音标签开头)。**不含中断标** —— 中断由 `isInterruption`
    /// 单独判定升标记轮,调用方务必先查 `isInterruption` 再查本函数,否则中断会被误丢。
    static func isClaudeHardNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return claudeHardNoisePrefixes.contains { t.hasPrefix($0) }
    }

    // MARK: - Codex 注入噪音过滤(问题1)
    //
    // Codex 把 harness 注入(AGENTS.md 上下文 / `$skill` 展开的 SKILL.md 全文 / 环境上下文 / 沙箱权限 /
    // CLI 启动 banner)也以 **`role:user` 的 `response_item/message`** 喂进对话流 —— 不像 Claude 有
    // `isMeta`/独立类型区分,旧 parser 当真用户消息整段渲染(`# AGENTS.md instructions…`、SKILL.md 全文、
    // `<environment_context>…`、Codex App 广告 + 一屏 TOML 告警 整屏冒充)。
    // 依据:扫 `~/.codex/sessions` **全量**会话(28 文件,跨 2026/04–06),`role:user` 文本里仅以下形态属注入;
    // 真实用户 prompt(你好 / `$cmd` / `--wait …` / `echo hi` / 自然语言)从不以此开头。
    // **`<task>` 不入名单** —— 它是 slash 命令展开,在 `event_msg/user_message` 与 `response_item` 两路径
    // 都出现 = 真实用户轮,过滤会丢掉真 prompt(关键反例)。
    //
    // 取舍(经对抗审查收紧):①`<skill>` 不做裸前缀(会误杀用户粘贴的游戏/通用 skill XML)→ 改结构化谓词,
    // 要求注入固定四要素 `<name>`/`<path>`/`SKILL.md` 共现。②删 `<user_instructions>`(零样本 + 通用脚手架
    // 标签,真有粘贴 prompt 模板的误杀面)。③`<permissions instructions>` 保留 —— 它在语料里 ×19 出现
    // (role=developer,已被非 user 角色分支丢),含空格非 XML 形态没人会手输 → 零误杀,防版本把它 re-channel
    // 成 role=user(双发那次证明 Codex 会跨事件类型搬运同内容,见 lessons §7.2)。

    /// 整条丢弃的 Codex harness 注入前缀(伪装成 `role:user`)。真实 prompt 不以这些开头(零误杀,全量语料验)。
    static let codexInjectionPrefixes = [
        "# AGENTS.md instructions",                  // AGENTS.md 上下文注入(实测最常见 ×17)
        "<environment_context>",                     // 环境上下文(日期/时区/cwd ×27)
        "<permissions instructions>",                // 沙箱/权限说明(×19,多为 role=developer;role=user 变体防御)
        "Tip: New Build faster with the Codex App",  // Codex CLI 启动 banner + 后续 TOML/skill 解析告警(×2)
    ]

    /// 该 `role:user` 文本是否 Codex harness 注入(非真实用户输入)→ 整条丢弃。
    static func isCodexInjectionNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if codexInjectionPrefixes.contains(where: { t.hasPrefix($0) }) { return true }
        // `<skill>` 单列结构化判定:`$skill` 注入恒为 `<skill><name>…</name><path>…SKILL.md</path>…`(实测固定),
        // 裸 `<skill>` 会误杀用户粘贴的游戏/通用 skill XML → 要求 SKILL.md 等专有要素共现才判噪音。
        return t.hasPrefix("<skill>") && t.contains("<name>") && t.contains("<path>") && t.contains("SKILL.md")
    }

    /// slash 命令注入(`<command-name>/effort</command-name>…<command-args>ultracode</command-args>`)
    /// → 清洗成可读 `/effort ultracode`(对照 contentSanitizer extractCommandDisplay)。非命令 → nil。
    static func extractSlashCommand(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<command-name>"),
              let name = innerTagText(t, tag: "command-name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let cmd = name.hasPrefix("/") ? name : "/" + name
        let args = innerTagText(t, tag: "command-args")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let args, !args.isEmpty { return cmd + " " + args }
        return cmd
    }

    /// 抽 `<tag>…</tag>` 内首个匹配的文本。无 → nil。
    private static func innerTagText(_ s: String, tag: String) -> String? {
        guard let open = s.range(of: "<\(tag)>"),
              let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex) else { return nil }
        return String(s[open.upperBound..<close.lowerBound])
    }
}
