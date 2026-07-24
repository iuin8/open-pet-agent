import Foundation
import Testing
@testable import Orchestrator

// LLMProviderError 的 LocalizedError 描述单测:卡片/气泡/日志共用这份文案 ——
// 按状态码给行动指引(401/403 换 key、429 降频、400 查模型名),服务商错误体摘录有界。

@Suite("LLMProviderError 用户可读描述(LocalizedError)")
struct LLMProviderErrorDescriptionTests {

    @Test("missingAPIKey → 指引去设置填 key")
    func missingKey() {
        let d = LLMProviderError.missingAPIKey.errorDescription ?? ""
        #expect(d.contains("API key"))
        #expect(d.contains("设置"))
    }

    @Test("httpError 401 → key 无效 + 状态码 + 服务商信息摘录")
    func http401() {
        let body = "{\"error\":{\"message\":\"Incorrect API key provided\"}}"
        let d = LLMProviderError.httpError(status: 401, body: body).errorDescription ?? ""
        #expect(d.contains("401"))
        #expect(d.contains("API key 无效"))
        #expect(d.contains("Incorrect API key"))
    }

    @Test("httpError 429 → 限流/额度指引;空体不留噪音")
    func http429() {
        let d = LLMProviderError.httpError(status: 429, body: "").errorDescription ?? ""
        #expect(d.contains("429"))
        #expect(d.contains("额度") || d.contains("频繁"))
        #expect(!d.contains("服务商信息"))
    }

    @Test("httpError 400 → 提示查模型名 + 体摘录")
    func http400() {
        let d = LLMProviderError.httpError(status: 400, body: "Invalid model").errorDescription ?? ""
        #expect(d.contains("400"))
        #expect(d.contains("模型名"))
        #expect(d.contains("Invalid model"))
    }

    @Test("httpError 5xx → 服务端错误稍后重试")
    func http503() {
        let d = LLMProviderError.httpError(status: 503, body: "").errorDescription ?? ""
        #expect(d.contains("503"))
        #expect(d.contains("服务端"))
    }

    @Test("httpError 其他状态码 → 通用服务错误")
    func httpOther() {
        let d = LLMProviderError.httpError(status: 418, body: "").errorDescription ?? ""
        #expect(d.contains("418"))
    }

    @Test("transportError → 网络失败 + 原始信息")
    func transport() {
        let d = LLMProviderError.transportError("连接被重置").errorDescription ?? ""
        #expect(d.contains("网络"))
        #expect(d.contains("连接被重置"))
    }

    @Test("decodingFailed / emptyResponse → 可读文案")
    func decodeAndEmpty() {
        #expect((LLMProviderError.decodingFailed("x").errorDescription ?? "").contains("解析"))
        #expect((LLMProviderError.emptyResponse.errorDescription ?? "").contains("空内容"))
    }

    @Test("NSError 桥接:localizedDescription 走 errorDescription(不再是「错误0」)")
    func nserrorBridging() {
        let e = LLMProviderError.httpError(status: 401, body: "bad key") as NSError
        #expect(e.localizedDescription.contains("API key 无效"))
    }

    @Test("错误体摘录:跳过前导空行取首个非空行;超 120 字符截断")
    func detailSnippet() {
        let multi = LLMProviderError.httpError(status: 500, body: "\nfirst\nsecond").errorDescription ?? ""
        #expect(multi.contains("first"))
        #expect(!multi.contains("second"))

        let long = String(repeating: "x", count: 200)
        let clipped = LLMProviderError.httpError(status: 500, body: long).errorDescription ?? ""
        #expect(clipped.contains("…"))
        #expect(clipped.count < 200)
    }
}
