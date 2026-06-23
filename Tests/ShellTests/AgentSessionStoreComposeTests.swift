import Testing
import Foundation
@testable import Shell
@testable import AgentSensing

@Suite("AgentSessionStore — 列表合成(活跃∪钉住∪选中)")
struct AgentSessionStoreComposeTests {
    @MainActor
    func makeStore() -> (AgentSessionStore, PinnedSessionStore) {
        let pin = PinnedSessionStore(defaults: UserDefaults(suiteName: "compose-\(UUID().uuidString)")!)
        let s = AgentSessionStore(); s.setPinnedStore(pin); return (s, pin)
    }

    @Test("钉住会话即使无活跃事件也出现在列表,且 isPinned=真")
    @MainActor
    func pinnedAppearsWhenSilent() {
        let (s, pin) = makeStore()
        pin.pin(PinnedSessionRef(agent: .claudeCode, sessionId: "p1", filePath: "/a/p1.jsonl",
                                 title: "钉住的", gitBranch: "main", pinnedAt: Date(timeIntervalSince1970: 5)))
        s.refreshPinned(.claudeCode)   // 把钉住并进列表
        let row = s.sessions(for: .claudeCode).first { $0.id == "p1" }
        #expect(row != nil)
        #expect(row?.isPinned == true)
        #expect(row?.title == "钉住的")
    }

    @Test("当前选中会话即使非活跃非钉住也恒在列表(不掉出)")
    @MainActor
    func selectedAlwaysPresent() {
        let (s, _) = makeStore()
        s.noteLoadedSession(agent: .claudeCode, sessionId: "sel1",
                            meta: SessionMetadata(title: "浏览来的", projectName: "x", startTime: Date(),
                                                  gitBranch: "dev", messageCount: 3, lastModified: Date()))
        s.selectSession(agent: .claudeCode, sessionId: "sel1")
        let row = s.sessions(for: .claudeCode).first { $0.id == "sel1" }
        #expect(row?.isSelected == true)
        #expect(row?.title == "浏览来的")
        #expect(row?.isPinned == false)
    }

    @Test("钉住会话无元数据且非活跃(文件被删)→ isUnavailable 真,缓存 title 仍显")
    @MainActor
    func pinnedUnavailableWhenNoMeta() {
        let (s, pin) = makeStore()
        pin.pin(PinnedSessionRef(agent: .claudeCode, sessionId: "gone", filePath: "/deleted/gone.jsonl",
                                 title: "已删的", gitBranch: nil, pinnedAt: Date(timeIntervalSince1970: 1)))
        s.refreshPinned(.claudeCode)
        let row = s.sessions(for: .claudeCode).first { $0.id == "gone" }
        #expect(row?.isPinned == true)
        #expect(row?.isUnavailable == true)   // 无 metadata/inj + 非活跃 → 不可用
        #expect(row?.title == "已删的")        // 缓存 title 仍显(不丢钉)
    }
}
