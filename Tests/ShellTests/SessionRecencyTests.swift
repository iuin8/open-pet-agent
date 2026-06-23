import Testing
import Foundation
@testable import Shell

@Suite("SessionRecency — picker 相对时间 / 活跃判定")
struct SessionRecencyTests {

    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("相对时间各档:刚刚 / 分 / 时 / 天")
    func relativeBuckets() {
        #expect(SessionRecency.shortRelative(from: now.addingTimeInterval(-30), now: now) == "刚刚")
        #expect(SessionRecency.shortRelative(from: now.addingTimeInterval(-120), now: now) == "2m")
        #expect(SessionRecency.shortRelative(from: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(SessionRecency.shortRelative(from: now.addingTimeInterval(-172_800), now: now) == "2d")
    }

    @Test("未来时间(时钟偏差)→ 钳到刚刚,不出负数")
    func futureClamped() {
        #expect(SessionRecency.shortRelative(from: now.addingTimeInterval(60), now: now) == "刚刚")
    }

    @Test("isOngoing:窗口内 true / 窗口外 false / nil → false")
    func ongoing() {
        #expect(SessionRecency.isOngoing(lastModified: now.addingTimeInterval(-10), now: now))
        #expect(!SessionRecency.isOngoing(lastModified: now.addingTimeInterval(-120), now: now))
        #expect(!SessionRecency.isOngoing(lastModified: nil, now: now))
    }
}
