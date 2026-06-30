import Foundation

// ACP transport 层:spawn ACP agent 子进程(`opencode acp` / `gemini --acp` / ...)
// 经 stdio JSON-RPC 通信。protocol 抽象便于测试注入 mock。
//
// 复用仓内基建(同 ClaudeCodeEngine):CLIAvailability.locate / CLIProcessEnvironment
// .augmented / SubprocessRegistry(app 退出统一收口)/ readabilityHandler 按行读。
//
// 生命周期:ACP 是**长连接**(client 跨多 turn 用同一 agent 子进程),不同于
// ClaudeCodeEngine 的「单 prompt 子进程退出」。transport 起 agent 进程一次,client
// 反复 send/recv;shutdown() 才 SIGTERM。
//
// 健壮性(ACP-1a 审查 follow-up):
// - readabilityHandler 的 `availableData` 空 = EOF → 置 nil 停 dispatch source(否则高频
//   回调烧 ~200% CPU,有同类判例)+ onEOF 通知 client。
// - terminationHandler:进程异常退出(非 shutdown 触发)→ onEOF(client 唤醒 pending)。
// - start() 的 `CLIAvailability.locate`(actor await)在锁外,免锁跨 await 阻塞读线程。
// - send 检查 process.isRunning,死则抛(免 broken pipe 异常)。

/// ACP 消息 transport。`send` 写 agent stdin;`start(onInbound:onEOF:)` 把收到的消息
/// 经 `onInbound` 推给上层,EOF/进程死时调 `onEOF`(client 据此唤醒 pending continuation)。
public protocol ACPTransport: Sendable {
    /// 写一行 JSON(JSON-RPC request/notification)到 agent stdin。本方法追加换行。
    /// 进程已退出 → 抛 `AgentEngineError.subprocessFailed`。
    func send(_ jsonString: String) throws
    /// spawn 子进程(若 stdio 实现)+ 开始读 stdout。每收到一条 `ACPInbound` 调 `onInbound`;
    /// stdout EOF 或进程异常退出时调 `onEOF`(client 唤醒 pending 免永挂)。回调在后台线程。
    func start(
        onInbound: @escaping @Sendable (ACPInbound) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) async throws
    /// SIGTERM 子进程 + cleanup(主动关闭,不触发 onEOF)。
    func shutdown()
}

// MARK: - 行切 + 解码(纯函数,可单测)

public enum ACPLineParser {
    /// 把累积的 stdout `Data` 按 `\n` 切成「完整行」+「剩余半行」。
    public static func splitLines(_ data: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var buf = data
        let nl: UInt8 = 0x0A
        while let idx = buf.firstIndex(of: nl) {
            lines.append(buf.subdata(in: buf.startIndex..<idx))
            buf.removeSubrange(buf.startIndex...idx)
        }
        return (lines, buf)
    }

    /// 把一行 `Data` 解码为 `ACPInbound`。空行 / 非 JSON / 非 ACP 消息 → nil(跳过,不崩)。
    public static func parseLine(_ data: Data) -> ACPInbound? {
        let trimmed = data.filter { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(ACPInbound.self, from: data)
    }
}

// MARK: - ACPStdioTransport(spawn agent 子进程 + stdio JSON-RPC)

/// stdio transport:spawn agent 命令,stdin 写 JSON 行,stdout 按行收 → `ACPInbound` 回调。
public final class ACPStdioTransport: ACPTransport, @unchecked Sendable {
    /// agent 启动命令,如 ["opencode","acp"] / ["gemini","--acp"]。
    public let command: [String]
    public let binaryPath: String?
    public let processEnvironment: [String: String]?
    public let currentDirectoryURL: URL?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stdoutBuffer = Data()
    private let lock = NSLock()
    private var didStart = false
    /// 主动 shutdown 置 true → terminationHandler 跳过 onEOF(免重复通知)。
    private var didShutdown = false

    public init(
        command: [String],
        binaryPath: String? = nil,
        processEnvironment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) {
        self.command = command
        self.binaryPath = binaryPath
        self.processEnvironment = processEnvironment
        self.currentDirectoryURL = currentDirectoryURL
    }

    public func send(_ jsonString: String) throws {
        lock.lock(); let pipe = stdinPipe; let proc = process; lock.unlock()
        guard let pipe else {
            throw AgentEngineError.cliNotInstalled(.openCode)   // 未 start
        }
        // 进程已退出 → 直接抛(免写 broken pipe 抛底层 POSIXError)
        if let proc, !proc.isRunning {
            throw AgentEngineError.subprocessFailed(
                exitCode: proc.terminationStatus, stderr: "agent 进程已退出")
        }
        var data = jsonString.data(using: .utf8) ?? Data()
        data.append(0x0A)   // JSON-RPC over stdio:行帧,换行结尾
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func start(
        onInbound: @escaping @Sendable (ACPInbound) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) async throws {
        // 1. 定位 binary —— **锁外** await(actor 调用,不持锁免阻塞读线程)
        let binary: String
        if let binaryPath {
            binary = binaryPath
        } else {
            let cli = CLIAvailability()
            binary = await cli.locate(binary: command[0]) ?? command[0]
        }

        // 2. 锁内只检查 didStart(不跨 await)
        lock.lock()
        guard !didStart else { lock.unlock(); return }
        didStart = true
        lock.unlock()

        // 3. 锁外配置 Process + Pipe + run(不持锁)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = Array(command.dropFirst())
        proc.environment = processEnvironment ?? CLIProcessEnvironment.augmented()
        if let currentDirectoryURL {
            proc.currentDirectoryURL = currentDirectoryURL
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // stderr 不读

        // 4. 按行读 stdout → onInbound;EOF(availableData 空)→ 置 nil 停回调 + onEOF
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF:对端关 stdout。置 nil 停 dispatch source(否则高频回调烧 CPU)。
                handle.readabilityHandler = nil
                onEOF()
                return
            }
            // 按行切(跨 chunk 累积,免半行)—— 锁只保护 buffer
            self.lock.lock()
            self.stdoutBuffer.append(chunk)
            let (lines, remainder) = ACPLineParser.splitLines(self.stdoutBuffer)
            self.stdoutBuffer = remainder
            self.lock.unlock()
            for line in lines {
                if let msg = ACPLineParser.parseLine(line) {
                    onInbound(msg)
                }
            }
        }

        // 5. 进程退出 → unregister + (若非主动 shutdown)onEOF 通知 client 唤醒 pending
        proc.terminationHandler = { proc in
            Task { await SubprocessRegistry.shared.unregister(proc) }
            let isShutdown = self.lockedRead(\.didShutdown)
            if !isShutdown {
                onEOF()   // 异常退出(崩溃 / 被 OS 杀)→ client 收 EOF 唤醒 pending
            }
        }

        do {
            try proc.run()
        } catch {
            lock.lock(); didStart = false; lock.unlock()
            throw AgentEngineError.subprocessFailed(exitCode: -1, stderr: error.localizedDescription)
        }
        lock.lock()
        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        lock.unlock()
        Task { await SubprocessRegistry.shared.register(proc) }
    }

    public func shutdown() {
        lock.lock()
        didShutdown = true   // 标记主动关闭 → terminationHandler 跳过 onEOF
        let proc = process
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
        Task { [proc] in
            if let proc { await SubprocessRegistry.shared.unregister(proc) }
        }
    }

    /// 锁内读属性(helper,terminationHandler 后台线程安全访问)。
    @inline(__always)
    private func lockedRead<T>(_ key: (ACPStdioTransport) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return key(self)
    }
}
