import Testing
import Foundation
@testable import Orchestrator

// MARK: - Helpers

private func makeTmpURL(suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("convstore-\(UUID().uuidString)\(suffix).json")
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    // Also clean up .bak and .tmp
    let bak = url.deletingPathExtension().appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: bak)
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + ".tmp")
    try? FileManager.default.removeItem(at: tmp)
}

private func makeMessage(
    role: LLMRole = .user,
    content: String = "hello",
    model: String? = nil
) -> ConversationMessage {
    ConversationMessage(
        id: UUID(),
        role: role,
        content: content,
        timestamp: Date(),
        model: model
    )
}

// MARK: - ConversationStoreTests

@Suite("ConversationStore — load / append / persist / error recovery")
struct ConversationStoreTests {

    // MARK: 1. init + load with missing file → empty messages

    @Test("init + load on missing file yields empty messages")
    func initLoadMissingFileYieldsEmpty() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()

        let msgs = await store.messages()
        #expect(msgs.isEmpty)
    }

    // MARK: 2. append + messages → order preserved, fields match

    @Test("append preserves insertion order and field values")
    func appendPreservesOrderAndFields() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()

        let msg1 = makeMessage(role: .user, content: "first", model: nil)
        let msg2 = makeMessage(role: .assistant, content: "second", model: "gpt-4o-mini")
        await store.append(msg1)
        await store.append(msg2)

        let msgs = await store.messages()
        #expect(msgs.count == 2)
        #expect(msgs[0].id == msg1.id)
        #expect(msgs[0].role == .user)
        #expect(msgs[0].content == "first")
        #expect(msgs[0].model == nil)
        #expect(msgs[1].id == msg2.id)
        #expect(msgs[1].role == .assistant)
        #expect(msgs[1].content == "second")
        #expect(msgs[1].model == "gpt-4o-mini")
    }

    // MARK: 3. append + new instance load same URL → messages survive restart

    @Test("append then new instance load reproduces same messages (persist round-trip)")
    func appendThenNewInstanceLoadReproducesMessages() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let msg1 = makeMessage(role: .user, content: "persisted user")
        let msg2 = makeMessage(role: .assistant, content: "persisted assistant", model: "ollama")

        do {
            let store = ConversationStore(storeURL: url)
            try await store.load()
            await store.append(msg1)
            await store.append(msg2)
        }

        // Simulate app restart with new instance
        let store2 = ConversationStore(storeURL: url)
        try await store2.load()

        let msgs = await store2.messages()
        #expect(msgs.count == 2)
        #expect(msgs[0].id == msg1.id)
        #expect(msgs[0].content == "persisted user")
        #expect(msgs[1].id == msg2.id)
        #expect(msgs[1].content == "persisted assistant")
        #expect(msgs[1].model == "ollama")
    }

    // MARK: 4. append → file actually written to storeURL

    @Test("append writes file to storeURL on disk")
    func appendWritesFileToDisk() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()

        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        await store.append(makeMessage(content: "disk check"))

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: 5. atomic write — no .tmp residue after append

    @Test("atomic write leaves no .tmp residue after append")
    func atomicWriteLeavesNoTmpResidue() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()
        await store.append(makeMessage(content: "atomic test"))

        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        #expect(FileManager.default.fileExists(atPath: tmpURL.path) == false)
    }

    // MARK: 6. clear → memory empty + disk also cleared

    @Test("clear empties memory and disk, new instance load sees empty")
    func clearEmptiesMemoryAndDisk() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()
        await store.append(makeMessage(content: "to be cleared"))
        await store.clear()

        let memMsgs = await store.messages()
        #expect(memMsgs.isEmpty)

        // New instance should also see empty
        let store2 = ConversationStore(storeURL: url)
        try await store2.load()
        let diskMsgs = await store2.messages()
        #expect(diskMsgs.isEmpty)
    }

    // MARK: 7. JSON corruption recovery → .bak exists, messages empty

    @Test("corrupt JSON triggers .bak recovery: messages empty, .bak file exists")
    func corruptJSONTriggersBackupRecovery() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        // Write corrupt JSON to simulate a damaged file
        let corrupt = Data("THIS IS NOT VALID JSON {{{{".utf8)
        try corrupt.write(to: url)

        let store = ConversationStore(storeURL: url)
        try await store.load()  // should NOT throw

        let msgs = await store.messages()
        #expect(msgs.isEmpty)

        // .bak file should exist
        let bakURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".bak"
            )
        #expect(FileManager.default.fileExists(atPath: bakURL.path))
    }

    // MARK: 8. directory auto-creation

    @Test("storeURL in non-existent subdirectory: directory auto-created after append")
    func directoryAutoCreatedOnAppend() async throws {
        let newSubdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convstore-autodir-\(UUID().uuidString)", isDirectory: true)
        let url = newSubdir.appendingPathComponent("conversations.json")
        defer {
            try? FileManager.default.removeItem(at: newSubdir)
        }

        #expect(FileManager.default.fileExists(atPath: newSubdir.path) == false)

        let store = ConversationStore(storeURL: url)
        try await store.load()
        await store.append(makeMessage(content: "dir creation test"))

        #expect(FileManager.default.fileExists(atPath: newSubdir.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: 9. truncatedMessages stub returns all messages (A.2.1)

    @Test("truncatedMessages stub returns all messages (A.2.1)")
    func truncatedMessagesStubReturnsAll() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()

        let messages = (0..<5).map { i in
            makeMessage(role: i % 2 == 0 ? .user : .assistant, content: "msg \(i)")
        }
        for msg in messages {
            await store.append(msg)
        }

        let truncated = await store.truncatedMessages(
            reservedReplyTokens: 2048,
            reservedSystemTokens: 1024,
            modelContextWindow: 4096
        )

        let all = await store.messages()
        #expect(truncated.count == all.count)
        #expect(truncated.map(\.id) == all.map(\.id))
    }

    // MARK: 10. stress: 100 appends → order correct after reload

    @Test("100 sequential appends preserve order after reload")
    func hundredAppendsPreserveOrderAfterReload() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }

        let store = ConversationStore(storeURL: url)
        try await store.load()

        let contents = (0..<100).map { "message-\($0)" }
        for content in contents {
            await store.append(makeMessage(content: content))
        }

        let store2 = ConversationStore(storeURL: url)
        try await store2.load()
        let msgs = await store2.messages()

        #expect(msgs.count == 100)
        for (i, msg) in msgs.enumerated() {
            #expect(msg.content == "message-\(i)")
        }
    }
}
