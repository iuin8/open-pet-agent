import Foundation
import Network
import os

/// 一条进来的 HTTP 连接的生命周期:累积读 → 解析完整请求 → 路由 → 保活等回写 → 关闭。
/// 实现 `HookResponder`(respond 一次写回 + 关闭)。
///
/// `@unchecked Sendable`:`buffer`/`routed` 只在 server 串行队列上碰(连接以该队列启动,所有
/// NWConnection 回调都在其上);`responded` 跨线程(UI 选 vs 超时弃权)→ `NSLock` 守。
final class HookConnection: HookResponder, Hashable, @unchecked Sendable {

    private static let log = Logger(subsystem: "io.openpetagent", category: "AgentSensing.hookconn")
    /// 整个请求(头 + 体)累积上限,挡本机进程用撒谎/不终结的请求把 buffer 撑到 OOM。
    private static let maxRequestBytes = HTTPRequestParser.maxBodyBytes + 65_536   // body 上限 + 头余量

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let onPermission: PermissionHookServer.OnPermission
    private let onClose: @Sendable (HookConnection) -> Void

    private var buffer = Data()
    private var routed = false
    private let respondLock = NSLock()
    private var responded = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        timeout: TimeInterval,
        onPermission: @escaping PermissionHookServer.OnPermission,
        onClose: @escaping @Sendable (HookConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.timeout = timeout
        self.onPermission = onPermission
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.onClose(self)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        connection.cancel()
    }

    // MARK: - 读 + 路由(全在 queue 上)

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if self.routed { return }
            // 上限熔断:撒谎/不终结的请求别把 buffer 撑到 OOM。
            if self.buffer.count > Self.maxRequestBytes {
                Self.log.error("请求超 \(Self.maxRequestBytes, privacy: .public)B,弃权断开")
                self.respond(.abstain)
                return
            }
            if let request = HTTPRequestParser.parse(self.buffer) {
                self.route(request)
            } else if let error {
                Self.log.warning("receive 出错,弃权: \(error.localizedDescription, privacy: .public)")
                self.respond(.abstain)
            } else if isComplete {
                self.respond(.abstain)          // 连接正常断开但请求没收齐 → 弃权收尾(EOF,非错误)
            } else {
                self.receive()                  // 继续读(body > 64KB 会多次进来)
            }
        }
    }

    private func route(_ request: HTTPRequest) {
        routed = true
        guard request.method == "POST",
              let prompt = PermissionPrompt.parse(jsonText: String(decoding: request.body, as: UTF8.self))
        else {
            respond(.abstain)                   // 非权限请求 → 弃权,交还正常流程 / 其它 hook 工具
            return
        }
        // 超时兜底:用户拖太久没选 → 弃权,别久阻塞 Claude(once-guard 让它无害)。
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.respond(.abstain) }
        onPermission(prompt, self)
    }

    // MARK: - HookResponder

    var isAlive: Bool {
        switch connection.state {
        case .ready, .preparing, .setup: return true
        default: return false
        }
    }

    func respond(_ decision: PermissionDecision, updatedInputJSON: Data?) {
        respondLock.lock()
        if responded { respondLock.unlock(); return }
        responded = true
        respondLock.unlock()

        // allow + AskUserQuestion 答案:完整 updatedInput JSON(含 questions + answers,App 端构造)解回字典。
        var updatedInput: [String: Any]?
        if decision == .allow, let updatedInputJSON,
           let obj = try? JSONSerialization.jsonObject(with: updatedInputJSON) as? [String: Any] {
            updatedInput = obj
        }
        let body = PermissionResponse.httpBody(decision, updatedInput: updatedInput)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + body
        connection.send(content: response, completion: .contentProcessed { [weak self] sendError in
            if let sendError {
                Self.log.warning("决策写回失败(Claude 可能已断): \(sendError.localizedDescription, privacy: .public)")
            }
            self?.connection.cancel()
        })
    }

    // MARK: - Hashable(供 server 用 Set 保活)

    static func == (lhs: HookConnection, rhs: HookConnection) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
