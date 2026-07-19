import XCTest
@testable import AgentMode

final class ProjectionGeneratedManifestTests: XCTestCase {
    private var tmpHome: URL!
    private var projectRoot: URL!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectionGeneratedManifestTests-\(UUID().uuidString)", isDirectory: true)
        projectRoot = tmpHome.appendingPathComponent("repo", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testClaimContainsReleaseAndPersistenceRoundtrip() throws {
        var manifest = ProjectionGeneratedManifest()
        XCTAssertFalse(manifest.contains(path: ".mcp.json"))

        manifest.claim(path: ".mcp.json", kind: .file, engineID: AgentEngineKind.claudeCode.rawValue)
        manifest.claim(path: ".claude/skills/review", kind: .directory, engineID: AgentEngineKind.claudeCode.rawValue)
        XCTAssertTrue(manifest.contains(path: ".mcp.json"))
        XCTAssertTrue(manifest.contains(path: ".claude/skills/review"))
        XCTAssertEqual(manifest.targets.map(\.path), [".claude/skills/review", ".mcp.json"])

        try ProjectionGeneratedManifestStore.save(manifest, projectRoot: projectRoot)
        let loaded = try ProjectionGeneratedManifestStore.load(projectRoot: projectRoot)
        XCTAssertEqual(loaded, manifest)

        var released = loaded
        released.release(path: ".mcp.json")
        XCTAssertFalse(released.contains(path: ".mcp.json"))
        XCTAssertTrue(released.contains(path: ".claude/skills/review"))
    }

    func testLoadMissingManifestReturnsEmpty() throws {
        let manifest = try ProjectionGeneratedManifestStore.load(projectRoot: projectRoot)
        XCTAssertEqual(manifest.schemaVersion, ProjectionGeneratedManifest.currentSchemaVersion)
        XCTAssertTrue(manifest.targets.isEmpty)
    }

    func testRelativePathInsideProject() {
        let url = projectRoot.appendingPathComponent(".claude/skills/review", isDirectory: true)
        XCTAssertEqual(
            ProjectionGeneratedManifestStore.relativePath(for: url, projectRoot: projectRoot),
            ".claude/skills/review"
        )
        XCTAssertNil(ProjectionGeneratedManifestStore.relativePath(for: projectRoot, projectRoot: projectRoot))
        XCTAssertNil(ProjectionGeneratedManifestStore.relativePath(
            for: tmpHome.appendingPathComponent("other", isDirectory: true),
            projectRoot: projectRoot
        ))
    }

    func testRelativePathResolvesSymlinkedPrefixes() throws {
        // macOS 上 temporaryDirectory 常含 /var→/private/var symlink;resolved url 也必须能匹配。
        let lexical = projectRoot.appendingPathComponent(".mcp.json", isDirectory: false)
        try "{}".write(to: lexical, atomically: true, encoding: .utf8)
        let resolved = lexical.resolvingSymlinksInPath()
        XCTAssertEqual(
            ProjectionGeneratedManifestStore.relativePath(for: resolved, projectRoot: projectRoot),
            ".mcp.json"
        )
    }

    func testIsGeneratedTargetUsesManifest() throws {
        let url = projectRoot.appendingPathComponent("opencode.json", isDirectory: false)
        var manifest = ProjectionGeneratedManifest()
        manifest.claim(path: "opencode.json", kind: .file, engineID: AgentEngineKind.openCode.rawValue)
        try ProjectionGeneratedManifestStore.save(manifest, projectRoot: projectRoot)

        XCTAssertTrue(ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot))
        XCTAssertFalse(ProjectionGeneratedManifestStore.isGeneratedTarget(
            projectRoot.appendingPathComponent(".mcp.json", isDirectory: false),
            projectRoot: projectRoot
        ))
    }

    func testIsGeneratedTargetFailsClosedWhenManifestCorrupt() throws {
        let url = projectRoot.appendingPathComponent("opencode.json", isDirectory: false)
        let manifestURL = ProjectionGeneratedManifestStore.manifestURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectionGeneratedManifestStore.load(projectRoot: projectRoot))
        XCTAssertFalse(ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot))
    }

    func testClaimBestEffortDoesNotThrowWhenManifestUnwritable() throws {
        // `.open-pet-agent/state` 被同名文件占用 → 登记静默放行,不阻断 materialize。
        let statePath = projectRoot.appendingPathComponent(".open-pet-agent/state", isDirectory: true)
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: statePath, options: .atomic)
        let url = projectRoot.appendingPathComponent("opencode.json", isDirectory: false)

        ProjectionGeneratedManifestStore.claimBestEffort(url, kind: .file, engineID: AgentEngineKind.openCode.rawValue, projectRoot: projectRoot)

        XCTAssertFalse(ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot))
        // state 修复后重新登记成功。
        try FileManager.default.removeItem(at: statePath)
        ProjectionGeneratedManifestStore.claimBestEffort(url, kind: .file, engineID: AgentEngineKind.openCode.rawValue, projectRoot: projectRoot)
        XCTAssertTrue(ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot))
    }
}
