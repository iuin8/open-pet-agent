import Foundation
import Testing
@testable import Orchestrator

// AgentSessionHandoffTracker 单测(P4 起;P5 改首见语义):会话桶(engineKind|cwd)
// **首次进入** → 一次性交接背景;首个桶/已见过的桶/空摘要不交接。
// P5:@mention 多引擎交错(→A→B→A)时,回到旧桶**不重复交接** —— 该桶 engine 自己的
// ACP session 仍持上下文,重复注入纯费 token。

@Suite("AgentSessionHandoffTracker")
struct AgentSessionHandoffTrackerTests {

    /// @Sendable transcript 闭包捕获用的标志盒(避 Swift 6 captured-var 警告)。
    private final class FlagBox: @unchecked Sendable { var value = false }

    @Test("首轮(首个桶)→ nil,不交接")
    func firstRunNoHandoff() async {
        let tracker = AgentSessionHandoffTracker()
        let ctx = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { "背景" }
        #expect(ctx == nil)
    }

    @Test("同桶再来 → nil(只首见那一下交接,不逐条重复)")
    func sameBucketNoHandoff() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { "背景" }
        let ctx = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { "背景" }
        #expect(ctx == nil)
    }

    @Test("新桶(已有旧桶)→ 调 transcript 返回摘要;再同桶 → 不再交接(一次性)")
    func firstSeenHandsOffOnce() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { nil }
        let ctx = await tracker.contextIfFirstSeen(bucket: "codex|/a") { "背景-来自opencode" }
        #expect(ctx == "背景-来自opencode")
        let again = await tracker.contextIfFirstSeen(bucket: "codex|/a") { "不应再出现" }
        #expect(again == nil)
    }

    @Test("P5:回到**见过的**旧桶 → 不重复交接(engine 自有 session 持上下文)")
    func returnToSeenBucketNoHandoff() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { nil }
        _ = await tracker.contextIfFirstSeen(bucket: "codex|/a") { "交接给codex" }
        // @opencode → @codex → @opencode:回 opencode 不再注入(engine session 还在)
        let back = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { "不应出现" }
        #expect(back == nil)
    }

    @Test("新桶但 transcript=nil(空时间线)→ nil 且桶已标记(不逐条重试)")
    func emptyTranscriptStillMarksSeen() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { nil }
        let first = await tracker.contextIfFirstSeen(bucket: "codex|/a") { nil }
        #expect(first == nil)
        // 若桶没标记,这次同桶调用会因"首见"而再调 transcript
        let second = await tracker.contextIfFirstSeen(bucket: "codex|/a") { "不应出现" }
        #expect(second == nil)
    }

    @Test("transcript 惰性:已见过的桶不调用(省 store 读取)")
    func transcriptLazy() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { nil }
        let called = FlagBox()
        let ctx = await tracker.contextIfFirstSeen(bucket: "openCode|/a") {
            called.value = true
            return "x"
        }
        #expect(ctx == nil)
        #expect(!called.value)
    }

    @Test("P5:第三个桶(新项目/新引擎)仍首见 → 正常交接")
    func thirdBucketStillHandsOff() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfFirstSeen(bucket: "openCode|/a") { nil }
        _ = await tracker.contextIfFirstSeen(bucket: "codex|/a") { "给codex" }
        // 切项目 → 新桶(cwd 变)→ 首见交接
        let ctx = await tracker.contextIfFirstSeen(bucket: "openCode|/b") { "给新项目" }
        #expect(ctx == "给新项目")
    }
}
