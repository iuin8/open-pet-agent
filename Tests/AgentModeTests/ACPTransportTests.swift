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
    private let lock = NSLock()

    init(_ inbound: [ACPInbound]) {
        self.queue = inbound
    }

    func send(_ jsonString: String) throws {
        lock.lock(); sentLines.append(jsonString); lock.unlock()
    }

    func start(onInbound: @escaping @Sendable (ACPInbound) -> Void) async throws {
        lock.lock(); self.onInbound = onInbound; let snap = queue; queue = []; lock.unlock()
        // 模拟 agent 依次回消息(立即,主线程同步)
        for msg in snap {
            onInbound(msg)
        }
    }

    /// 测试用:后续再推一条消息(模拟流式 update 后到)。
    func push(_ msg: ACPInbound) {
        onInbound?(msg)
    }

    func shutdown() {}
}
