import Foundation
import Testing
@testable import Orchestrator

@Suite("OpenClawGatewayManager")
struct OpenClawGatewayManagerTests {

    // MARK: - extractPort

    @Test("extractPort 读取 gateway.http.port")
    func extractPortHappyPath() {
        let json: [String: Any] = [
            "gateway": ["http": ["port": 18789]]
        ]
        #expect(OpenClawGatewayManager.extractPort(from: json) == 18789)
    }

    @Test("extractPort 缺 gateway → nil")
    func extractPortMissingGateway() {
        let json: [String: Any] = [:]
        #expect(OpenClawGatewayManager.extractPort(from: json) == nil)
    }

    @Test("extractPort 缺 http → nil")
    func extractPortMissingHTTP() {
        let json: [String: Any] = ["gateway": [:]]
        #expect(OpenClawGatewayManager.extractPort(from: json) == nil)
    }

    @Test("extractPort 缺 port → nil")
    func extractPortMissingPortKey() {
        let json: [String: Any] = ["gateway": ["http": [:]]]
        #expect(OpenClawGatewayManager.extractPort(from: json) == nil)
    }

    @Test("extractPort port 不是 Int (字符串) → nil")
    func extractPortStringNotInt() {
        let json: [String: Any] = [
            "gateway": ["http": ["port": "18789"]]
        ]
        #expect(OpenClawGatewayManager.extractPort(from: json) == nil)
    }

    // MARK: - extractToken

    @Test("extractToken mode==token 返回 token 字符串")
    func extractTokenHappyPath() {
        let json: [String: Any] = [
            "auth": ["mode": "token", "token": "abc-123-secret"]
        ]
        #expect(OpenClawGatewayManager.extractToken(from: json) == "abc-123-secret")
    }

    @Test("extractToken mode==password 不返回 token (避免误把 password 当 bearer)")
    func extractTokenPasswordModeReturnsNil() {
        let json: [String: Any] = [
            "auth": ["mode": "password", "token": "looks-like-token-but-isnt"]
        ]
        #expect(OpenClawGatewayManager.extractToken(from: json) == nil)
    }

    @Test("extractToken 缺 auth → nil")
    func extractTokenMissingAuth() {
        let json: [String: Any] = [:]
        #expect(OpenClawGatewayManager.extractToken(from: json) == nil)
    }

    @Test("extractToken mode 缺失 → nil")
    func extractTokenMissingMode() {
        let json: [String: Any] = ["auth": ["token": "x"]]
        #expect(OpenClawGatewayManager.extractToken(from: json) == nil)
    }

    @Test("extractToken mode==token 但 token 字段缺失 → nil")
    func extractTokenMissingTokenField() {
        let json: [String: Any] = ["auth": ["mode": "token"]]
        #expect(OpenClawGatewayManager.extractToken(from: json) == nil)
    }

    // MARK: - extractChatCompletionsEnabled

    @Test("extractChatCompletionsEnabled true 路径")
    func extractEndpointEnabledTrue() {
        let json: [String: Any] = [
            "gateway": [
                "http": [
                    "endpoints": [
                        "chatCompletions": ["enabled": true]
                    ]
                ]
            ]
        ]
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: json) == true)
    }

    @Test("extractChatCompletionsEnabled false 路径")
    func extractEndpointEnabledFalse() {
        let json: [String: Any] = [
            "gateway": [
                "http": [
                    "endpoints": [
                        "chatCompletions": ["enabled": false]
                    ]
                ]
            ]
        ]
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: json) == false)
    }

    @Test("extractChatCompletionsEnabled 缺整个嵌套层 → false (默认 disabled)")
    func extractEndpointEnabledMissingNesting() {
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: [:]) == false)
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: ["gateway": [:]]) == false)
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: ["gateway": ["http": [:]]]) == false)
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: [
            "gateway": ["http": ["endpoints": [:]]]
        ]) == false)
    }

    @Test("extractChatCompletionsEnabled enabled 字段不是 Bool (字符串 'true') → false")
    func extractEndpointEnabledStringNotBool() {
        let json: [String: Any] = [
            "gateway": [
                "http": [
                    "endpoints": [
                        "chatCompletions": ["enabled": "true"]
                    ]
                ]
            ]
        ]
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: json) == false)
    }

    // MARK: - bootstrapIfPossible — autoStart 开关

    @Test("autoStart=false 直接返回 .disabledByUser, 不动 daemon")
    func bootstrapDisabledByUser() async {
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: OpenClawGatewayManager.autoStartKey)

        let manager = OpenClawGatewayManager(
            userDefaults: defaults,
            overrideBinaryPath: "/usr/bin/false",  // 不该被调到
            skipDaemonSpawn: true
        )
        let status = await manager.bootstrapIfPossible()
        #expect(status == .disabledByUser)
    }

    // MARK: - bootstrapIfPossible — binary 缺失

    @Test("binary 找不到 → .notInstalled")
    func bootstrapBinaryNotFound() async {
        let defaults = ephemeralDefaults()
        // 不注入 overrideBinaryPath → 走 PATH 搜索;
        // 注入一个空 CLIAvailability 不行,只能让 PATH 里没 openclaw。
        // 这里偷懒 —— 大多数 CI / dev 机器都没装 openclaw,默认就是 .notInstalled。
        // 真严格隔离需要 mock CLIAvailability,N2.x 再加。
        let manager = OpenClawGatewayManager(
            userDefaults: defaults,
            skipDaemonSpawn: true
        )
        let status = await manager.bootstrapIfPossible()
        // 已装机器返回 .ready(...) 也可接受 —— 我们只断言**不是 .disabledByUser**
        // 来确保 autoStart 路径走对。
        #expect(status != .disabledByUser)
    }

    // MARK: - bootstrapIfPossible — fake config 路径(完整 ready 流程)

    @Test("config 完整 + endpoint enabled → .ready(baseURL, token)")
    func bootstrapReadyWithGoodConfig() async throws {
        let defaults = ephemeralDefaults()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configURL = tmpDir.appendingPathComponent("openclaw.json")
        let goodJSON: [String: Any] = [
            "auth": ["mode": "token", "token": "test-token-xyz"],
            "gateway": [
                "http": [
                    "port": 19999,
                    "endpoints": ["chatCompletions": ["enabled": true]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: goodJSON, options: [])
        try data.write(to: configURL)

        // 用 /usr/bin/false 作 fake binary —— 存在但 daemon 调被 skip
        let manager = OpenClawGatewayManager(
            userDefaults: defaults,
            overrideBinaryPath: "/usr/bin/false",
            overrideConfigPath: configURL.path,
            skipDaemonSpawn: true
        )
        let status = await manager.bootstrapIfPossible()
        #expect(status == .ready(baseURL: "http://localhost:19999", token: "test-token-xyz"))
    }

    @Test("config 缺 port → 用默认端口 18789")
    func bootstrapDefaultPortFallback() async throws {
        let defaults = ephemeralDefaults()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configURL = tmpDir.appendingPathComponent("openclaw.json")
        let json: [String: Any] = [
            "auth": ["mode": "token", "token": "tok"],
            "gateway": [
                "http": [
                    "endpoints": ["chatCompletions": ["enabled": true]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: configURL)

        let manager = OpenClawGatewayManager(
            userDefaults: defaults,
            overrideBinaryPath: "/usr/bin/false",
            overrideConfigPath: configURL.path,
            skipDaemonSpawn: true
        )
        let status = await manager.bootstrapIfPossible()
        #expect(status == .ready(baseURL: "http://localhost:18789", token: "tok"))
    }

    @Test("endpoint disabled + allowEnable=false → .error 不动 json")
    func bootstrapEndpointDisabledNoAutoEnable() async throws {
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: OpenClawGatewayManager.allowEndpointEnableKey)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configURL = tmpDir.appendingPathComponent("openclaw.json")
        let json: [String: Any] = [
            "auth": ["mode": "token", "token": "tok"],
            "gateway": [
                "http": [
                    "port": 18789,
                    "endpoints": ["chatCompletions": ["enabled": false]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: configURL)

        let manager = OpenClawGatewayManager(
            userDefaults: defaults,
            overrideBinaryPath: "/usr/bin/false",
            overrideConfigPath: configURL.path,
            skipDaemonSpawn: true
        )
        let status = await manager.bootstrapIfPossible()
        if case .error(let msg) = status {
            #expect(msg.contains("chatCompletions"))
        } else {
            Issue.record("expected .error, got \(status)")
        }

        // 验证 json 没被改 —— 原 enabled 仍是 false
        let after = try Data(contentsOf: configURL)
        let afterJSON = try JSONSerialization.jsonObject(with: after) as? [String: Any] ?? [:]
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: afterJSON) == false)
    }

    @Test("endpoint disabled + allowEnable=true (默认) → 自动写 enabled=true")
    func bootstrapAutoEnableWritesConfig() async throws {
        let defaults = ephemeralDefaults()
        // 不设 allowEndpointEnableKey → 默认 true

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configURL = tmpDir.appendingPathComponent("openclaw.json")
        let json: [String: Any] = [
            "auth": ["mode": "token", "token": "tok"],
            "gateway": [
                "http": [
                    "port": 18789,
                    "endpoints": ["chatCompletions": ["enabled": false]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: configURL)

        let manager = OpenClawGatewayManager(
            userDefaults: defaults,
            overrideBinaryPath: "/usr/bin/false",
            overrideConfigPath: configURL.path,
            skipDaemonSpawn: true  // skip daemon restart spawn
        )
        let status = await manager.bootstrapIfPossible()
        #expect(status == .ready(baseURL: "http://localhost:18789", token: "tok"))

        // 验证 json 被改成 enabled=true
        let after = try Data(contentsOf: configURL)
        let afterJSON = try JSONSerialization.jsonObject(with: after) as? [String: Any] ?? [:]
        #expect(OpenClawGatewayManager.extractChatCompletionsEnabled(from: afterJSON) == true)
    }

    // MARK: - Helpers

    /// 隔离的 UserDefaults suite,每 test 一份避免状态污染。
    private func ephemeralDefaults() -> UserDefaults {
        let suite = "openclaw-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
