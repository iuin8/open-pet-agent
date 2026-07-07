import XCTest
@testable import App
@testable import AgentMode

/// P3 FrontmostProjectDetector.matchProject 测试(纯函数,不依赖 NSWorkspace/proc_pidinfo)。
final class FrontmostProjectDetectorTests: XCTestCase {

    private func project(_ id: String, _ root: String) -> AgentProject {
        AgentProject(id: id, name: id, rootURL: URL(fileURLWithPath: root),
                    isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testMatchExactRoot() {
        let projects = [project("p1", "/Users/fa/work/app")]
        let matched = FrontmostProjectDetector.matchProject(
            cwd: URL(fileURLWithPath: "/Users/fa/work/app"), in: projects)
        XCTAssertEqual(matched?.id, "p1")
    }

    func testMatchSubdirectory() {
        let projects = [project("p1", "/Users/fa/work/app")]
        let matched = FrontmostProjectDetector.matchProject(
            cwd: URL(fileURLWithPath: "/Users/fa/work/app/src/main.swift"), in: projects)
        XCTAssertEqual(matched?.id, "p1")
    }

    func testNoMatchDifferentDir() {
        let projects = [project("p1", "/Users/fa/work/app")]
        let matched = FrontmostProjectDetector.matchProject(
            cwd: URL(fileURLWithPath: "/Users/fa/other"), in: projects)
        XCTAssertNil(matched)
    }

    func testLongestPrefixWins() {
        let projects = [
            project("outer", "/Users/fa/work"),
            project("inner", "/Users/fa/work/app")
        ]
        let matched = FrontmostProjectDetector.matchProject(
            cwd: URL(fileURLWithPath: "/Users/fa/work/app/src"), in: projects)
        XCTAssertEqual(matched?.id, "inner")
    }

    func testRootPathNotPartialMatch() {
        // /Users/fa/work-app 不应匹配 /Users/fa/work（前缀相同但不是路径分段边界）。
        let projects = [project("p1", "/Users/fa/work")]
        let matched = FrontmostProjectDetector.matchProject(
            cwd: URL(fileURLWithPath: "/Users/fa/work-app/src"), in: projects)
        XCTAssertNil(matched)
    }

    func testRootWithTrailingSlashStillMatchesSubdirectory() {
        let projects = [project("p1", "/Users/fa/work/app/")]
        let matched = FrontmostProjectDetector.matchProject(
            cwd: URL(fileURLWithPath: "/Users/fa/work/app/Sources/main.swift"), in: projects)
        XCTAssertEqual(matched?.id, "p1")
    }
}
