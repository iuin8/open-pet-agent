import XCTest
@testable import AgentMode

final class ProjectCapabilityCommunitySourceStoreTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityCommunitySourceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(
            id: "p/1", name: "P1", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true),
            isExternal: true, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testCommunitySourcesPathIsUserPrivateAndOutsideProjectRoot() {
        let url = ProjectConfig.communitySourcesURL(for: project)

        XCTAssertTrue(url.path.hasPrefix(tmpHome.appendingPathComponent(".open-pet-agent/state/projects", isDirectory: true).path))
        XCTAssertFalse(url.path.hasPrefix(project.rootURL.path))
        XCTAssertEqual(url.lastPathComponent, "community-sources.local.json")
    }

    func testSourceURLValidationAcceptsHTTPSAndRejectsUnsafeSchemesAndHosts() throws {
        XCTAssertEqual(
            try ProjectCapabilityCommunitySource.validatedURL("https://example.com/catalog.json").absoluteString,
            "https://example.com/catalog.json"
        )

        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("http://example.com/catalog.json"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("file:///tmp/catalog.json"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("javascript:alert(1)"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("https://localhost/catalog.json"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("https://127.0.0.1/catalog.json"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("https://169.254.169.254/latest"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("https://user:pass@example.com/catalog.json"))
        XCTAssertThrowsError(try ProjectCapabilityCommunitySource.validatedURL("https://example.com/catalog.json#fragment"))
    }

    func testStoreSaveLoadUpsertDeleteRoundTripsSources() throws {
        let store = ProjectCapabilityCommunitySourceStore()
        let source = try ProjectCapabilityCommunitySource(
            name: "Official MCP Registry",
            url: "https://registry.modelcontextprotocol.io/v0.1/servers",
            isEnabled: true,
            addedAt: "2026-07-22T00:00:00Z"
        )
        let disabled = try ProjectCapabilityCommunitySource(
            name: "Glama",
            url: "https://glama.ai/mcp/servers",
            isEnabled: false,
            addedAt: "2026-07-22T00:00:01Z"
        )

        try store.save([source, disabled], project: project)
        XCTAssertEqual(try store.load(project: project), [source, disabled])

        let renamed = ProjectCapabilityCommunitySource(
            id: source.id,
            name: "MCP Registry",
            url: source.url,
            isEnabled: source.isEnabled,
            addedAt: source.addedAt,
            lastFetchedAt: "2026-07-22T00:01:00Z",
            lastContentHash: "sha256:abc"
        )
        try store.upsert(renamed, project: project)
        XCTAssertEqual(try store.load(project: project), [renamed, disabled])

        try store.delete(id: disabled.id, project: project)
        XCTAssertEqual(try store.load(project: project), [renamed])
    }

    func testStoreReturnsEmptyForMissingOrCorruptState() throws {
        let store = ProjectCapabilityCommunitySourceStore()
        XCTAssertEqual(try store.load(project: project), [])

        let url = ProjectConfig.communitySourcesURL(for: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url, options: .atomic)

        XCTAssertEqual(try store.load(project: project), [])
    }
}
