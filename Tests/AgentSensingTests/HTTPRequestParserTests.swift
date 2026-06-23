import Testing
import Foundation
@testable import AgentSensing

@Suite("HTTPRequestParser — 原始字节 → HTTP 请求")
struct HTTPRequestParserTests {

    func raw(_ method: String, _ path: String, body: String, contentLength: Int? = nil) -> Data {
        let len = contentLength ?? body.utf8.count
        let s = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(len)\r\n\r\n\(body)"
        return Data(s.utf8)
    }

    @Test("完整 POST → 解析出方法/路径/头/体")
    func completePost() {
        let r = HTTPRequestParser.parse(raw("POST", "/hooks/permission-request", body: #"{"a":1}"#))
        #expect(r?.method == "POST")
        #expect(r?.path == "/hooks/permission-request")
        #expect(r?.headers["content-type"] == "application/json")
        #expect(r.map { String(decoding: $0.body, as: UTF8.self) } == #"{"a":1}"#)
    }

    @Test("header 未收齐(无 \\r\\n\\r\\n)→ nil")
    func incompleteHeaders() {
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nHost: l".utf8)) == nil)
    }

    @Test("body 不足 Content-Length → nil(继续读)")
    func incompleteBody() {
        // 声明 Content-Length: 20 但只给了 6 字节 body。
        #expect(HTTPRequestParser.parse(raw("POST", "/x", body: #"{"a":1}"#, contentLength: 20)) == nil)
    }

    @Test("GET 无 body → 解析成功,body 空")
    func getNoBody() {
        let s = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let r = HTTPRequestParser.parse(Data(s.utf8))
        #expect(r?.method == "GET")
        #expect(r?.path == "/health")
        #expect(r?.body.isEmpty == true)
    }

    @Test("body 超过 Content-Length(粘包)→ 只取 Content-Length 长度")
    func extraBytesTruncated() {
        let r = HTTPRequestParser.parse(raw("POST", "/x", body: #"{"a":1}EXTRA"#, contentLength: 7))
        #expect(r.map { String(decoding: $0.body, as: UTF8.self) } == #"{"a":1}"#)
    }

    @Test("header 名大小写不敏感(归一化小写)")
    func headerCaseInsensitive() {
        let s = "POST /x HTTP/1.1\r\nCONTENT-LENGTH: 2\r\nX-Foo: Bar\r\n\r\n{}"
        let r = HTTPRequestParser.parse(Data(s.utf8))
        #expect(r?.headers["content-length"] == "2")
        #expect(r?.headers["x-foo"] == "Bar")
    }

    @Test("非 HTTP 垃圾字节 → nil")
    func garbage() {
        #expect(HTTPRequestParser.parse(Data("garbage no crlf".utf8)) == nil)
    }

    @Test("负 Content-Length → nil(防误把垃圾当空 body)")
    func negativeContentLength() {
        let s = "POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\nABC"
        #expect(HTTPRequestParser.parse(Data(s.utf8)) == nil)
    }

    @Test("超大 Content-Length(> maxBodyBytes)→ nil(防喂无限 buffer)")
    func oversizedContentLength() {
        let s = "POST /x HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n{}"
        #expect(HTTPRequestParser.parse(Data(s.utf8)) == nil)
    }

    @Test("Content-Length 正好 maxBodyBytes 边界内 → 收齐才解析")
    func atBoundary() {
        // 声明 = 上限,但 body 没给够 → nil(继续读,不是拒绝)
        let s = "POST /x HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maxBodyBytes)\r\n\r\n{}"
        #expect(HTTPRequestParser.parse(Data(s.utf8)) == nil)
    }
}
