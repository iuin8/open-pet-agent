// Tests/AgentSensingTests/SessionBrowseTypesTests.swift
import Testing
import Foundation
@testable import AgentSensing

@Suite("会话浏览/钉住数据类型")
struct SessionBrowseTypesTests {
    @Test("PinnedSessionRef Codable 往返保字段")
    func pinnedCodableRoundTrips() throws {
        let ref = PinnedSessionRef(agent: .claudeCode, sessionId: "s1",
                                   filePath: "/a/b/s1.jsonl", title: "改超时", gitBranch: "main",
                                   pinnedAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(ref)
        let back = try JSONDecoder().decode(PinnedSessionRef.self, from: data)
        #expect(back == ref)
    }
}
