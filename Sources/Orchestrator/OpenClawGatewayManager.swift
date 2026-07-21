import Foundation
import AgentMode

/// OpenClaw 本地 AI gateway 探测 + daemon 自动拉起 + token/port 自动加载。
///
/// **目标**:用户装了 `openclaw`(npm install -g openclaw / brew install openclaw)
/// 就**零配置**可用 —— App 启动时自动探测 binary、拉起 launchd 管理的 daemon
/// (`ai.openclaw.gateway` service)、读出 token 与 port、并在 chatCompletions
/// endpoint 没 enable 时静默改 `~/.openclaw/openclaw.json` + 重启 daemon。
///
/// 结果通过 `Status` enum 暴露;`.ready(baseURL:token:)` 时上层可以**不让
/// 用户填表**直接拼出 OpenAI 兼容 baseURL 走 `OpenAIProvider`。
///
/// ## 设计要点
///
/// - **autoStart 开关**:`UserDefaults[autoStartKey]` 默认 true。用户在设置
///   关掉 → `bootstrapIfPossible()` 直接返回当前 status,不动 daemon。
/// - **静默写 config 开关**:`UserDefaults[allowEndpointEnableKey]` 默认 true。
///   关掉 → 检测到 endpoint disabled 时**不改 json**,status 报错由设置 UI 展示。
/// - **不主动停 daemon**:daemon 是 launchd service,用户机器其他应用可能也在用,
///   OpenPetAgent 退出**绝不** SIGTERM。仅 `terminate()` 留空对称接口。
/// - **Static parser 纯函数**:`extractPort` / `extractToken` /
///   `extractChatCompletionsEnabled` 不接触 IO,便于单测。
///
/// ## 与 HermesPet `OpenClawGatewayManager` 的差异
///
/// - 这里用 `actor` 而非 `@unchecked Sendable` + NSLock —— Swift 6 项目首选,
///   且 `Process` 本身 Sendable,actor 内 `try proc.run()` /
///   `proc.waitUntilExit()` 安全。
/// - 不发 `NotificationCenter` broadcast —— Orchestrator 通过返回的 `Status`
///   决定是否注入 provider,callback 显式优于全局通知。
/// - binary 探测复用 `CLIAvailability.locate(binary:searchPaths:)` +
///   `CLIProcessEnvironment.augmented()["PATH"]`,与 ACP engine 的探测一致,
///   不再单独写 `which openclaw` 兜底逻辑(扩展 PATH 已
///   覆盖 Homebrew + npm global + 用户 ~/.local/bin)。
public actor OpenClawGatewayManager {

    /// 进程级共享实例(配置在 launchd 层全局唯一,App 内多次调 bootstrap 安全幂等)。
    public static let shared = OpenClawGatewayManager()

    /// UserDefaults key:控制是否在启动时自动探测 + 拉起 daemon。
    /// 缺失 → 视为开启(默认零配置体验)。
    public static let autoStartKey = "openclawGatewayAutoStart"

    /// UserDefaults key:是否允许静默改 `~/.openclaw/openclaw.json` enable
    /// chatCompletions endpoint。缺失 → 视为允许。
    public static let allowEndpointEnableKey = "openclawAllowEndpointEnable"

    /// `~/.openclaw/openclaw.json` 缺失或 gateway.http.port 缺失时的兜底端口。
    /// 跟 OpenClaw 自身默认值保持一致,避免改 json 后我们读到错的 port。
    public static let defaultPort = 18789

    public enum Status: Sendable, Equatable {
        /// 还没跑过 `bootstrapIfPossible()`。
        case unknown
        /// `UserDefaults[autoStartKey] == false` —— 用户主动关掉自动启动。
        case disabledByUser
        /// 系统 PATH(含扩展)找不到 openclaw binary。
        case notInstalled
        /// 找到 binary 但 `~/.openclaw/openclaw.json` 不存在或读不出 token/port。
        /// 用户需手动 `openclaw onboard --install-daemon`。
        case installedNotOnboarded(binaryPath: String)
        /// 一切就绪:baseURL + (可能为 nil 的) Bearer token。
        /// 上层据此构造 `OpenAIProvider(apiKey: token ?? "", endpoint: baseURL/chat/completions)`。
        case ready(baseURL: String, token: String?)
        /// 启动 / 改配置 / 解析过程出错。msg 给 UI 展示。
        case error(String)
    }

    private var _status: Status = .unknown
    public var status: Status { _status }

    /// 测试注入用。生产路径走 nil → 真 `CLIAvailability` + 真 FileManager + 真 Process。
    private let cliAvailabilityFactory: @Sendable () -> CLIAvailability
    private let fileManager: FileManager
    private let userDefaults: UserDefaults

    /// 测试用:注入 fake binary 路径跳过 PATH 探测。生产路径传 nil 走真实 PATH 搜索。
    private let overrideBinaryPath: String?

    /// 测试用:注入 fake openclaw.json 路径。生产路径传 nil 走 `~/.openclaw/openclaw.json`。
    private let overrideConfigPath: String?

    /// 测试用:跳过实际的 `openclaw daemon start` 调用(单测不想 spawn 真子进程)。
    /// 生产传 false。
    private let skipDaemonSpawn: Bool

    public init(
        cliAvailabilityFactory: @escaping @Sendable () -> CLIAvailability = { CLIAvailability() },
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        overrideBinaryPath: String? = nil,
        overrideConfigPath: String? = nil,
        skipDaemonSpawn: Bool = false
    ) {
        self.cliAvailabilityFactory = cliAvailabilityFactory
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.overrideBinaryPath = overrideBinaryPath
        self.overrideConfigPath = overrideConfigPath
        self.skipDaemonSpawn = skipDaemonSpawn
    }

    // MARK: - Public entry

    /// 完整启动流程:autoStart 检查 → 探测 binary → 拉 daemon → 读
    /// `openclaw.json` → 自动 enable chatCompletions(若用户允许)→ 返回 status。
    ///
    /// 调用方:`MinimalAppDelegate.applicationDidFinishLaunching` 起一个 Task 跑一次,
    /// 拿到 `.ready(baseURL:token:)` 后(若用户没自配云 provider)写入 openclaw
    /// **专属槽** `UserDefaults["OpenClawBaseURL"]`/`["OpenClawToken"]` + 设
    /// `["LLMProvider"]="openclaw"`,让 `SoulBackendRegistry` 选中 openclaw entry
    /// → `AppBootstrap.resolveOpenClawProvider` 构造 provider 走 localhost。
    /// 详见 `MinimalAppDelegate.setupOpenClawBootstrap`。
    @discardableResult
    public func bootstrapIfPossible() async -> Status {
        // 1. autoStart 开关
        if let raw = userDefaults.object(forKey: Self.autoStartKey) as? Bool, raw == false {
            _status = .disabledByUser
            return _status
        }

        // 2. 探测 binary(测试可注入 overrideBinaryPath)
        let binary: String
        if let override = overrideBinaryPath {
            binary = override
        } else {
            let cli = cliAvailabilityFactory()
            let augmentedPath = CLIProcessEnvironment.augmented()["PATH"] ?? ""
            let paths = augmentedPath.split(separator: ":").map(String.init)
            guard let found = await cli.locate(binary: "openclaw", searchPaths: paths) else {
                _status = .notInstalled
                return _status
            }
            binary = found
        }

        // 3. 第一次尝试读 config;不存在 → 先尝试拉 daemon 再重读
        let configURL = resolvedConfigURL()
        if !fileManager.fileExists(atPath: configURL.path) {
            await startDaemon(binary: binary)
            // 给 launchd 接管 + 首次 onboard 写盘的 buffer
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !fileManager.fileExists(atPath: configURL.path) {
                _status = .installedNotOnboarded(binaryPath: binary)
                return _status
            }
        }

        // 4. 解析 config
        guard let json = loadJSON(at: configURL) else {
            _status = .error("解析 \(configURL.path) 失败 —— openclaw.json 可能损坏")
            return _status
        }

        let port = Self.extractPort(from: json) ?? Self.defaultPort
        let token = Self.extractToken(from: json)
        let endpointEnabled = Self.extractChatCompletionsEnabled(from: json)

        // 5. chatCompletions endpoint disabled → 静默改 json + 重启 daemon(若用户允许)
        let allowEnable = (userDefaults.object(forKey: Self.allowEndpointEnableKey) as? Bool) ?? true
        if !endpointEnabled, allowEnable {
            let writeOK = enableChatCompletionsEndpoint(at: configURL, currentJSON: json)
            if writeOK {
                await restartDaemon(binary: binary)
                // 给 launchd 重启 service 的时间
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                _status = .error("写入 \(configURL.path) 失败 —— 检查文件权限")
                return _status
            }
        } else if !endpointEnabled {
            // 用户禁止自动改 + endpoint 没开 → 报错让 UI 引导手动
            _status = .error("chatCompletions endpoint 未启用,且自动写入被禁;请手动 `openclaw config enable chatCompletions`")
            return _status
        }

        // OpenClaw 的 OpenAI 兼容 endpoint 实测在 `/v1/chat/completions`(非
        // `/chat/completions` —— 后者 404)。baseURL 带 `/v1`,让上层
        // `LLMConfig.endpoint`(baseURL + "/chat/completions")正好拼出 `/v1/...`。
        let baseURL = "http://localhost:\(port)/v1"
        _status = .ready(baseURL: baseURL, token: token)
        return _status
    }

    /// 对称接口 —— daemon 由 launchd 管,OpenPetAgent 退出**不主动停**它
    /// (用户可能同时跑其他工具用 openclaw)。留空便于将来调用方对接。
    public func terminate() {
        // no-op by design
    }

    // MARK: - Private IO helpers

    private func resolvedConfigURL() -> URL {
        if let override = overrideConfigPath {
            return URL(fileURLWithPath: override)
        }
        let expanded = (("~/.openclaw/openclaw.json") as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private func loadJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func startDaemon(binary: String) async {
        guard !skipDaemonSpawn else { return }
        runOpenClawCommand(binary: binary, args: ["daemon", "start"])
    }

    private func restartDaemon(binary: String) async {
        guard !skipDaemonSpawn else { return }
        runOpenClawCommand(binary: binary, args: ["daemon", "restart"])
    }

    /// 同步 spawn 一次 `openclaw <args>` 子进程,等它退出。
    /// 由于 launchd 接管 daemon,这个调用本身是快的(秒级)。
    private func runOpenClawCommand(binary: String, args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.environment = CLIProcessEnvironment.augmented()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // 静默失败 —— bootstrapIfPossible 会通过后续 health/config 检查识别
        }
    }

    /// 写回 chatCompletions.enabled = true。原子写:先 tmp 再 replace,
    /// 保留 0600 权限(openclaw config 含 token,不能放宽)。
    private func enableChatCompletionsEndpoint(at url: URL, currentJSON: [String: Any]) -> Bool {
        var json = currentJSON
        var gateway = (json["gateway"] as? [String: Any]) ?? [:]
        var http = (gateway["http"] as? [String: Any]) ?? [:]
        var endpoints = (http["endpoints"] as? [String: Any]) ?? [:]
        var chatCompletions = (endpoints["chatCompletions"] as? [String: Any]) ?? [:]
        chatCompletions["enabled"] = true
        endpoints["chatCompletions"] = chatCompletions
        http["endpoints"] = endpoints
        gateway["http"] = http
        json["gateway"] = gateway

        do {
            let updated = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            let tmpURL = url.appendingPathExtension("tmp")
            try updated.write(to: tmpURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            // replaceItemAt 在目标存在时返回新 URL;不存在时抛错。fallback 走 move。
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fileManager.moveItem(at: tmpURL, to: url)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Static JSON parsers (nonisolated, pure — easy to unit test)

    /// 从 openclaw.json root dict 中提取 `gateway.http.port`。缺失 / 类型不对 → nil。
    public static func extractPort(from json: [String: Any]) -> Int? {
        (json["gateway"] as? [String: Any])
            .flatMap { $0["http"] as? [String: Any] }
            .flatMap { $0["port"] as? Int }
    }

    /// 从 openclaw.json 提取 Bearer token。
    ///
    /// OpenClaw 2026.5.28 实际结构(实机实测,非旧版假设):token 在
    /// **`gateway.auth.token`**,不是 root `auth`。
    /// ```json
    /// { "gateway": { "auth": { "mode": "token", "token": "xxx" } } }
    /// ```
    /// 仅在 `mode == "token"` 时返回 token(避免 password mode 误把 hash 当 bearer)。
    public static func extractToken(from json: [String: Any]) -> String? {
        guard let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any] else { return nil }
        let mode = auth["mode"] as? String
        guard mode == "token" else { return nil }
        return auth["token"] as? String
    }

    /// 从 openclaw.json root dict 中提取
    /// `gateway.http.endpoints.chatCompletions.enabled`。缺失任意一层 → false。
    public static func extractChatCompletionsEnabled(from json: [String: Any]) -> Bool {
        let enabled = (json["gateway"] as? [String: Any])
            .flatMap { $0["http"] as? [String: Any] }
            .flatMap { $0["endpoints"] as? [String: Any] }
            .flatMap { $0["chatCompletions"] as? [String: Any] }
            .flatMap { $0["enabled"] as? Bool }
        return enabled ?? false
    }
}
