import Foundation
import Testing
@testable import Weather

@Suite("OpenMeteoService")
struct OpenMeteoServiceTests {
    // MARK: - URL 构造

    @Test("buildURL 含全部必需 query items + 正确 host")
    func buildURLContainsAllParams() {
        let url = OpenMeteoService.buildURL(for: .beijing)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })

        #expect(comps.host == "api.open-meteo.com")
        #expect(comps.path == "/v1/forecast")
        #expect(items["latitude"] == "39.9042")
        #expect(items["longitude"] == "116.4074")
        #expect(items["wind_speed_unit"] == "ms")
        #expect(items["current"]?.contains("temperature_2m") == true)
        #expect(items["current"]?.contains("wind_speed_10m") == true)
        #expect(items["current"]?.contains("wind_direction_10m") == true)
        #expect(items["current"]?.contains("weather_code") == true)
    }

    // MARK: - JSON 解析

    @Test("Response 解析: 标准 payload 还原 temperature / wind / direction / condition")
    func decodeStandardPayload() throws {
        let json = """
        {
          "current": {
            "time": "2026-05-23T15:00",
            "temperature_2m": 12.5,
            "wind_speed_10m": 3.8,
            "wind_direction_10m": 270,
            "weather_code": 3
          }
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(OpenMeteoResponse.self, from: json)
        let snap = payload.current.toSnapshot()

        #expect(snap.temperature == 12.5)
        #expect(snap.windSpeed == 3.8)
        #expect(snap.windDirection == 270)
        #expect(snap.condition == .cloudy)  // WMO 3 = 多云
    }

    // MARK: - WMO 代码映射

    @Test("WMO 0 → sunny")
    func mapWMOSunny() {
        #expect(OpenMeteoResponse.Current.mapWMO(code: 0) == .sunny)
    }

    @Test("WMO 1/2/3 → cloudy")
    func mapWMOCloudy() {
        for code in [1, 2, 3, 45, 48] {
            #expect(OpenMeteoResponse.Current.mapWMO(code: code) == .cloudy)
        }
    }

    @Test("WMO 51-67 / 80-82 / 95-99 → rainy")
    func mapWMORainy() {
        for code in [51, 55, 61, 67, 80, 82, 95, 99] {
            #expect(OpenMeteoResponse.Current.mapWMO(code: code) == .rainy)
        }
    }

    @Test("WMO 71-77 / 85-86 → snowy")
    func mapWMOSnowy() {
        for code in [71, 73, 75, 77, 85, 86] {
            #expect(OpenMeteoResponse.Current.mapWMO(code: code) == .snowy)
        }
    }

    @Test("未知 WMO code 落回 cloudy (安全 fallback)")
    func mapWMOUnknownFallsBack() {
        #expect(OpenMeteoResponse.Current.mapWMO(code: 999) == .cloudy)
        #expect(OpenMeteoResponse.Current.mapWMO(code: -1) == .cloudy)
    }

    // MARK: - 失败路径

    @Test("非 2xx HTTP 抛 OpenMeteoError.badResponse")
    func nonOKResponseThrows() async throws {
        let session = StubSession(
            data: Data(),
            response: HTTPURLResponse(
                url: URL(string: "https://api.open-meteo.com/v1/forecast")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
        )
        let service = OpenMeteoService(session: session.urlSession)

        await #expect(throws: OpenMeteoError.self) {
            try await service.currentWeather(at: .beijing)
        }
    }
}

// MARK: - URLSession stub (走 URLProtocol)

/// 用 URLProtocol 自定义 stub: 不发实际请求, 直接喂 data + response。
private final class StubSession: @unchecked Sendable {
    let urlSession: URLSession

    init(data: Data, response: URLResponse) {
        StubURLProtocol.stubData = data
        StubURLProtocol.stubResponse = response
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        self.urlSession = URLSession(configuration: config)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stubData: Data = Data()
    nonisolated(unsafe) static var stubResponse: URLResponse = URLResponse()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didReceive: Self.stubResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
