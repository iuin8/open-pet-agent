import Foundation
import Testing
import AgentMode
import Shell
@testable import App

// ACP-3 usage UI 纯映射单测:ACPUsage(usage_update)→ ChatCardState 上下文占用字段 +
// cost 展示格式化。engine onUsage 回调 → wiring 是 Task { @MainActor } hop(同 onThought),
// 与 wireACPPermissionHandler 集成部分不在此单测。

@MainActor
@Suite("ACPUsageWiring")
struct ACPUsageWiringTests {

    @Test("applyContextUsage: used/size/cost 落到 ChatCardState(composer 占用条数据源)")
    func applyContextUsageSetsState() {
        let state = ChatCardState()
        MinimalAppDelegate.applyContextUsage(
            ACPUsage(used: 12_345, size: 200_000, cost: .init(amount: 0.0123, currency: "USD")),
            to: state
        )
        #expect(state.contextUsed == 12_345)
        #expect(state.contextSize == 200_000)
        #expect(state.contextCost == "$0.0123")
    }

    @Test("applyContextUsage: agent 未报 cost → contextCost=nil(占用条只显 used/size)")
    func applyContextUsageWithoutCost() {
        let state = ChatCardState()
        MinimalAppDelegate.applyContextUsage(
            ACPUsage(used: 42_000, size: 1_000_000),
            to: state
        )
        #expect(state.contextUsed == 42_000)
        #expect(state.contextSize == 1_000_000)
        #expect(state.contextCost == nil)
    }

    @Test("formatUsageCost: USD → $ 前缀;其它币种原样前缀")
    func formatUsageCostCurrency() {
        #expect(MinimalAppDelegate.formatUsageCost(.init(amount: 0.0123, currency: "USD")) == "$0.0123")
        #expect(MinimalAppDelegate.formatUsageCost(.init(amount: 1.5, currency: "CNY")) == "CNY 1.5000")
    }

    @Test("applyContextUsage: size=nil(fallback 只报 used)不覆盖此前已知窗口 —— 精确值留住")
    func applyContextUsageKeepsKnownSize() {
        let state = ChatCardState()
        MinimalAppDelegate.applyContextUsage(ACPUsage(used: 10_000, size: 200_000), to: state)
        MinimalAppDelegate.applyContextUsage(ACPUsage(used: 29_661, size: nil), to: state)
        #expect(state.contextUsed == 29_661)
        #expect(state.contextSize == 200_000)
    }
}
