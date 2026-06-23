import Foundation
import os

/// 感知层编排器:轮询 Claude / Codex 的活跃会话文件,增量 tail → 解析 → 折叠活动状态,
/// 把每条 `AgentEvent` + 状态跃迁推给接线层(`sink`)。
///
/// **actor**:内部 tailer offset / tracker 是可变共享态,用 actor 隔离(对照
/// `ProactiveSuggestionEngine` 的并发模型)。**不持 Timer** —— App 接线层持 Timer 周期调
/// `poll()`(同 `ProactiveSuggestionEngine.tick()`)。Foundation only,不碰 AppKit / pet 类型。
public actor AgentSensingService {

    /// 一次感知产出:事件本身(给气泡)+ 它引起的会话状态跃迁(给一次性情绪反应)。
    public struct Output: Sendable {
        public let event: AgentEvent
        public let transition: AgentActivityTracker.Transition?
        /// 是否为「静默检测合成的 idle」。`true` 时它不是真 transcript 事件 —— App 接线层应**只**
        /// 驱动活动视觉态回 idle,不进会话流 / 不发招牌动作 / 不出气泡(否则每次静默注入假「完成一轮」)。
        public let isSilenceIdle: Bool
        public init(event: AgentEvent, transition: AgentActivityTracker.Transition?, isSilenceIdle: Bool = false) {
            self.event = event
            self.transition = transition
            self.isSilenceIdle = isSilenceIdle
        }
    }

    private let claude: any TranscriptParser = ClaudeTranscriptParser()
    private let codex: any TranscriptParser = CodexTranscriptParser()
    private let claudeRoot: URL
    private let codexRoot: URL
    private let activeWindow: TimeInterval
    private let clock: @Sendable () -> Date
    private let sink: @Sendable (Output) async -> Void

    private var enabled: Bool
    /// path → (该文件的增量读取器, 用哪个 parser, 钉死的 sessionId)。
    private var tailers: [String: FileEntry] = [:]
    private var tracker = AgentActivityTracker()
    /// sessionId → 最近一次有新行(活动)的时刻。静默检测据此判「会话停了」。
    private var lastEventAt: [String: Date] = [:]
    /// sessionId → 最近一条事件是否为 toolUse(工具可能在飞)。静默检测跳过这种会话,
    /// 否则一个 >silenceThreshold 的长工具(build/test 无新行)会被误判成「停了」而错归 idle。
    private var lastEventWasToolUse: [String: Bool] = [:]
    /// sessionId → agent 类型。合成静默 idle 事件时需要。
    private var sessionAgent: [String: AgentKind] = [:]
    /// 会话超过这么久无新行 → 合成 idle(根治:Claude transcript 不产 .done,否则活跃态会卡死不回 idle)。
    /// 取 activeWindow 的一半但不超 8s:足够长不误判模型「思考间隙」,又够短让停手后桌宠及时归位。
    private var silenceThreshold: TimeInterval { Swift.min(activeWindow / 2, 8) }
    /// 每 agent 最近一次 poll 发现的最活跃文件(mtime 最新)。供陪伴卡片打开时回填会话历史。
    private var activeURLs: [AgentKind: URL] = [:]
    /// 最近 poll 发现的**全部**活跃会话(每 agent 多个,按 mtime 新→旧)。供会话切换 picker
    /// 把 sessionId 映射回 URL 拉历史。
    private var recentRefs: [AgentSessionRef] = []

    private static let log = Logger(subsystem: "io.openpetagent", category: "AgentSensing.service")

    private struct FileEntry {
        var tailer: FileTailer
        let agent: AgentKind
        let sessionId: String
    }

    public init(
        enabled: Bool = true,
        claudeRoot: URL = SessionDiscovery.claudeProjectsRoot,
        codexRoot: URL = SessionDiscovery.codexSessionsRoot,
        activeWindow: TimeInterval = 120,
        clock: @escaping @Sendable () -> Date = { Date() },
        sink: @escaping @Sendable (Output) async -> Void
    ) {
        self.enabled = enabled
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.activeWindow = activeWindow
        self.clock = clock
        self.sink = sink
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        if !on { tailers.removeAll(); activeURLs.removeAll() }   // 关掉时丢掉 offset/活跃记录,重开从末尾起(不回放静默期)
    }

    /// 跑一轮:发现活跃文件 → 各自吐新行 → 解析 → 折叠 → sink。App Timer 周期调。
    public func poll() async {
        guard enabled else { return }
        let now = clock()
        let claudeFiles = SessionDiscovery.recentJSONL(under: claudeRoot, within: activeWindow, now: now)
        let codexFiles = SessionDiscovery.recentJSONL(under: codexRoot, within: activeWindow, now: now)

        for url in claudeFiles { await process(url: url, agent: .claudeCode) }
        for url in codexFiles { await process(url: url, agent: .codex) }

        // 记录每 agent 最活跃文件(recentJSONL 按 mtime 新→旧排,.first = 最新),供卡片回填历史。
        var nextActive: [AgentKind: URL] = [:]
        if let u = claudeFiles.first { nextActive[.claudeCode] = u }
        if let u = codexFiles.first { nextActive[.codex] = u }
        activeURLs = nextActive
        // 记录全部活跃会话(picker 用 sessionId → URL 拉历史)。
        recentRefs = claudeFiles.map { AgentSessionRef(agent: .claudeCode, sessionId: Self.canonicalSessionId(from: $0), url: $0) }
            + codexFiles.map { AgentSessionRef(agent: .codex, sessionId: Self.canonicalSessionId(from: $0), url: $0) }

        // 剪掉已不活跃的文件,避免 tailer 字典无限长(再次活跃会重新从末尾注册)。
        let active = Set((claudeFiles + codexFiles).map(\.path))
        tailers = tailers.filter { active.contains($0.key) }

        await emitSilenceIdle(now: now)
    }

    /// 静默检测:活跃态(working/talking)会话超 `silenceThreshold` 无新行 → 合成 idle 跃迁推下游。
    /// **根治**:Claude transcript 不写 Stop hook → parser 永不产 `.done` → tracker 对 Claude 会话
    /// 永停在最后一条内容事件态(多为 talking),活动视觉态卡死不回 idle(用户报「哆啦一直挥手」的「一直」)。
    /// awaitingUser(等你)/已是 idle 的不动;合成事件标 `isSilenceIdle` 让接线层只切视觉态、不进会话流/不出气泡。
    private func emitSilenceIdle(now: Date) async {
        for (sid, state) in tracker.states {
            guard state == .working || state == .talking else { continue }
            guard lastEventWasToolUse[sid] != true else { continue }   // 工具在飞(长 build/test 无新行)→ 别误判停了
            guard let last = lastEventAt[sid], now.timeIntervalSince(last) >= silenceThreshold else { continue }
            let synthesized = AgentEvent(
                agent: sessionAgent[sid] ?? .claudeCode, sessionId: sid, cwd: nil, kind: .done, timestamp: now)
            if let transition = tracker.ingest(synthesized) {
                await sink(Output(event: synthesized, transition: transition, isSilenceIdle: true))
            }
            lastEventAt[sid] = now   // 防下一拍重复合成(直到有新活动刷新)
        }
    }

    /// 每 agent 当前最活跃会话文件(上一次 `poll` 的发现快照)。陪伴卡片打开时据此读历史。
    /// 无活跃会话(静默期 / 未 poll)→ 对应 key 缺席。
    public func activeSessionURLs() -> [AgentKind: URL] { activeURLs }

    /// 最近发现的全部活跃会话(按 mtime 新→旧)。会话切换 picker 用它把 sessionId 映射回 URL。
    public func recentSessions() -> [AgentSessionRef] { recentRefs }

    // MARK: - 单文件处理

    private func process(url: URL, agent: AgentKind) async {
        let key = url.path
        guard var entry = tailers[key] else {
            // 首次遇到 → seek 到末尾,只感知「此刻起」的新行,绝不回放历史(可达数百 MB)。
            tailers[key] = FileEntry(
                tailer: FileTailer(url: url, startAtEnd: true),
                agent: agent,
                sessionId: Self.canonicalSessionId(from: url)
            )
            Self.log.debug("注册会话 \(url.lastPathComponent, privacy: .public)")
            return
        }
        let lines = entry.tailer.readNewLines()
        tailers[key] = entry   // 写回推进后的 offset
        guard !lines.isEmpty else { return }

        let parser = (agent == .codex) ? codex : claude
        for line in lines {
            // 一行可能产多事件(assistant 既叙述又调工具,P0-2)→ 逐个 ingest + 转发。
            for raw in parser.parse(line: line, fallbackSessionId: entry.sessionId, fallbackCwd: nil) {
                // 钉死每文件 sessionId(Codex session_meta.id 可能与后续行兜底不一致 → 折叠会拆键)。
                let event = stamped(raw, sessionId: entry.sessionId)
                lastEventAt[entry.sessionId] = clock()   // 有新行 = 会话活着,刷新静默计时
                sessionAgent[entry.sessionId] = agent
                if case .toolUse = event.kind { lastEventWasToolUse[entry.sessionId] = true }
                else { lastEventWasToolUse[entry.sessionId] = false }
                let transition = tracker.ingest(event)
                await sink(Output(event: event, transition: transition))
            }
        }
    }

    private func stamped(_ e: AgentEvent, sessionId: String) -> AgentEvent {
        guard e.sessionId != sessionId else { return e }
        // detail / attachments 必须随重建保留 —— Codex 工具行常带自身 id(≠文件名)走这条分支,丢了详情/图就没了。
        return AgentEvent(agent: e.agent, sessionId: sessionId, cwd: e.cwd, kind: e.kind, timestamp: e.timestamp,
                          detail: e.detail, attachments: e.attachments)
    }

    /// 用文件名(去后缀)作每文件稳定 id。Claude=`<uuid>.jsonl`,Codex=`rollout-<ts>-<uuid>.jsonl`。
    /// `public`:App 接线层回填历史时用同一规则算 sessionId,确保与实时事件钉死的 id 一致。
    public static func canonicalSessionId(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
