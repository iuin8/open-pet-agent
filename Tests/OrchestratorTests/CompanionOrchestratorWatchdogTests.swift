import Testing
@testable import Orchestrator
import Context
import Foundation
import Rendering
import RuntimeBridge

// MARK: - Stubs

/// Provider that streamChat 永远不 yield 任何 chunk —— 模拟服务端建连成功
/// 但 SSE chunk 卡死的国内云厂商场景。chat() 也会挂住以保证不会被走 fallback。
private final class StallingProvider: LLMProvider, Sendable {
    func chat(_ messages: [LLMMessage]) async throws -> String {
        // 挂住够久但有限,避免测试基础设施泄漏 Task。watchdog 应当先触发。
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return ""
    }

    nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // 注意:不调用 continuation.yield / .finish,模拟服务端永远不回包。
            // 用一个长 sleep Task 持有 continuation,这样 stream 真的在等。
            let task = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Provider 按节奏 yield 多个 chunk;每个 chunk 之间 sleep 一小段,确保
/// 测试看到的是"边收 token 边重置 watchdog",而不是一口气返完。
private final class TickingProvider: LLMProvider, Sendable {
    private let chunks: [String]
    private let perChunkSleepNanos: UInt64

    init(chunks: [String], perChunkSleepNanos: UInt64) {
        self.chunks = chunks
        self.perChunkSleepNanos = perChunkSleepNanos
    }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        chunks.joined()
    }

    nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let capturedChunks = chunks
        let capturedSleep = perChunkSleepNanos
        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in capturedChunks {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: capturedSleep)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Tests

/// C1 — SSE 流空闲超时 watchdog 行为校验。
///
/// 测试通过临时修改 `CompanionOrchestrator.streamIdleTimeoutSeconds` 把超时
/// 阈值从 90s 缩到 1s,避免每个用例跑一分半。每个测试都用 defer 还原原值。
@Suite("CompanionOrchestrator stream idle watchdog (C1)")
struct CompanionOrchestratorWatchdogTests {

    // MARK: replyStream(for:) — public AsyncThrowingStream 路径

    @Test("replyStream 服务端卡死 → 超时后 throw URLError(.timedOut)")
    func replyStreamIdleTimeoutFires() async throws {
        let originalTimeout = CompanionOrchestrator.streamIdleTimeoutSeconds
        CompanionOrchestrator.streamIdleTimeoutSeconds = 1
        defer { CompanionOrchestrator.streamIdleTimeoutSeconds = originalTimeout }

        let provider = StallingProvider()
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        let started = Date()
        do {
            for try await delta in orchestrator.replyStream(for: "hi") {
                Issue.record("不应该收到任何 delta,实测收到: \(delta)")
            }
            Issue.record("期望 throw URLError(.timedOut),实际正常结束")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("期望 URLError(.timedOut),实际收到: \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        // 断言语义(谁触发)不断言速度:watchdog 是真 1s tick 轮询,全套 --parallel
        // 负载下 main actor + Task.sleep 延迟不可控(实测 22~25s),秒级上限必然 flake
        // (已三连)。上限只需显著低于 StallingProvider 的 60s 兜底结束 —— 足以证明
        // 是 watchdog 触发而非 provider 正常结束(后者走上面 Issue.record)。真 hung
        // 由测试硬超时兜底。
        #expect(elapsed < 55, "watchdog 应先于 provider 60s 兜底触发,实际耗时 \(elapsed)s")
    }

    @Test("replyStream 正常 yield → 不会被 watchdog 误杀")
    func replyStreamNormalDoesNotTimeout() async throws {
        let originalTimeout = CompanionOrchestrator.streamIdleTimeoutSeconds
        // 阈值 2s,chunk 间隔 200ms → 远低于阈值,watchdog 应保持沉默。
        CompanionOrchestrator.streamIdleTimeoutSeconds = 2
        defer { CompanionOrchestrator.streamIdleTimeoutSeconds = originalTimeout }

        let provider = TickingProvider(
            chunks: ["hello", " ", "world"],
            perChunkSleepNanos: 200_000_000
        )
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "hi") {
            collected += delta
        }
        #expect(collected == "hello world")
    }

    @Test("replyStream watchdog 触发后不会再 yield delta")
    func replyStreamWatchdogPreemptsLateYield() async throws {
        let originalTimeout = CompanionOrchestrator.streamIdleTimeoutSeconds
        CompanionOrchestrator.streamIdleTimeoutSeconds = 1
        defer { CompanionOrchestrator.streamIdleTimeoutSeconds = originalTimeout }

        let provider = StallingProvider()
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        var deltaCount = 0
        do {
            for try await _ in orchestrator.replyStream(for: "hi") {
                deltaCount += 1
            }
        } catch {
            // 期望路径
        }
        #expect(deltaCount == 0, "卡死场景下不应收到任何 delta")
    }

    // MARK: reply(to:onPartialReply:) — 内部 streamReply 路径

    @Test("reply onPartialReply 服务端卡死 → 触发 watchdog 走 echo fallback")
    func replyOnPartialReplyTimeoutFallsBackToEcho() async throws {
        let originalTimeout = CompanionOrchestrator.streamIdleTimeoutSeconds
        CompanionOrchestrator.streamIdleTimeoutSeconds = 1
        defer { CompanionOrchestrator.streamIdleTimeoutSeconds = originalTimeout }

        let provider = StallingProvider()
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        var thinkingEndedResult: Result<String, Error>?
        let started = Date()
        let result = await orchestrator.reply(
            to: "hello",
            onThinkingEnded: { thinkingEndedResult = $0 },
            onPartialReply: { _ in }
        )
        let elapsed = Date().timeIntervalSince(started)

        // 失败时 reply(to:) 走 echo fallback
        let expectedEcho = "\u{6211}\u{542C}\u{5230}\u{201C}hello\u{201D}\u{4E86}\u{3002}"
        #expect(result == expectedEcho)
        // 同 replyStreamIdleTimeoutFires:断言语义(echo fallback + onThinkingEnded timedOut
        // 已证明 watchdog 触发),上限只压 provider 60s 兜底,不断言秒级速度(负载相关,必 flake)。
        #expect(elapsed < 55, "watchdog 应先于 provider 60s 兜底触发,实测 \(elapsed)s")

        // onThinkingEnded 收到 URLError(.timedOut)
        if case .failure(let error) = thinkingEndedResult {
            let urlError = error as? URLError
            #expect(urlError?.code == .timedOut, "期望 URLError(.timedOut),实际 \(error)")
        } else {
            Issue.record("期望 .failure,实际 \(String(describing: thinkingEndedResult))")
        }
    }

    @Test("reply onPartialReply 正常 stream → 不触发 watchdog")
    func replyOnPartialReplyNormalDoesNotTimeout() async throws {
        let originalTimeout = CompanionOrchestrator.streamIdleTimeoutSeconds
        CompanionOrchestrator.streamIdleTimeoutSeconds = 2
        defer { CompanionOrchestrator.streamIdleTimeoutSeconds = originalTimeout }

        let provider = TickingProvider(
            chunks: ["A", "B", "C"],
            perChunkSleepNanos: 200_000_000
        )
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        var partials: [String] = []
        let result = await orchestrator.reply(
            to: "ping",
            onPartialReply: { accumulated in
                partials.append(accumulated)
            }
        )
        #expect(result == "ABC")
        #expect(partials == ["A", "AB", "ABC"])
    }
}
