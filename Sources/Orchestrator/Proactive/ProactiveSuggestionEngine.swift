// Sources/Orchestrator/Proactive/ProactiveSuggestionEngine.swift
import Context
import Foundation

/// 主动建议运行时编排 actor。串行三入口（feedAppSwitch / feedSleepingChanged / tick），
/// 每条候选过：evaluate（判定）→ 安全时机门（isGenerating / 用户对话中）→ throttle 三道闸
/// → 组 prompt → no-history 生成 → sink 落气泡。判定/节流/组词全委托纯函数层，actor 只编排。
public actor ProactiveSuggestionEngine {
    // MARK: - 注入边界
    private let snapshotProvider: @Sendable () async -> DesktopSnapshot?
    private let generator: any ProactiveSuggestionGenerating
    private let sink: @Sendable (String, String) async -> Void
    private let isStreamingProvider: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    /// 第 1 层碎碎念取一句预设短语（snap, hour, avoiding 上一句）。默认 nil（不出碎碎念）。
    private let quoteProvider: @Sendable (DesktopSnapshot?, Int, String?) -> String?
    /// 自主节奏间隔随机源（注入便于测试用固定值）。默认 `Double.random(in:)`。
    private let random: @Sendable (ClosedRange<TimeInterval>) -> TimeInterval

    // MARK: - 可变状态
    private var settings: ProactiveSettings
    private var throttleState: ProactiveThrottleState
    private var isGenerating = false
    private var lastAppName: String?
    private var lastAppSwitchAt: Date?
    private var wentSleepAt: Date?
    private var dwellKey: String?
    private var dwellSeconds: TimeInterval = 0
    private var dwellFired = false
    /// 第 1 层碎碎念下次到期时间（nil = 首个 tick 时随机排程）。
    private var nextChatterAt: Date?
    /// 第 2 层 LLM 自主闲聊下次到期时间。
    private var nextAutonomousAt: Date?
    /// 上一句碎碎念（避免立刻重复）。
    private var lastChatterQuote: String?

    /// app 切换去抖窗口（秒）。
    private static let appSwitchDebounce: TimeInterval = 3
    /// tick 周期（秒），dwell 每 tick +此值。
    public static let tickIntervalSeconds: TimeInterval = 30

    public init(
        settings: ProactiveSettings,
        throttleState: ProactiveThrottleState = ProactiveThrottleState(),
        snapshotProvider: @escaping @Sendable () async -> DesktopSnapshot?,
        generator: any ProactiveSuggestionGenerating,
        sink: @escaping @Sendable (String, String) async -> Void,
        isStreamingProvider: @escaping @Sendable () async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        quoteProvider: @escaping @Sendable (DesktopSnapshot?, Int, String?) -> String? = { _, _, _ in nil },
        random: @escaping @Sendable (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }
    ) {
        self.settings = settings
        self.throttleState = throttleState
        self.snapshotProvider = snapshotProvider
        self.generator = generator
        self.sink = sink
        self.isStreamingProvider = isStreamingProvider
        self.now = now
        self.calendar = calendar
        self.quoteProvider = quoteProvider
        self.random = random
    }

    // MARK: - 设置 / 反馈
    public func updateSettings(_ s: ProactiveSettings) { settings = s }
    public func recordIgnored() { throttleState = throttleState.recordIgnored() }
    public func recordEngaged() { throttleState = throttleState.recordEngaged() }

    // MARK: - 入口 A：app 切换（事件驱动 + 3s 去抖）
    public func feedAppSwitch(appName: String) async {
        let n = now()
        if let last = lastAppSwitchAt, n.timeIntervalSince(last) < Self.appSwitchDebounce {
            lastAppSwitchAt = n   // 只滑窗，不改 lastAppName（保持 = 上次真正触发的 app）
            return
        }
        guard appName != lastAppName else { return }
        lastAppName = appName
        lastAppSwitchAt = n
        dwellFired = false  // 切 app 复位 dwell 锁
        _ = await attempt(ProactiveSignal(kind: .appSwitch, appName: appName))
    }

    // MARK: - 入口 B：睡眠态翻转（true=睡 / false=回来）
    public func feedSleepingChanged(_ sleeping: Bool) async {
        if sleeping { wentSleepAt = now(); return }
        let away = wentSleepAt.map { now().timeIntervalSince($0) } ?? 0
        wentSleepAt = nil
        _ = await attempt(ProactiveSignal(kind: .idleReturn, awaySeconds: away))
    }

    // MARK: - 入口 C/D/E + 碎碎念：30s tick
    /// 每 tick **至多冒一条**。顺序：① 第 1 层碎碎念（预设短语，无 LLM）→ ② dwell → ③ 深夜
    /// → ④ 第 2 层 LLM 自主闲聊。前者命中即 return，不再往下。
    public func tick() async {
        let snap = await snapshotProvider()
        updateDwell(snapshot: snap)
        let sleeping = wentSleepAt != nil
        let n = now()
        let hour = calendar.component(.hour, from: n)

        // ① 第 1 层：碎碎念（预设短语，自己的轻节奏，不动 throttle 配额）。
        if await tickChatter(snap: snap, now: n, hour: hour) { return }

        // ② dwell 优先于 ③ lateNight
        if !dwellFired {
            let dwellSignal = ProactiveSignal(
                kind: .dwell,
                appName: snap?.visibleApplicationName,
                windowTitle: snap?.visibleWindows.first?.title,
                dwellSeconds: dwellSeconds
            )
            if ProactiveTriggerEvaluator.evaluate(signal: dwellSignal, settings: settings, hour: hour, isSleeping: sleeping) != nil {
                if await attempt(dwellSignal, snapshot: snap) { dwellFired = true }
                // dwell 优先于 lateNight：dwell 一旦构成候选（达阈值），本 tick 即只走 dwell 不再评 lateNight；
                // 即使 attempt 被 throttle 拒，本 tick 也不补评 lateNight（dwell 内容更具体，优先级更高，设计如此）。
                return
            }
        }
        let lateSignal = ProactiveSignal(kind: .lateNight)
        if ProactiveTriggerEvaluator.evaluate(signal: lateSignal, settings: settings, hour: hour, isSleeping: sleeping) != nil {
            if await attempt(lateSignal, snapshot: snap) { return }
        }

        // ④ 第 2 层：LLM 自主闲聊（场景 E，自己的节奏，复用 throttle 配额）。
        await tickAutonomous(snap: snap, now: n)
    }

    // MARK: - 私有 — 自主两层

    /// 第 1 层碎碎念：到期 + 安全门 → 取一句预设短语直接落气泡（不走 generator、不动配额）。
    /// 返回是否真冒了（用于 tick「每 tick 至多一条」短路）。
    private func tickChatter(snap: DesktopSnapshot?, now n: Date, hour: Int) async -> Bool {
        guard settings.chatterEnabled, settings.level != .off,
              let range = settings.chatterIntervalRange else { return false }
        if nextChatterAt == nil { nextChatterAt = n.addingTimeInterval(random(range)) }
        guard let due = nextChatterAt, n >= due else { return false }
        nextChatterAt = n.addingTimeInterval(random(range))   // 无论这次冒不冒都重排下次
        guard !isGenerating, !(await isStreamingProvider()) else { return false }  // 安全门
        guard let quote = quoteProvider(snap, hour, lastChatterQuote), !quote.isEmpty else { return false }
        lastChatterQuote = quote
        await sink(TriggerKind.chatter.displayName, quote)
        return true
    }

    /// 第 2 层 LLM 自主闲聊：到期 → 走 attempt（evaluate→安全门→throttle→生成），复用配额。
    private func tickAutonomous(snap: DesktopSnapshot?, now n: Date) async {
        guard settings.triggerAutonomous, let range = settings.autonomousIntervalRange else { return }
        if nextAutonomousAt == nil { nextAutonomousAt = n.addingTimeInterval(random(range)) }
        guard let due = nextAutonomousAt, n >= due else { return }
        nextAutonomousAt = n.addingTimeInterval(random(range))
        _ = await attempt(ProactiveSignal(kind: .autonomous, appName: snap?.visibleApplicationName), snapshot: snap)
    }

    // MARK: - 私有

    /// 同 app+title key 相同 → dwell 累积；不同 → 重置并解锁。
    private func updateDwell(snapshot: DesktopSnapshot?) {
        let key = "\(snapshot?.visibleApplicationName ?? "")|\(snapshot?.visibleWindows.first?.title ?? "")"
        if key == dwellKey {
            dwellSeconds += Self.tickIntervalSeconds
        } else {
            dwellKey = key
            dwellSeconds = 0
            dwellFired = false
        }
    }

    /// 统一闸门：evaluate → 安全时机门 → throttle → 生成 → sink。返回是否真正触发。
    private func attempt(_ signal: ProactiveSignal, snapshot: DesktopSnapshot? = nil) async -> Bool {
        let n = now()
        let hour = calendar.component(.hour, from: n)
        let sleeping = wentSleepAt != nil
        guard ProactiveTriggerEvaluator.evaluate(signal: signal, settings: settings, hour: hour, isSleeping: sleeping) != nil else { return false }
        guard !isGenerating else { return false }
        guard throttleState.decide(settings: settings, now: n) else { return false }
        // 在第一个 await 之前 claim isGenerating —— 防止 await isStreamingProvider() 挂起期间
        // 第二个 attempt 穿过所有闸门导致双发/双计配额（actor 在 await 处可重入）。
        isGenerating = true
        defer { isGenerating = false }
        if await isStreamingProvider() { return false }   // 用户正在对话 → 跳过；此时尚未 recordFired，不计配额
        throttleState = throttleState.recordFired(now: n)
        // 注：`??` 的 RHS 是 autoclosure，不支持 await（Swift 并发限制），改用显式分支保持等价语义。
        let snap: DesktopSnapshot?
        if let snapshot { snap = snapshot } else { snap = await snapshotProvider() }
        let prompt = ProactivePromptComposer.build(signal: signal, level: settings.level)
        do {
            let reply = try await generator.generate(prompt: prompt, snapshot: snap)
            // 兜底①：模型把要求当正文复述（英文 meta / 几乎无中文）→ 静默跳过这条，不弹废话气泡。
            guard !ProactiveReplyTrimmer.isLikelyMetaEcho(reply) else { return false }
            // 兜底②：长度——模型偶尔不守字数约束 → 按级别 charLimit 句界截断（折成一行）。
            let limit = ProactivePromptComposer.charLimit(for: settings.level)
            let trimmed = ProactiveReplyTrimmer.trim(reply, toCharLimit: limit)
            guard !trimmed.isEmpty else { return false }
            await sink(signal.kind.displayName, trimmed)
            return true
        } catch {
            // 主动建议失败 → 静默跳过（不给用户没要的东西弹错误气泡），不计 ignored。
            print("[ProactiveEngine] 生成失败，跳过：\(error)")
            return false
        }
    }
}
