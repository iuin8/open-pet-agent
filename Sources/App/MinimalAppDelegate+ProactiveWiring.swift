import AppKit
import Context
import Orchestrator

extension MinimalAppDelegate {
    /// applicationDidFinishLaunching 末段调（bondedSession + liveContextBox + orchestrator 就绪后）。
    /// 构造主动引擎、注入全部闭包、订阅三类信号源（NSWorkspace activate / idle fanout / 30s Timer）。
    @MainActor
    func setupProactiveEngine() {
        // bondedSession 是气泡落点；generator 是 no-history 生成器。任一缺席 → 不构造引擎。
        guard bondedSession != nil,
              let generator = rootSystem.proactiveGenerator
        else { return }

        // snapshotProvider：liveContextBox 持有 actor-isolated 闭包，wrap 一层适配引擎
        // 的 `() async -> DesktopSnapshot?` 签名（box / 内部 provider 任一缺席 → nil）。
        // liveContextBox 是 actor（Sendable），用局部 let 捕获 actor 引用而非 self → @Sendable 闭包合规、无循环持有。
        let liveBox = liveContextBox

        let engine = ProactiveSuggestionEngine(
            settings: proactiveSettings,
            snapshotProvider: { await liveBox?.snapshotProvider?() },
            generator: generator,
            sink: { [weak self] label, reply in
                // 主动建议落双气泡（不写 store）。注入 + 置 visible 标志都在主线程。
                // 先把 weak self 绑成 immutable let（weakSelf），再传入 MainActor.run —— 避免在
                // 并发闭包里二次引用可变 self（Swift 6 SendableClosureCaptures 错误）。
                let weakSelf = self
                await MainActor.run {
                    guard let strongSelf = weakSelf, let bonded = strongSelf.bondedSession else { return }
                    strongSelf.proactiveBubbleVisible = true
                    bonded.injectProactiveSuggestion(context: label, reply: reply) { [weak strongSelf] _ in
                        // 超时自然消失（未互动）→ 记忽略 + 清 visible 标志。
                        strongSelf?.proactiveBubbleVisible = false
                        Task { await strongSelf?.proactiveEngine?.recordIgnored() }
                    }
                }
            },
            isStreamingProvider: { [weak self] in
                // 用户正在对话（bonded 流式中）→ 引擎跳过本次主动建议。
                let weakSelf = self
                return await MainActor.run { weakSelf?.bondedSession?.isStreaming ?? false }
            },
            now: { Date() },
            calendar: .current,
            // 第 1 层碎碎念：从预设短语库按 app/时段抽一句（避免立刻重复）。纯函数、无 LLM。
            quoteProvider: { snap, hour, last in
                ProactiveQuotes.pick(
                    snapshot: snap,
                    hour: hour,
                    avoiding: last,
                    randomIndex: { $0 > 0 ? Int.random(in: 0..<$0) : 0 }
                )
            }
        )
        self.proactiveEngine = engine

        // 场景 A：自订 NSWorkspace.didActivateApplicationNotification（排除 OpenPetAgent 自身）。
        // 存 token → applicationWillTerminate 移除（防 observer 泄漏 + 持有 engine 引用）。
        proactiveAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let name = app.localizedName,
                name != "OpenPetAgent"
            else { return }
            Task { await self?.proactiveEngine?.feedAppSwitch(appName: name) }
        }

        // 场景 B：idle fanout → 主动引擎（与现有省电逻辑并联）。
        idleSleepingFanout?.subscribe { [weak self] sleeping in
            Task { await self?.proactiveEngine?.feedSleepingChanged(sleeping) }
        }

        // 场景 C/D：30s tick（dwell 累积 + 深夜）。
        let timer = Timer.scheduledTimer(
            withTimeInterval: ProactiveSuggestionEngine.tickIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.proactiveEngine?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.proactiveTickTimer = timer
    }

    /// 用户在主动建议气泡可见时召唤 chat → engaged（归零 decay）。
    /// 由 QuickAsk 召唤路径 / pet 点击路径调用。
    @MainActor
    func notifyProactiveEngagementIfVisible() {
        guard proactiveBubbleVisible else { return }
        proactiveBubbleVisible = false
        Task { await proactiveEngine?.recordEngaged() }
    }
}
