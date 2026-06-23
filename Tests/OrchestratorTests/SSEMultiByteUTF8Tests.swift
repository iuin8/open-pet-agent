import Foundation
import Testing
@testable import Orchestrator

/// Regression tests for the SSE UTF-8 decoding bug discovered 2026-05-18.
///
/// Symptom: streaming Chinese / Japanese / Korean replies showed ASCII-range
/// garbage like `"ä½ å¥½"` instead of `"你好"`.
///
/// Root cause: the per-byte `Character(UnicodeScalar(byte))` accumulator
/// silently re-interpreted every UTF-8 byte as a separate Latin-1 codepoint,
/// so a 3-byte CJK character became 3 unrelated characters.
///
/// Fix: accumulate raw bytes (`Data`), split on the SSE `\n\n` byte sequence,
/// and decode each whole event with `String(data:encoding: .utf8)`. Chunk
/// boundaries can now fall anywhere — including mid-codepoint — without
/// breaking the resulting text.
@Suite("OpenAIProvider SSE multi-byte UTF-8 decoding")
struct SSEMultiByteUTF8Tests {

    private func makeByteStream(_ bytes: [UInt8]) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private func makeProvider(bytes: [UInt8], status: Int = 200) -> OpenAIProvider {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return OpenAIProvider(
            apiKey: "test",
            httpStreamClient: { _ in
                (self.makeByteStream(bytes), response)
            }
        )
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await s in stream {
            out.append(s)
        }
        return out
    }

    @Test("CJK delta in a single chunk decodes to correct Chinese characters")
    func chineseSingleChunkDecodes() async throws {
        let event = #"""
        data: {"choices":[{"delta":{"content":"你好"}}]}

        data: [DONE]


        """#
        let provider = makeProvider(bytes: Array(event.utf8))
        let deltas = try await collect(provider.streamChat([]))
        #expect(deltas == ["你好"])
    }

    @Test("CJK delta split across two byte chunks still decodes correctly")
    func chineseSplitAcrossChunksDecodes() async throws {
        let payload = #"data: {"choices":[{"delta":{"content":"你好世界"}}]}"# + "\n\n"
        let bytes = Array(payload.utf8) + Array("data: [DONE]\n\n".utf8)
        // Yield byte-by-byte (worst case: every CJK char split across 3 separate "chunks").
        let provider = makeProvider(bytes: bytes)
        let deltas = try await collect(provider.streamChat([]))
        #expect(deltas == ["你好世界"])
    }

    @Test("Multiple CJK chunks accumulate without mojibake")
    func multipleCJKDeltasAccumulate() async throws {
        let events = #"""
        data: {"choices":[{"delta":{"content":"写一首"}}]}

        data: {"choices":[{"delta":{"content":"五言绝句"}}]}

        data: {"choices":[{"delta":{"content":"献给桌宠"}}]}

        data: [DONE]


        """#
        let provider = makeProvider(bytes: Array(events.utf8))
        let deltas = try await collect(provider.streamChat([]))
        #expect(deltas == ["写一首", "五言绝句", "献给桌宠"])
        #expect(deltas.joined() == "写一首五言绝句献给桌宠")
    }

    @Test("Mixed ASCII + CJK in one delta preserves both")
    func mixedASCIIAndCJK() async throws {
        let event = #"""
        data: {"choices":[{"delta":{"content":"Hello, 世界! 👋"}}]}

        data: [DONE]


        """#
        let provider = makeProvider(bytes: Array(event.utf8))
        let deltas = try await collect(provider.streamChat([]))
        #expect(deltas == ["Hello, 世界! 👋"])
    }

    @Test("Emoji (4-byte UTF-8) decodes correctly")
    func emojiDecodes() async throws {
        // 🎉 = F0 9F 8E 89 (4 bytes UTF-8)
        let event = #"""
        data: {"choices":[{"delta":{"content":"🎉🎊"}}]}

        data: [DONE]


        """#
        let provider = makeProvider(bytes: Array(event.utf8))
        let deltas = try await collect(provider.streamChat([]))
        #expect(deltas == ["🎉🎊"])
    }
}
