// Tests/OrchestratorTests/ProactiveQuotesTests.swift
import Foundation
import Testing
import Context
@testable import Orchestrator

@Suite("ProactiveQuotes")
struct ProactiveQuotesTests {
    /// 固定取第 0 句的 randomIndex（确定性）。
    private let zero: (Int) -> Int = { _ in 0 }

    @Test("coding 桶：前台 app 含编辑器关键词 → 抽 coding 句")
    func codingBucket() {
        let snap = DesktopSnapshot(visibleApplicationName: "Xcode")
        let q = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: zero)
        #expect(q != nil)
        #expect(ProactiveQuotes.codingQuotes.contains(q!))
    }

    @Test("coding 关键词大小写不敏感（VS Code / idea / vim）")
    func codingKeywordsCaseInsensitive() {
        for app in ["Visual Studio Code", "IntelliJ IDEA", "MacVim", "Cursor"] {
            let snap = DesktopSnapshot(visibleApplicationName: app)
            let q = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: zero)
            #expect(ProactiveQuotes.codingQuotes.contains(q!), "\(app) 应进 coding 桶")
        }
    }

    @Test("browsing 桶：浏览器 app → 抽 browsing 句")
    func browsingBucket() {
        for app in ["Safari", "Google Chrome", "Microsoft Edge", "Firefox"] {
            let snap = DesktopSnapshot(visibleApplicationName: app)
            let q = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: zero)
            #expect(ProactiveQuotes.browsingQuotes.contains(q!), "\(app) 应进 browsing 桶")
        }
    }

    @Test("chatting 桶：聊天 app → 抽 chatting 句")
    func chattingBucket() {
        for app in ["WeChat", "微信", "Slack", "Telegram", "QQ", "飞书"] {
            let snap = DesktopSnapshot(visibleApplicationName: app)
            let q = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: zero)
            #expect(ProactiveQuotes.chattingQuotes.contains(q!), "\(app) 应进 chatting 桶")
        }
    }

    @Test("lateNight 桶：深夜时段优先于 app 桶")
    func lateNightOverridesApp() {
        // 即便在写代码，深夜也走 lateNight 桶（关怀优先）。
        let snap = DesktopSnapshot(visibleApplicationName: "Xcode")
        for hour in [23, 0, 4] {
            let q = ProactiveQuotes.pick(snapshot: snap, hour: hour, avoiding: nil, randomIndex: zero)
            #expect(ProactiveQuotes.lateNightQuotes.contains(q!), "hour=\(hour) 应进 lateNight 桶")
        }
    }

    @Test("generic 兜底：无 snapshot / 不识别的 app → generic 桶")
    func genericFallback() {
        let q1 = ProactiveQuotes.pick(snapshot: nil, hour: 14, avoiding: nil, randomIndex: zero)
        #expect(ProactiveQuotes.genericQuotes.contains(q1!))
        let snap = DesktopSnapshot(visibleApplicationName: "SomeUnknownApp")
        let q2 = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: zero)
        #expect(ProactiveQuotes.genericQuotes.contains(q2!))
    }

    @Test("avoiding：抽到与 last 相同 → 换下一句（不立刻重复）")
    func avoidsImmediateRepeat() {
        let snap = DesktopSnapshot(visibleApplicationName: "Xcode")
        let first = ProactiveQuotes.codingQuotes[0]
        // randomIndex 仍返回 0（=first），但 avoiding=first → 应换成下一句。
        let q = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: first, randomIndex: zero)
        #expect(q != nil)
        #expect(q != first)
        #expect(ProactiveQuotes.codingQuotes.contains(q!))
    }

    @Test("randomIndex 注入确定性：不同索引取不同句")
    func randomIndexDeterministic() {
        let snap = DesktopSnapshot(visibleApplicationName: "Xcode")
        let q0 = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: { _ in 0 })
        let q1 = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: { _ in 1 })
        #expect(q0 == ProactiveQuotes.codingQuotes[0])
        #expect(q1 == ProactiveQuotes.codingQuotes[1])
    }

    @Test("randomIndex 越界自动取模归位（防注入非法值崩溃）")
    func randomIndexOutOfRangeWraps() {
        let snap = DesktopSnapshot(visibleApplicationName: "Xcode")
        let count = ProactiveQuotes.codingQuotes.count
        let q = ProactiveQuotes.pick(snapshot: snap, hour: 14, avoiding: nil, randomIndex: { _ in count })
        #expect(q == ProactiveQuotes.codingQuotes[0])  // count % count == 0
    }

    @Test("每桶 6-8 句、≤20 字、无空句")
    func bucketsWellFormed() {
        let buckets = [
            ProactiveQuotes.codingQuotes,
            ProactiveQuotes.browsingQuotes,
            ProactiveQuotes.chattingQuotes,
            ProactiveQuotes.lateNightQuotes,
            ProactiveQuotes.genericQuotes,
        ]
        for bucket in buckets {
            #expect(bucket.count >= 6 && bucket.count <= 8)
            for line in bucket {
                #expect(!line.isEmpty)
                #expect(line.count <= 20, "短句应 ≤20 字：\(line)")
            }
        }
    }
}
