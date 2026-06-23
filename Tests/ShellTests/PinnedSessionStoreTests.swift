import Testing
import Combine
import Foundation
@testable import Shell
@testable import AgentSensing

@Suite("PinnedSessionStore — UserDefaults 持久化")
struct PinnedSessionStoreTests {
    func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "pin-test-\(UUID().uuidString)")!
        return d
    }
    func ref(_ sid: String) -> PinnedSessionRef {
        PinnedSessionRef(agent: .claudeCode, sessionId: sid, filePath: "/a/\(sid).jsonl",
                         title: sid, gitBranch: "main", pinnedAt: Date(timeIntervalSince1970: 1))
    }

    @Test("pin → pinned 含 + isPinned 真;unpin → 移除")
    func pinUnpin() {
        let d = freshDefaults()
        let store = PinnedSessionStore(defaults: d)
        store.pin(ref("s1"))
        #expect(store.isPinned(agent: .claudeCode, sessionId: "s1"))
        #expect(store.pinned(for: .claudeCode).map(\.sessionId) == ["s1"])
        store.unpin(agent: .claudeCode, sessionId: "s1")
        #expect(!store.isPinned(agent: .claudeCode, sessionId: "s1"))
        #expect(store.pinned(for: .claudeCode).isEmpty)
    }

    @Test("重建 store 读回(持久化) + 同 sid 重复 pin 去重")
    func persistsAndDedups() {
        let d = freshDefaults()
        let a = PinnedSessionStore(defaults: d)
        a.pin(ref("s1")); a.pin(ref("s1"))   // 去重
        let b = PinnedSessionStore(defaults: d)   // 重建读回
        #expect(b.pinned(for: .claudeCode).map(\.sessionId) == ["s1"])
    }

    @Test("pin/unpin 各发一次 objectWillChange(浏览 sheet 观察它即时同步钉住)")
    @MainActor
    func notifiesObservers() {
        let store = PinnedSessionStore(defaults: freshDefaults())
        var ticks = 0
        let sub = store.objectWillChange.sink { ticks += 1 }
        store.pin(ref("s1"))
        store.unpin(agent: .claudeCode, sessionId: "s1")
        sub.cancel()
        #expect(ticks == 2)   // 一次 pin + 一次 unpin → 观察者(sheet/picker)随之刷新
    }
}
