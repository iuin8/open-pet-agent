import Foundation
import Testing
@testable import Orchestrator

// AgentSessionHandoffTracker 单测(P4):桶(engineKind|cwd)变化 → 一次性交接背景;
// 首轮/同桶/空摘要不交接;并发安全由 actor 串行化(逻辑覆盖即可)。

@Suite("AgentSessionHandoffTracker")
struct AgentSessionHandoffTrackerTests {

    @Test("首轮(lastBucket=nil)→ nil,不交接")
    func firstRunNoHandoff() async {
        let tracker = AgentSessionHandoffTracker()
        let ctx = await tracker.contextIfBucketChanged(bucket: "openCode|/a") { "背景" }
        #expect(ctx == nil)
    }

    @Test("同桶 → nil(只在变化那一下交接,不逐条重复)")
    func sameBucketNoHandoff() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfBucketChanged(bucket: "openCode|/a") { "背景" }
        let ctx = await tracker.contextIfBucketChanged(bucket: "openCode|/a") { "背景" }
        #expect(ctx == nil)
    }

    @Test("桶变化 → 调 transcript 返回摘要;再同桶 → 不再交接(一次性)")
    func bucketChangeHandsOffOnce() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfBucketChanged(bucket: "openCode|/a") { nil }
        let ctx = await tracker.contextIfBucketChanged(bucket: "claudeCode|/a") { "背景-来自opencode" }
        #expect(ctx == "背景-来自opencode")
        let again = await tracker.contextIfBucketChanged(bucket: "claudeCode|/a") { "不应再出现" }
        #expect(again == nil)
    }

    @Test("桶变化但 transcript=nil(空时间线)→ nil 且桶已更新(不逐条重试)")
    func emptyTranscriptStillAdvancesBucket() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfBucketChanged(bucket: "openCode|/a") { nil }
        let first = await tracker.contextIfBucketChanged(bucket: "codex|/a") { nil }
        #expect(first == nil)
        // 若桶没更新,这次同桶调用会因"与 openCode|/a 不同"而再调 transcript
        let second = await tracker.contextIfBucketChanged(bucket: "codex|/a") { "不应出现" }
        #expect(second == nil)
    }

    @Test("transcript 惰性:桶不变时不调用(省 store 读取)")
    func transcriptLazy() async {
        let tracker = AgentSessionHandoffTracker()
        _ = await tracker.contextIfBucketChanged(bucket: "openCode|/a") { nil }
        var called = false
        let ctx = await tracker.contextIfBucketChanged(bucket: "openCode|/a") {
            called = true
            return "x"
        }
        #expect(ctx == nil)
        #expect(!called)
    }
}
