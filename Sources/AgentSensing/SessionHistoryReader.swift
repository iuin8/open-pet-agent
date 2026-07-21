import Foundation

/// 一个历史窗口的读取结果(P3.8 G4 增量加载)。
public struct SessionFileFingerprint: Sendable, Equatable, Hashable {
    public let mtime: Date
    public let size: UInt64

    public init(mtime: Date, size: UInt64) {
        self.mtime = mtime
        self.size = size
    }
}

public struct HistoryWindow: Sendable, Equatable {
    /// 本窗口解析出的事件(按文件顺序)。
    public let events: [AgentEvent]
    /// 本窗口**首条完整行**的字节偏移 —— 即下次「加载更早」的 `endOffset`(游标往文件头走)。
    public let startOffset: UInt64
    /// 是否已读到文件**开头**(没有更早内容了)→ UI 隐藏「加载更早」。
    public let reachedStart: Bool

    public init(events: [AgentEvent], startOffset: UInt64, reachedStart: Bool) {
        self.events = events
        self.startOffset = startOffset
        self.reachedStart = reachedStart
    }
}

/// 读 transcript 文件**窗口**(进卡片时拉最近历史 + 上滑加载更早)——区别于 `FileTailer`
/// (只 tail「此刻起」的增量)。大文件(可达数百 MB / GB)绝不全读,只 seek 一个窗口。
///
/// 纯文件读 + 复用 parser,`now`/路径可注入 → 无头单测。
public enum SessionHistoryReader {

    /// 读 `url` 尾部 `tailBytes` 字节,逐行解析成 `[AgentEvent]`(按文件顺序)。便捷重载(只要事件)。
    public static func read(url: URL, agent: AgentKind = .claudeCode, tailBytes: Int = 262_144) -> [AgentEvent] {
        readWindow(url: url, agent: agent, endOffset: nil, windowBytes: tailBytes).events
    }

    /// 读一个**以 `endOffset` 结尾**的窗口([max(0, endOffset-windowBytes), endOffset))。
    /// - `endOffset == nil` → 从**文件末尾**起(首次加载尾部历史)。
    /// - `endOffset == 上次的 startOffset` → 往前接一个更早窗口(增量「加载更早」),无缝无重叠。
    ///
    /// seek 切在半行 → 丢弃**首条**残行(`lo > 0` 时),`startOffset` 指向首条完整行的字节(下次游标)。
    /// 文件不存在 / 读失败 → 空窗口(reachedStart=true,停止再读)。
    public static func readWindow(
        url: URL,
        agent: AgentKind = .claudeCode,
        endOffset: UInt64? = nil,
        windowBytes: Int = 262_144
    ) -> HistoryWindow {
        guard let size = fileSize(url), let handle = try? FileHandle(forReadingFrom: url) else {
            return HistoryWindow(events: [], startOffset: 0, reachedStart: true)
        }
        defer { try? handle.close() }

        let hi = min(endOffset ?? size, size)
        let lo = hi > UInt64(windowBytes) ? hi - UInt64(windowBytes) : 0
        guard hi > lo else { return HistoryWindow(events: [], startOffset: lo, reachedStart: true) }

        do { try handle.seek(toOffset: lo) } catch {
            return HistoryWindow(events: [], startOffset: lo, reachedStart: lo == 0)
        }
        guard let data = try? handle.read(upToCount: Int(hi - lo)), !data.isEmpty else {
            return HistoryWindow(events: [], startOffset: lo, reachedStart: lo == 0)
        }

        // lo > 0:首行被 seek 切半 → 丢到第一个换行后;首条完整行的文件字节 = lo + 第一个 '\n' 下标 + 1。
        var firstCompleteByte = lo
        var body = data
        if lo > 0 {
            guard let nl = data.firstIndex(of: 0x0A) else {
                // 整窗无换行(超长单行)→ 无完整行可解,游标停在 lo 防死循环。
                return HistoryWindow(events: [], startOffset: lo, reachedStart: false)
            }
            let afterNL = data.index(after: nl)
            firstCompleteByte = lo + UInt64(data.distance(from: data.startIndex, to: afterNL))
            body = data.subdata(in: afterNL..<data.endIndex)
        }

        let text = String(decoding: body, as: UTF8.self)
        let parser: any TranscriptParser = (agent == .codex) ? CodexTranscriptParser() : ClaudeTranscriptParser()
        let sessionId = url.deletingPathExtension().lastPathComponent
        let events = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { parser.parse(line: String($0), fallbackSessionId: sessionId, fallbackCwd: nil) }   // 一行可能多事件(P0-2)
            .map { stamped($0, sessionId: sessionId) }

        return HistoryWindow(events: events, startOffset: firstCompleteByte, reachedStart: lo == 0)
    }

    private static func stamped(_ event: AgentEvent, sessionId: String) -> AgentEvent {
        guard event.sessionId != sessionId else { return event }
        return AgentEvent(
            agent: event.agent,
            sessionId: sessionId,
            cwd: event.cwd,
            kind: event.kind,
            timestamp: event.timestamp,
            detail: event.detail,
            toolUseId: event.toolUseId,
            usage: event.usage,
            model: event.model,
            attachments: event.attachments
        )
    }

    /// 读窗口并**连续爬过纯噪音窗**(0 可解析事件)—— 往文件头连读直到拿到事件 / 到文件头 / 触 `maxHops` 上限。
    /// attachment-heavy transcript 尾部/某段可能整窗都是 attachment(无 user/assistant/tool),
    /// 单窗 `readWindow` 会返回空 → 初始加载 / 加载更早会"无内容"。初始 + 切会话 + 加载更早三处共用。
    ///
    /// **丢消息根治(2026-06-21)**:旧实现遇空窗**大跳 `skipStride` 再小窗采样**,跳过的中间字节**从不读** ——
    /// 假设「跳过区全是噪音、无可见消息损失」,实测**被证伪**(真实 1.77GB 会话里一个 2MB 跳过区含 34 条真实
    /// user/assistant 消息,用户的真实提问连同模型回复整段被跳读丢失)。改为**连续爬**(空窗 → 往头**无缝**读一个
    /// `crawlSpan` 大窗,不留盲区):噪音区事件极少不撑爆列表(容器已是 NSTableView 虚拟化,§5.9 的 LazyVStack
    /// 顾虑已不适用),解析极廉价(§5.15:32MB ~100ms),连续不漏。
    public static func readWindowSkippingNoise(
        url: URL,
        agent: AgentKind = .claudeCode,
        endOffset: UInt64? = nil,
        windowBytes: Int = 262_144,
        maxHops: Int = 50,
        crawlSpan: UInt64 = 2 << 20
    ) -> HistoryWindow {
        var window = readWindow(url: url, agent: agent, endOffset: endOffset, windowBytes: windowBytes)
        var hops = 0
        while window.events.isEmpty, !window.reachedStart, hops < maxHops {
            // 空窗 → 往文件头**连续**读 [lo-span, lo)(endOffset=lo 与上窗无缝衔接,**不跳字节**)→ 覆盖原本被
            // skipStride 大跳漏掉的真实消息;不足一窗(near 头)→ span=lo 收到头窗(reachedStart)。
            let lo = window.startOffset
            let span = Int(Swift.min(crawlSpan, lo))
            window = readWindow(url: url, agent: agent, endOffset: lo, windowBytes: span)
            hops += 1
        }
        return window
    }

    /// 初始加载:从尾部往前**累积到 ≥`minEvents` 条事件**(或到文件头 / 触 `maxWindows` 上限),保证开卡一屏有内容。
    /// 每窗仍走 `readWindowSkippingNoise`(有界 256KB + 跨噪音),**总量有界**(≤ maxWindows 窗)→ 不无限、不撑爆。
    /// 替代已删的 view 层 auto-chain(那个无限自滚)——初始填充放数据层一次读够,view 只管「上滑到顶再加一窗」。
    public static func readRecentHistory(
        url: URL,
        agent: AgentKind = .claudeCode,
        minEvents: Int = 40,
        maxWindows: Int = 8
    ) -> HistoryWindow {
        var window = readWindowSkippingNoise(url: url, agent: agent, endOffset: nil)
        var events = window.events
        var windows = 1
        while events.count < minEvents, !window.reachedStart, windows < maxWindows {
            let earlier = readWindowSkippingNoise(url: url, agent: agent, endOffset: window.startOffset)
            events = earlier.events + events
            window = earlier
            windows += 1
        }
        return HistoryWindow(events: events, startOffset: window.startOffset, reachedStart: window.reachedStart)
    }

    /// 「加载更早」按**可见 turn 行**累积:从 `endOffset` 往文件头连读窗口,直到 `buildTurns` 产出
    /// ≥`minRows` 个**可见 turn 行**(或到文件头 / 触 `maxWindows` × `windowBytes` 字节预算上限)。
    ///
    /// 大型 agentic 日志约 **0.3 turn/MB**(巨型 tool_result 占满字节却折进 turn 元数据不可见)→ 凑够 10 行需
    /// 读 ~32MB。**实测解析 32MB 真实 transcript 仅 ~100ms**(2026-06-20:曾以为解析是 1-2s 瓶颈、差点上索引/
    /// 懒加载大系统,测量推翻 → 解析极廉价,瓶颈只是字节预算上限)→ 故直接放大预算:`windowBytes` 2MB × `maxWindows` 16
    /// = **32MB 上限**,后台读+解析 ~100-150ms。普通会话早停(读 ≤1 窗),重型会话凑够 ~`minRows` 行 → 丝滑。
    /// mega-turn(单轮 30MB+ 工具输出)是字节内联物理下限,仍 ~少数行,任何方案都救不了(首次滚过都得读完它)。
    public static func readEarlierRows(
        url: URL,
        agent: AgentKind = .claudeCode,
        endOffset: UInt64,
        minRows: Int = 10,
        maxWindows: Int = 16,
        windowBytes: Int = 2_097_152
    ) -> HistoryWindow {
        var window = readWindowSkippingNoise(url: url, agent: agent, endOffset: endOffset, windowBytes: windowBytes)
        var events = window.events
        var windows = 1
        // 可见行 = turn 行数(buildTurns 折叠后)。事件数累计很小(每窗 ~数条),buildTurns O(events) → 重算廉价。
        while AgentConversation.buildTurns(from: events).count < minRows,
              !window.reachedStart, windows < maxWindows {
            let earlier = readWindowSkippingNoise(url: url, agent: agent, endOffset: window.startOffset, windowBytes: windowBytes)
            events = earlier.events + events
            window = earlier
            windows += 1
        }
        return HistoryWindow(events: events, startOffset: window.startOffset, reachedStart: window.reachedStart)
    }

    public static func fingerprint(url: URL) -> SessionFileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return SessionFileFingerprint(mtime: mtime, size: size)
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
    }
}
