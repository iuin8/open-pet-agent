import Foundation

// ACP transport 层:spawn ACP agent 子进程(`opencode acp` / `gemini --acp` / ...)
// 经 stdio JSON-RPC 通信。protocol 抽象便于测试注入 mock。
//
// 复用仓内基建(同 ClaudeCodeEngine):CLIAvailability.locate / CLIProcessEnvironment
// .augmented / SubprocessRegistry(app 退出统一收口)/ readabilityHandler 按行读。
//
// 生命周期:ACP 是**长连接**(client 跨多 turn 用同一 agent 子进程),不同于
// ClaudeCodeEngine 的「单 prompt 子进程退出」。transport 起 agent 进程一次,client
// 反复 send/recv;shutdown() 才 SIGTERM。idle/总超时由上层(client/engine)管,transport
// 只管 IO + 进程生命周期 + 经 callback 推 inbound(被动管道,client 主动路由)。

/// ACP 消息 transport。`send` 写 agent stdin;`start(onInbound:)` 把收到的消息
/// 经 callback 推给上层(client 按需路由:response 按 id 配对 / notification 分发)。
public protocol ACPTransport: Sendable {
    /// 写一行 JSON(JSON-RPC request/notification)到 agent stdin。本方法追加换行。
    func send(_ jsonString: String) throws
    /// spawn 子进程(若 stdio 实现)+ 开始读 stdout,每收到一条 `ACPInbound` 调 `onInbound`。
    /// `onInbound` 在后台线程(readabilityHandler)回调,须线程安全。
    func start(onInbound: @escaping @Sendable (ACPInbound) -> Void) async throws
    /// SIGTERM 子进程 + cleanup。
    func shutdown()
}

// MARK: - 行切 + 解码(纯函数,可单测)

public enum ACPLineParser {
    /// 把累积的 stdout `Data` 按 `\n` 切成「完整行」+「剩余半行」。
    /// 返回 (完整行数据数组[不含换行], 剩余未结束的 bytes)。
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
    /// 可注入的 binary 绝对路径(nil = `CLIAvailability.locate` 找 command[0])。
    public let binaryPath: String?
    /// 环境变量(nil = `CLIProcessEnvironment.augmented`)。
    public let processEnvironment: [String: String]?
    /// 工作目录(nil = 进程当前 cwd)。
    public let currentDirectoryURL: URL?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stdoutBuffer = Data()
    private let lock = NSLock()
    private var didStart = false

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
        lock.lock(); let pipe = stdinPipe; lock.unlock()
        guard let pipe else {
            throw AgentEngineError.cliNotInstalled(.openCode)   // 未 start
        }
        var data = jsonString.data(using: .utf8) ?? Data()
        data.append(0x0A)   // JSON-RPC over stdio:行帧,换行结尾
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func start(onInbound: @escaping @Sendable (ACPInbound) -> Void) async throws {
        lock.lock(); defer { lock.unlock() }
        guard !didStart else { return }
        didStart = true

        // 1. 定位 binary
        let binary: String
        if let binaryPath {
            binary = binaryPath
        } else {
            let cli = CLIAvailability()
            binary = await cli.locate(binary: command[0]) ?? command[0]
        }

        // 2. Process 配置
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
        proc.standardError = Pipe()   // stderr 不读(agent 日志,异常时拼错误即可)

        // 3. 按行读 stdout → 解 ACPInbound → onInbound 回调
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // 按行切(跨 chunk 累积,免半行)
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

        try proc.run()
        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        Task { await SubprocessRegistry.shared.register(proc) }
    }

    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        Task { [proc = process] in
            if let proc { await SubprocessRegistry.shared.unregister(proc) }
        }
    }
}
