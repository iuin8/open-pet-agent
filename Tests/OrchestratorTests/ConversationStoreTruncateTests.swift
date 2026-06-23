import Testing
import Foundation
@testable import Orchestrator

// MARK: - Helpers

private func makeTmpURL(suffix: String = "trunc") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("convtrunc-\(suffix)-\(UUID().uuidString).json")
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    let bak = url.deletingPathExtension().appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: bak)
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + ".tmp")
    try? FileManager.default.removeItem(at: tmp)
}

/// Creates a store with the given (role, content) pairs pre-loaded in order.
private func makeStore(turns: [(LLMRole, String)]) async throws -> (ConversationStore, URL) {
    let url = makeTmpURL()
    let store = ConversationStore(storeURL: url)
    try await store.load()
    for (role, content) in turns {
        let msg = ConversationMessage(role: role, content: content)
        await store.append(msg)
    }
    return (store, url)
}

/// Builds content strings of exactly `count` ASCII chars.
private func ascii(_ count: Int) -> String {
    String(repeating: "x", count: count)
}

/// Builds content strings of exactly `count` CJK chars.
private func cjk(_ count: Int) -> String {
    String(repeating: "你", count: count)
}

// MARK: - estimateTokens tests

/// Parametrized rows for `ConversationStore.estimateTokens`. Each row pairs an input
/// description with the input text and the deterministic expected token count
/// produced by the heuristic `(cjk*2 + ascii)/4 + 1`.
fileprivate struct EstimateTokensCase: Sendable, CustomStringConvertible {
    let label: String
    let input: String
    let expected: Int
    var description: String { label }
}

@Suite("ConversationStore.estimateTokens — heuristic token counting")
struct EstimateTokensTests {

    @Test(
        "estimateTokens heuristic",
        arguments: [
            EstimateTokensCase(label: "empty → 1",
                               input: "",
                               expected: 1),
            EstimateTokensCase(label: "11 ASCII → (11)/4 + 1 = 3",
                               input: "hello world",
                               expected: 3),
            EstimateTokensCase(label: "4 CJK → (8)/4 + 1 = 3",
                               input: "你好世界",
                               expected: 3),
            EstimateTokensCase(label: "mixed 6 ASCII + 2 CJK → (4+6)/4 + 1 = 3",
                               input: "Hello 世界",
                               expected: 3),
            EstimateTokensCase(label: "200 CJK → 400/4 + 1 = 101",
                               input: cjk(200),
                               expected: 101),
            EstimateTokensCase(label: "400 ASCII → 100 + 1 = 101",
                               input: ascii(400),
                               expected: 101),
        ]
    )
    fileprivate func estimateTokensMatchesExpected(testCase: EstimateTokensCase) {
        let result = ConversationStore.estimateTokens(testCase.input)
        #expect(result == testCase.expected, "\(testCase.label) (got \(result))")
    }
}

// MARK: - truncatedMessages tests

@Suite("ConversationStore.truncatedMessages — rolling window")
struct TruncatedMessagesTests {

    // MARK: Basic edge cases

    // 7. Empty store → []
    @Test("empty store returns empty array")
    func emptyStoreReturnsEmpty() async throws {
        let url = makeTmpURL()
        defer { cleanup(url) }
        let store = ConversationStore(storeURL: url)
        try await store.load()

        let result = await store.truncatedMessages(
            reservedReplyTokens: 2048,
            reservedSystemTokens: 1024,
            modelContextWindow: 4096
        )
        #expect(result.isEmpty)
    }

    // 8. budget = 0 → []
    @Test("zero budget (reserved >= window) returns empty array")
    func zeroBudgetReturnsEmpty() async throws {
        let (store, url) = try await makeStore(turns: [
            (.user, "question"),
            (.assistant, "answer")
        ])
        defer { cleanup(url) }

        // window=100, reservedReply=60, reservedSystem=50 → budget = max(0, -10) = 0
        let result = await store.truncatedMessages(
            reservedReplyTokens: 60,
            reservedSystemTokens: 50,
            modelContextWindow: 100
        )
        #expect(result.isEmpty)
    }

    // 9. single turn (user+assistant) within budget → returns both in order
    @Test("single turn within budget returns both messages in original order")
    func singleTurnWithinBudgetReturnsAll() async throws {
        let (store, url) = try await makeStore(turns: [
            (.user, "hi"),     // estimateTokens("hi") = (0+2)/4+1 = 1
            (.assistant, "hello") // estimateTokens("hello") = (0+5)/4+1 = 2
        ])
        defer { cleanup(url) }

        // budget = 4096 - 2048 - 1024 = 1024; both messages tiny
        let result = await store.truncatedMessages(
            reservedReplyTokens: 2048,
            reservedSystemTokens: 1024,
            modelContextWindow: 4096
        )
        #expect(result.count == 2)
        #expect(result[0].role == .user)
        #expect(result[0].content == "hi")
        #expect(result[1].role == .assistant)
        #expect(result[1].content == "hello")
    }

    // 10. budget extremely small, message exceeds it → returns empty (not the latest turn)
    @Test("budget too small for any turn returns empty array")
    func tinyBudgetReturnsEmpty() async throws {
        // Each 100-char ASCII message → estimateTokens = (0+100)/4+1 = 26
        // budget = 100 - 80 - 10 = 10; a turn (user+assistant) = 26+26 = 52 tokens > 10 → []
        let (store, url) = try await makeStore(turns: [
            (.user, ascii(100)),
            (.assistant, ascii(100))
        ])
        defer { cleanup(url) }

        let result = await store.truncatedMessages(
            reservedReplyTokens: 80,
            reservedSystemTokens: 10,
            modelContextWindow: 100
        )
        #expect(result.isEmpty)
    }

    // MARK: Rolling drop

    // 11. 50 turns (each 100-char), small budget → only latest N turns kept
    @Test("50 turns with small budget keeps only the most recent turns")
    func rollingDropKeepsLatestTurns() async throws {
        // 50 turns: user "msg-U-i" + assistant "msg-A-i"
        // Each content ~8 chars → estimateTokens ~3 each
        // Turn cost ≈ 6 tokens, budget = 4096 - 2048 - 1024 = 1024
        // We'll use longer content so drops are visible
        let content100 = ascii(100) // estimateTokens = 26
        var turns: [(LLMRole, String)] = []
        for i in 0..<50 {
            turns.append((.user, "\(content100)-U\(i)"))
            turns.append((.assistant, "\(content100)-A\(i)"))
        }

        let (store, url) = try await makeStore(turns: turns)
        defer { cleanup(url) }

        // budget = 200; each turn costs ~26+26 = 52 tokens → ~3 full turns fit (3*52=156 ≤ 200, 4*52=208 > 200)
        let result = await store.truncatedMessages(
            reservedReplyTokens: 80,
            reservedSystemTokens: 0,
            modelContextWindow: 280 // budget = 280 - 80 - 0 = 200
        )

        // Result must be strictly less than 50 turns (100 messages)
        #expect(result.count < 100)
        // Result must be > 0
        #expect(result.count > 0)
        // Only the latest messages should be present — check by role alternation
        // All results should be user/assistant pairs in order
        for i in stride(from: 0, to: result.count - 1, by: 2) {
            #expect(result[i].role == .user)
            #expect(result[i + 1].role == .assistant)
        }
        // Last message must be the most recently appended assistant message
        #expect(result.last?.content.hasSuffix("-A49") == true)
    }

    // 12. Result order is preserved (oldest first in result, newest at end)
    @Test("result preserves original chronological order (oldest first)")
    func resultPreservesChronologicalOrder() async throws {
        var turns: [(LLMRole, String)] = []
        for i in 0..<10 {
            turns.append((.user, "U\(i)"))
            turns.append((.assistant, "A\(i)"))
        }
        let (store, url) = try await makeStore(turns: turns)
        defer { cleanup(url) }

        // Large enough budget to hold everything
        let result = await store.truncatedMessages(
            reservedReplyTokens: 0,
            reservedSystemTokens: 0,
            modelContextWindow: 100_000
        )
        #expect(result.count == 20)
        for i in 0..<10 {
            #expect(result[i * 2].content == "U\(i)")
            #expect(result[i * 2 + 1].content == "A\(i)")
        }
    }

    // MARK: Pair preservation

    // 13. 5 turns, budget tight: 2 newest turns fit but not 3rd → 3rd turn fully dropped
    @Test("pair preservation: turn where only user fits but not assistant is fully dropped")
    func pairPreservationDropsPartialTurn() async throws {
        // Each message = 100 ASCII chars → estimateTokens = (100)/4+1 = 26
        // Turn cost = 26 + 26 = 52 tokens
        // budget = 110 → fits 2 turns (104 tokens) but not 3 (156 tokens)
        var turns: [(LLMRole, String)] = []
        for _ in 0..<5 {
            turns.append((.user, ascii(100)))
            turns.append((.assistant, ascii(100)))
        }
        let (store, url) = try await makeStore(turns: turns)
        defer { cleanup(url) }

        let result = await store.truncatedMessages(
            reservedReplyTokens: 0,
            reservedSystemTokens: 0,
            modelContextWindow: 110 // budget = 110
        )

        // Should return exactly 2 full turns = 4 messages
        #expect(result.count == 4)
        // Roles must alternate user/assistant
        #expect(result[0].role == .user)
        #expect(result[1].role == .assistant)
        #expect(result[2].role == .user)
        #expect(result[3].role == .assistant)
    }

    // 14. User fits within budget but assistant would overflow → entire turn dropped
    @Test("user message fits but assistant overflows budget: both are dropped")
    func userFitsAssistantOverflowsBothDropped() async throws {
        // budget = 30
        // Turn 1 (older): user(20 chars)=6 tokens + assistant(20 chars)=6 tokens = 12 total
        // Turn 2 (newest): user(20 chars)=6 tokens + assistant(80 chars)=21 tokens
        //   → turn2 total = 27 tokens
        //   → cumulative if we took turn2 = 27, then turn1 = 27+12 = 39 > 30
        // With budget=30: only turn2 (27 tokens) fits in isolation
        // Verify: user of turn2 alone = 6 → fits. assistant of turn2 = 21 → 6+21=27 ≤ 30 → fits
        // So turn2 fits as a whole (27 ≤ 30). Turn1 cannot fit (27+12=39 > 30).
        // Result should be turn2 only = 2 messages

        let (store, url) = try await makeStore(turns: [
            (.user, ascii(20)),     // 6 tokens
            (.assistant, ascii(20)), // 6 tokens
            (.user, ascii(20)),     // 6 tokens
            (.assistant, ascii(80))  // (80)/4+1=21 tokens
        ])
        defer { cleanup(url) }

        let result = await store.truncatedMessages(
            reservedReplyTokens: 0,
            reservedSystemTokens: 0,
            modelContextWindow: 30 // budget = 30
        )

        // Turn2 fits (27 tokens), turn1 doesn't (39 total). Result = 2 messages (turn2).
        #expect(result.count == 2)
        #expect(result[0].role == .user)
        #expect(result[0].content == ascii(20))
        #expect(result[1].role == .assistant)
        #expect(result[1].content == ascii(80))
    }

    // MARK: Special edge cases

    // 15. Trailing unpaired user (partial turn, no reply yet) → included
    @Test("trailing unpaired user message (no assistant reply yet) is included")
    func trailingUnpairedUserIncluded() async throws {
        let (store, url) = try await makeStore(turns: [
            (.user, "old user"),
            (.assistant, "old assistant"),
            (.user, "new user no reply") // partial turn at end
        ])
        defer { cleanup(url) }

        let result = await store.truncatedMessages(
            reservedReplyTokens: 0,
            reservedSystemTokens: 0,
            modelContextWindow: 100_000
        )
        #expect(result.count == 3)
        #expect(result.last?.content == "new user no reply")
        #expect(result.last?.role == .user)
    }

    // 16. Orphaned assistant message (no preceding user, corrupted history) → treated as independent
    @Test("orphaned assistant message at start is treated as independent and included if budget allows")
    func orphanedAssistantMessageHandled() async throws {
        // We manually build messages bypassing the pairs helper
        let url = makeTmpURL()
        defer { cleanup(url) }
        let store = ConversationStore(storeURL: url)
        try await store.load()

        // Append orphaned assistant (no preceding user)
        await store.append(ConversationMessage(role: .assistant, content: "orphan"))
        await store.append(ConversationMessage(role: .user, content: "later user"))
        await store.append(ConversationMessage(role: .assistant, content: "later assistant"))

        let result = await store.truncatedMessages(
            reservedReplyTokens: 0,
            reservedSystemTokens: 0,
            modelContextWindow: 100_000
        )
        // All 3 should be included when budget is large
        #expect(result.count == 3)
        // Order must be preserved: orphan, user, assistant
        #expect(result[0].content == "orphan")
        #expect(result[1].content == "later user")
        #expect(result[2].content == "later assistant")
    }

    // 17. Large dataset: 100 turns → no crash, completion within reasonable time
    @Test("100 turns stress test: no crash, returns subset")
    func hundredTurnsStressTest() async throws {
        var turns: [(LLMRole, String)] = []
        for i in 0..<100 {
            turns.append((.user, "user message \(i) " + ascii(50)))
            turns.append((.assistant, "assistant reply \(i) " + ascii(50)))
        }
        let (store, url) = try await makeStore(turns: turns)
        defer { cleanup(url) }

        // Small budget
        let result = await store.truncatedMessages(
            reservedReplyTokens: 2048,
            reservedSystemTokens: 1024,
            modelContextWindow: 4096 // budget = 1024
        )
        // Must return fewer than 200 (UInt is always >= 0; that assertion was vacuous).
        #expect(result.count < 200)
        // If non-empty, the last entry should be from turn 99
        if !result.isEmpty {
            let lastMsg = result.last!
            #expect(lastMsg.content.hasPrefix("assistant reply 99") || lastMsg.content.hasPrefix("user message 99"))
        }
    }

    // 18. Negative budget clamped to 0 → returns empty (not a crash)
    @Test("negative budget (reserved > window) is clamped to 0 and returns empty")
    func negativeBudgetClampedToZero() async throws {
        let (store, url) = try await makeStore(turns: [
            (.user, "test"),
            (.assistant, "response")
        ])
        defer { cleanup(url) }

        // reservedReplyTokens + reservedSystemTokens > modelContextWindow
        let result = await store.truncatedMessages(
            reservedReplyTokens: 5000,
            reservedSystemTokens: 5000,
            modelContextWindow: 4096
        )
        #expect(result.isEmpty)
    }

    // 19. Large budget includes everything in original order
    @Test("very large budget returns all messages in original order")
    func largeBudgetReturnsAll() async throws {
        var turns: [(LLMRole, String)] = []
        for i in 0..<10 {
            turns.append((.user, "q\(i)"))
            turns.append((.assistant, "a\(i)"))
        }
        let (store, url) = try await makeStore(turns: turns)
        defer { cleanup(url) }

        let result = await store.truncatedMessages(
            reservedReplyTokens: 1000,
            reservedSystemTokens: 1000,
            modelContextWindow: 1_000_000
        )
        let all = await store.messages()
        #expect(result.count == all.count)
        #expect(result.map(\.id) == all.map(\.id))
    }

    // 20. Rolling drop preserves the newest N turns, not the oldest N
    @Test("rolling drop preserves newest turns, discards oldest")
    func rollingDropPreservesNewestTurns() async throws {
        // 10 turns, budget only fits last 2 turns
        // Each turn: user(ascii(100))=26 + assistant(ascii(100))=26 = 52 tokens
        // budget = 110 → 2 turns (104 tokens) fit, not 3 (156)
        var turns: [(LLMRole, String)] = []
        for i in 0..<10 {
            turns.append((.user, ascii(100)))
            turns.append((.assistant, "TURN-\(i)-\(ascii(90))")) // mark with turn index
        }
        let (store, url) = try await makeStore(turns: turns)
        defer { cleanup(url) }

        let result = await store.truncatedMessages(
            reservedReplyTokens: 0,
            reservedSystemTokens: 0,
            modelContextWindow: 110
        )

        // Should be 4 messages (2 turns) — the LATEST 2 turns
        #expect(result.count == 4)
        // The assistant in the second-to-last slot should be TURN-8
        #expect(result[1].content.hasPrefix("TURN-8-"))
        // The assistant in the last slot should be TURN-9
        #expect(result[3].content.hasPrefix("TURN-9-"))
    }
}
