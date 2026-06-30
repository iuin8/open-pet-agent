import Testing
import Foundation
@testable import AgentMode

// ACP transport 纯函数测试(splitLines / parseLine)+ mock transport(client/engine 复用)。

// MARK: - ACPLineParser

@Test("ACPLineParser.splitLines: 按换行切,跨 chunk 拼回半行")
func splitLinesBasic() {
    let data = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}".utf8)   // 末行无换行 = 半行
    let (lines, remainder) = ACPLineParser.splitLines(data)
    #expect(lines.count == 2)
    #expect(remainder == Data("{\"c\":3}".utf8))
}

@Test("ACPLineParser.parseLine: 合法 ACP → inbound;空行/非 JSON → nil")
func parseLineValid() {
    let msg = ACPLineParser.parseLine(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#.utf8))
    if case .notification = msg { } else { Issue.record("应解出 notification") }

    #expect(ACPLineParser.parseLine(Data("\n".utf8)) == nil)
    #expect(ACPLineParser.parseLine(Data("not json".utf8)) == nil)
    #expect(ACPLineParser.parseLine(Data("".utf8)) == nil)
}

// MARK: - MockACPTransport(client/engine 测试用)

/// 内存 mock transport:预置 inbound 队列(按序推给 onInbound),记录 send 的 line。
final class MockACPTransport: ACPTransport, @unchecked Sendable {
    private var queue: [ACPInbound]
    private(set) var sentLines: [String] = []
    private var onInbound: (@Sendable (ACPInbound) -> Void)?
    private var onEOF: (@Sendable () -> Void)?
    private(set) var didShutdown = false
    private let lock = NSLock()

    init(_ inbound: [ACPInbound]) {
        self.queue = inbound
    }

    func send(_ jsonString: String) throws {
        lock.lock()
        sentLines.append(jsonString)
        // send-driven:每次 client send 取「直到下一个 response(含)」的消息组
        // (一个 request → 若干 notification + 一个 response),异步推(给 client
        // 设 pending 的机会,免「response 在 request 前到」的 race —— 原 start 同步
        // 推会被 client pending 前丢弃,被 timeout 暴露)。
        var group: [ACPInbound] = []
        while !queue.isEmpty {
            let msg = queue.removeFirst()
            group.append(msg)
            if case .response = msg { break }
        }
        let onInbound = self.onInbound
        lock.unlock()
        guard let onInbound, !group.isEmpty else { return }
        Task { for msg in group { onInbound(msg) } }
    }

    func start(
        onInbound: @escaping @Sendable (ACPInbound) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) async throws {
        lock.lock(); self.onInbound = onInbound; self.onEOF = onEOF; lock.unlock()
        // 不在 start 推队列 —— 留给 send 触发(见 send),模拟真实 agent request-response。
    }

    /// 测试用:后续再推一条消息(模拟流式 update 后到)。
    func push(_ msg: ACPInbound) {
        onInbound?(msg)
    }

    /// 测试用:模拟 agent 进程 EOF / 异常退出 → 触发 onEOF(client 应唤醒 pending)。
    func simulateEOF() {
        onEOF?()
    }

    func shutdown() {
        lock.lock(); didShutdown = true; lock.unlock()
    }
}
