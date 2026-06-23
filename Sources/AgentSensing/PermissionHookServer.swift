import Foundation
import Network
import os

/// 回写一个权限请求决策的能力。接线层(App)拿到它,在用户于卡片上选后调 `respond`。
/// 仅第一次调用生效(UI 选择 vs 超时弃权竞争 → 第一个赢),其余 no-op。
public protocol HookResponder: AnyObject, Sendable {
    /// 写回决策。`updatedInputJSON`(仅 allow + AskUserQuestion 用)= **完整** `updatedInput` 的 JSON
    /// (原 `questions` 数组全保留 + `answers` —— 见 `PermissionPrompt.answeredInputJSON`)。
    /// **关键**:必须保留 `questions`,否则客户端渲染 AskUserQuestion 时 `questions.map` 碰 undefined →
    /// `undefined is not an object (evaluating 'H.map')` 崩(早期我们只发 `{answers}` 丢了 questions
    /// 的教训,见 [docs/lessons-learned.md §7.1]);用 `Data` 而非 `[String:Any]` 是为过 Sendable 边界。
    func respond(_ decision: PermissionDecision, updatedInputJSON: Data?)
    /// 连接是否还活着(用户拖太久 / Claude 取消 → 连接断,卡片可自行消失)。
    var isAlive: Bool { get }
}

public extension HookResponder {
    /// 便捷:allow/deny/abstain,无 updatedInput。
    func respond(_ decision: PermissionDecision) { respond(decision, updatedInputJSON: nil) }
}

/// 本地 HTTP server:接 Claude Code `type: "http"` PermissionRequest hook 的 POST,解析成
/// `PermissionPrompt` 交给接线层弹卡片,**保活连接**等用户选,再写回决策;超时 → 弃权(`{}`)。
///
/// 相比基于 `settings.json` 命令 hook + shell 脚本中转的做法,这里用官方 `type: "http"` hook
/// 让 Claude **直接 POST** 到这里,少一层 shell,不落脚本文件。
///
/// 并发:Network.framework 回调队列驱动 → `final class @unchecked Sendable` + 专用串行队列,
/// 所有可变状态只在该队列上碰(不用 actor:actor 与 NWListener 的队列模型相抵)。
public enum HookServerError: Error, Sendable {
    case noPort   // listener ready 却拿不到端口
}

public final class PermissionHookServer: @unchecked Sendable {

    /// 回调在 server **专用串行队列上同步调用** —— 实现禁止在闭包内 `queue.sync` 回 server(死锁),
    /// 也禁止长时间阻塞(会卡住 accept/超时/其它连接);应立即异步派发到主线程。`respond` 可安全调用。
    public typealias OnPermission = @Sendable (PermissionPrompt, any HookResponder) -> Void

    static let log = Logger(subsystem: "io.openpetagent", category: "AgentSensing.hookserver")
    private let queue = DispatchQueue(label: "io.openpetagent.hookserver")
    private let preferredPort: UInt16?       // nil = 系统分配空闲端口(测试用)
    private let portFallbacks: Int
    private let requestTimeout: TimeInterval
    private let onPermission: OnPermission
    /// 并发连接上限,挡本机进程灌满串行队列阻塞真 hook(Claude 实际一次只一个权限请求)。
    private let maxConcurrentConnections = 16

    private var listener: NWListener?
    private var assignedPort: UInt16?
    private var connections: Set<HookConnection> = []   // 强引用保活,防 receive 中被释放

    public init(
        preferredPort: UInt16? = 45831,
        portFallbacks: Int = 9,
        requestTimeout: TimeInterval = 120,
        onPermission: @escaping OnPermission
    ) {
        self.preferredPort = preferredPort
        self.portFallbacks = portFallbacks
        self.requestTimeout = requestTimeout
        self.onPermission = onPermission
    }

    /// 当前监听端口(start 成功后才有)。HookInstaller 用它写 settings.json 的 hook url。
    public var port: UInt16? { queue.sync { assignedPort } }

    /// 起 server。`completion` 在 listener ready(成功,带端口)或全部端口失败时回调一次。
    public func start(completion: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        queue.async { [self] in
            let attempts = preferredPort == nil ? 1 : portFallbacks + 1
            bringUp(port: preferredPort, attemptsLeft: attempts - 1, completion: OneShot(completion))
        }
    }

    public func stop() {
        queue.async { [self] in
            for c in connections { c.close() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
            assignedPort = nil
        }
    }

    // MARK: - 内部(全在 queue 上)

    /// completion 只能 fire 一次的小包装(ready 或失败竞争时防重复回调)。
    /// 安全:`fire()` 只在 `queue` 上调用(bringUp 全路径经 queue.async / queue 上的 handler 进入)。
    private final class OneShot: @unchecked Sendable {
        private var fn: ((Result<UInt16, Error>) -> Void)?
        init(_ fn: @escaping (Result<UInt16, Error>) -> Void) { self.fn = fn }
        func fire(_ r: Result<UInt16, Error>) { let f = fn; fn = nil; f?(r) }
    }

    private func bringUp(port: UInt16?, attemptsLeft: Int, completion: OneShot) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只接 loopback —— 这个端口能弹权限卡片,绝不暴露到 LAN(只 Claude Code 本机 POST)。
        params.requiredInterfaceType = .loopback
        let newListener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: params, on: nwPort)
            } else {
                newListener = try NWListener(using: params)   // 系统分配
            }
        } catch {
            completion.fire(.failure(error))
            return
        }
        // handler 已在 `queue` 上触发(start(queue:)),无需再 queue.async。
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let actual = newListener.port?.rawValue else {
                    // 拿不到端口 = 没法写正确的 settings.json hook url,宁可失败也别写 0。
                    Self.log.error("listener ready 但无端口")
                    completion.fire(.failure(HookServerError.noPort))
                    return
                }
                self.assignedPort = actual
                Self.log.notice("hook server ready @\(actual, privacy: .public)")
                completion.fire(.success(actual))
            case .failed(let err):
                newListener.cancel()
                if attemptsLeft > 0, let p = port {
                    self.bringUp(port: p + 1, attemptsLeft: attemptsLeft - 1, completion: completion)
                } else {
                    Self.log.error("hook server 起不来: \(err.localizedDescription, privacy: .public)")
                    completion.fire(.failure(err))
                }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        guard connections.count < maxConcurrentConnections else {
            Self.log.error("并发连接超 \(self.maxConcurrentConnections, privacy: .public),拒新连接")
            conn.cancel()
            return
        }
        let c = HookConnection(
            connection: conn,
            queue: queue,
            timeout: requestTimeout,
            onPermission: onPermission,
            onClose: { [weak self] closed in
                self?.queue.async { self?.connections.remove(closed) }
            }
        )
        connections.insert(c)
        c.start()
    }
}
