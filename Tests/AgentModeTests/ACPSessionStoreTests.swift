import Testing
import Foundation
@testable import AgentMode

// ACPSessionStore 持久化测试:hermetic 临时路径,覆盖 round-trip / 跨实例(跨重启语义)/
// remove / 损坏恢复 / key 格式。范式对齐 ConversationStore(原子写 + .bak 恢复)。

@Suite("ACPSessionStore")
struct ACPSessionStoreTests {

    private func hermeticURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-sessions-test-\(UUID().uuidString).json")
    }

    @Test("set → 同 key 读回;不同 key 隔离(engine|cwd 各自指针)")
    func roundTrip() async {
        let store = ACPSessionStore(storeURL: hermeticURL())
        await store.load()
        await store.set(sessionId: "ses_1", forKey: "openCode|/tmp/a")
        #expect(await store.sessionId(forKey: "openCode|/tmp/a") == "ses_1")
        #expect(await store.sessionId(forKey: "openCode|/tmp/b") == nil)
    }

    @Test("持久化:新实例从磁盘读回(跨重启恢复语义)")
    func persistsAcrossInstances() async {
        let url = hermeticURL()
        let store1 = ACPSessionStore(storeURL: url)
        await store1.load()
        await store1.set(sessionId: "ses_x", forKey: "k")

        let store2 = ACPSessionStore(storeURL: url)
        await store2.load()
        #expect(await store2.sessionId(forKey: "k") == "ses_x")
    }

    @Test("remove 清指针并落盘(指针失效回退)")
    func removeClears() async {
        let url = hermeticURL()
        let store = ACPSessionStore(storeURL: url)
        await store.load()
        await store.set(sessionId: "ses_1", forKey: "k")
        await store.remove(forKey: "k")
        #expect(await store.sessionId(forKey: "k") == nil)

        let store2 = ACPSessionStore(storeURL: url)
        await store2.load()
        #expect(await store2.sessionId(forKey: "k") == nil)
    }

    @Test("损坏文件 → .bak 恢复不崩,从空开始,仍可写")
    func corruptionRecovery() async throws {
        let url = hermeticURL()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let store = ACPSessionStore(storeURL: url)
        await store.load()
        #expect(await store.sessionId(forKey: "k") == nil)

        await store.set(sessionId: "s", forKey: "k")
        #expect(await store.sessionId(forKey: "k") == "s")
    }

    @Test("key 格式:engineKind|cwd")
    func keyFormat() {
        #expect(ACPSessionStore.key(engineKind: "openCode", cwd: "/tmp") == "openCode|/tmp")
    }
}
