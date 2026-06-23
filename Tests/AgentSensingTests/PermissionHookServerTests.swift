import Testing
import Foundation
@testable import AgentSensing

/// 集成:起 server(系统分配端口)→ URLSession POST 一个权限请求 → 验回写 JSON。
/// 真 localhost 网络但本地、快、确定。
@Suite("PermissionHookServer — HTTP hook 收发(集成)")
struct PermissionHookServerTests {

    actor PromptBox {
        private(set) var value: PermissionPrompt?
        func set(_ p: PermissionPrompt) { value = p }
    }

    func startServer(
        timeout: TimeInterval = 5,
        onPermission: @escaping PermissionHookServer.OnPermission
    ) async throws -> (PermissionHookServer, UInt16) {
        let server = PermissionHookServer(preferredPort: nil, requestTimeout: timeout, onPermission: onPermission)
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            server.start { cont.resume(with: $0) }
        }
        return (server, port)
    }

    func post(port: UInt16, path: String = "/hooks/permission-request", json: String) async throws -> String {
        let url = try #require(URL(string: "http://localhost:\(port)\(path)"))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(json.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    let permReq = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    @Test("POST 权限请求 → onPermission 收到 prompt + respond(.allow) → 回 allow JSON")
    func allowFlow() async throws {
        let box = PromptBox()
        let (server, port) = try await startServer { prompt, responder in
            Task { await box.set(prompt) }
            responder.respond(.allow)
        }
        defer { server.stop() }
        let body = try await post(port: port, json: permReq)
        #expect(body.contains(#""behavior":"allow""#))
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(await box.value?.toolName == "Bash")
    }

    @Test("respond(.deny) → 回 deny JSON")
    func denyFlow() async throws {
        let (server, port) = try await startServer { _, responder in responder.respond(.deny) }
        defer { server.stop() }
        let body = try await post(port: port, json: permReq)
        #expect(body.contains(#""behavior":"deny""#))
    }

    @Test("onPermission 不回应 → 超时弃权 → 回空 body(官方:2xx 空 body = 无决策)")
    func timeoutAbstains() async throws {
        let (server, port) = try await startServer(timeout: 0.5) { _, _ in /* 故意不 respond */ }
        defer { server.stop() }
        let body = try await post(port: port, json: permReq)
        #expect(body.isEmpty)
    }

    @Test("非权限请求(PreToolUse)→ 立即弃权(空 body)")
    func nonPermissionAbstains() async throws {
        let (server, port) = try await startServer { _, r in r.respond(.allow) }
        defer { server.stop() }
        let body = try await post(port: port, json: #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)
        #expect(body.isEmpty)
    }

    @Test("allow + 答案 → 回写完整 updatedInput(保留 questions + answers key=问题文本,防 H.map)")
    func allowWithQuestionAnswers() async throws {
        let (server, port) = try await startServer { prompt, responder in
            responder.respond(.allow, updatedInputJSON: prompt.answeredInputJSON(answer: "方案A"))
        }
        defer { server.stop() }
        let body = try await post(port: port, json: #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"选哪个?","options":[{"label":"方案A"},{"label":"方案B"}]}]}}"#)
        #expect(body.contains(#""behavior":"allow""#))
        #expect(body.contains("updatedInput"))
        #expect(body.contains("questions"))     // 关键:questions 数组保留(否则客户端 questions.map 碰 undefined → H.map 崩)
        #expect(body.contains("选哪个?"))        // answers key = 问题文本(约定)
        #expect(body.contains("方案A"))
    }

    @Test("respond 只第一次生效(allow 后 deny no-op)")
    func respondOnce() async throws {
        let (server, port) = try await startServer { _, responder in
            responder.respond(.allow)
            responder.respond(.deny)   // 应被忽略
        }
        defer { server.stop() }
        let body = try await post(port: port, json: permReq)
        #expect(body.contains(#""behavior":"allow""#))
    }
}
