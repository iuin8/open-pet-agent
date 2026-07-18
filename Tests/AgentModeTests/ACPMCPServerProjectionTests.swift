import XCTest
@testable import AgentMode

final class ACPMCPServerProjectionTests: XCTestCase {
    private let stdio = ACPJSON.object([
        "name": .string("fs"),
        "command": .string("npx"),
        "args": .array([.string("-y"), .string("srv")]),
        "env": .array([]),
    ])
    private let http = ACPJSON.object([
        "name": .string("remote"),
        "type": .string("http"),
        "url": .string("https://example.com/mcp"),
        "headers": .array([]),
    ])
    private let sse = ACPJSON.object([
        "name": .string("events"),
        "type": .string("sse"),
        "url": .string("https://example.com/sse"),
        "headers": .array([]),
    ])

    func testSupportedKeepsStdioWithoutCapabilities() {
        XCTAssertEqual(ACPMCPServerProjection.supported([stdio], capabilities: []), [stdio])
    }

    func testSupportedDropsHTTPWhenCapabilityMissing() {
        XCTAssertEqual(ACPMCPServerProjection.supported([http], capabilities: []), [])
    }

    func testSupportedKeepsHTTPWhenCapabilityPresent() {
        XCTAssertEqual(ACPMCPServerProjection.supported([http], capabilities: [.http]), [http])
    }

    func testSupportedFiltersSSEIndependently() {
        XCTAssertEqual(ACPMCPServerProjection.supported([sse], capabilities: [.http]), [])
        XCTAssertEqual(ACPMCPServerProjection.supported([sse], capabilities: [.http, .sse]), [sse])
    }

    func testSupportedKeepsOrderAndMixedServers() {
        let result = ACPMCPServerProjection.supported([http, stdio, sse], capabilities: [.sse])
        XCTAssertEqual(result, [stdio, sse])
    }
}
