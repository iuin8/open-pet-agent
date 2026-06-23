import Foundation

/// 一个解析好的 HTTP 请求(只取我们需要的:方法、路径、头、体)。
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]   // header 名小写
    public let body: Data
}

/// 把 NWConnection 累积的原始字节解析成完整 HTTP/1.1 请求。Claude Code 的 `type: http`
/// hook 是一个普通 POST(`Content-Type: application/json`,body = hook JSON),我们自己
/// 解析(无第三方 HTTP server 依赖)。**纯函数、无 I/O → 好无头单测。**
///
/// 请求未收齐(header 没出现 `\r\n\r\n` / body 不足 `Content-Length`)→ 返回 nil,调用方继续读。
public enum HTTPRequestParser {

    /// 单个请求 body 上限(本地权限请求 JSON 绰绰有余)。超出 / 负数 → 拒解析,挡 OOM + 误解析。
    public static let maxBodyBytes = 1_048_576   // 1 MB

    public static func parse(_ data: Data) -> HTTPRequest? {
        let bytes = [UInt8](data)
        guard let bodyStart = indexAfterHeaderTerminator(bytes) else { return nil }  // \r\n\r\n 之后
        let headerBytes = bytes[0..<(bodyStart - 4)]
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let reqParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard reqParts.count >= 2 else { return nil }
        let method = String(reqParts[0])
        let path = String(reqParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        // 负数 = 撒谎头(否则 `count >= 负数` 恒真 → 误把垃圾当空 body);超大 = 喂无限 buffer 的 DoS。
        guard contentLength >= 0, contentLength <= maxBodyBytes else { return nil }
        let bodyBytes = bytes[bodyStart...]
        guard bodyBytes.count >= contentLength else { return nil }   // body 未收齐,继续读
        let body = Data(bodyBytes.prefix(contentLength))
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    /// 找 `\r\n\r\n`,返回其**之后**的字节下标;没找到 → nil。
    private static func indexAfterHeaderTerminator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let cr: UInt8 = 13, lf: UInt8 = 10
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == cr, bytes[i + 1] == lf, bytes[i + 2] == cr, bytes[i + 3] == lf {
                return i + 4
            }
            i += 1
        }
        return nil
    }
}
