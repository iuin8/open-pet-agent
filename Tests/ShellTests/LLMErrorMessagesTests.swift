import Foundation
import Testing
@testable import Shell

@Suite("LLMErrorMessages — Markdown 友好文案映射")
struct LLMErrorMessagesTests {

    @Test("providerNotConfigured 文案包含 ⚠️ + 设置入口指引")
    func providerNotConfiguredContent() {
        let msg = LLMErrorMessages.providerNotConfigured
        #expect(msg.contains("⚠️"))
        #expect(msg.contains("设置"))
        // Markdown 加粗标记 — BondedMarkdownBubble 渲染时会变粗
        #expect(msg.contains("**"))
    }

    @Test("URLError.notConnectedToInternet → '没有网络'")
    func friendlyNotConnected() {
        let error = URLError(.notConnectedToInternet)
        let msg = LLMErrorMessages.friendly(for: error)
        #expect(msg.contains("⚠️"))
        #expect(msg.contains("没有网络"))
    }

    @Test("URLError.timedOut → '请求超时'")
    func friendlyTimedOut() {
        let error = URLError(.timedOut)
        let msg = LLMErrorMessages.friendly(for: error)
        #expect(msg.contains("超时"))
    }

    @Test("URLError.cannotFindHost → '连不上 AI 服务器' + baseURL 提示")
    func friendlyCannotFindHost() {
        let error = URLError(.cannotFindHost)
        let msg = LLMErrorMessages.friendly(for: error)
        #expect(msg.contains("连不上"))
        #expect(msg.contains("baseURL"))
    }

    @Test("URLError.userAuthenticationRequired → 'API key' 错了提示")
    func friendlyAuth() {
        let error = URLError(.userAuthenticationRequired)
        let msg = LLMErrorMessages.friendly(for: error)
        #expect(msg.contains("认证"))
        #expect(msg.contains("API key"))
    }

    @Test("URLError.cancelled → '请求已取消'(简短无 fallback)")
    func friendlyCancelled() {
        let error = URLError(.cancelled)
        let msg = LLMErrorMessages.friendly(for: error)
        #expect(msg.contains("取消"))
    }

    @Test("未知 URLError → 兜底文案含 localizedDescription + code")
    func friendlyUnknownURLError() {
        let error = URLError(.dataNotAllowed)
        let msg = LLMErrorMessages.friendly(for: error)
        #expect(msg.contains("⚠️"))
        // 兜底显示 URLError code 数字让用户能搜
        #expect(msg.contains(String(URLError.Code.dataNotAllowed.rawValue)))
    }

    @Test("非 URLError 错误 → 兜底 fallback 含 localizedDescription")
    func friendlyGenericError() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "炸了" }
        }
        let msg = LLMErrorMessages.friendly(for: Boom())
        #expect(msg.contains("⚠️"))
        #expect(msg.contains("回复失败"))
        #expect(msg.contains("炸了"))
    }
}
