import XCTest
@testable import AgentMode

final class ProjectConfigTests: XCTestCase {
    private var tmpHome: URL!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testPluginPathHelpersUseNamedPluginDirectories() {
        let project = AgentProject(
            id: "p1", name: "P1", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true),
            isExternal: true, createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(ProjectConfig.pluginRoot(for: project).path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins", isDirectory: true).path)
        XCTAssertEqual(ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit").path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit", isDirectory: true).path)
        XCTAssertEqual(ProjectConfig.pluginMCPDirectory(for: project, pluginID: "dev-toolkit").path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit/mcp", isDirectory: true).path)
        XCTAssertEqual(ProjectConfig.pluginSkillsDirectory(for: project, pluginID: "dev-toolkit").path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit/skills", isDirectory: true).path)
        XCTAssertEqual(ProjectConfig.pluginPromptsDirectory(for: project, pluginID: "dev-toolkit").path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit/prompts", isDirectory: true).path)
        XCTAssertEqual(ProjectConfig.pluginToolsDirectory(for: project, pluginID: "dev-toolkit").path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit/tools", isDirectory: true).path)
        XCTAssertEqual(ProjectConfig.pluginAgentsDirectory(for: project, pluginID: "dev-toolkit").path, project.rootURL.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit/agents", isDirectory: true).path)
    }

    func testMaterializedPluginDirectoryUsesEngineAndPlugin() {
        let project = AgentProject(
            id: "p1", name: "P1", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true),
            isExternal: true, createdAt: Date(timeIntervalSince1970: 0)
        )

        let url = ProjectConfig.materializedPluginDirectory(
            for: project, engineID: "codex", pluginID: "dev-toolkit")
        XCTAssertEqual(
            url.path,
            project.rootURL.appendingPathComponent(".open-pet-agent/plugins/.materialized/codex/plugins/dev-toolkit", isDirectory: true).path
        )
    }

    func testEnsureCreatesPluginRootButNotNamedPlugin() throws {
        let project = AgentProject(
            id: "p1", name: "P1", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true),
            isExternal: true, createdAt: Date(timeIntervalSince1970: 0)
        )

        _ = try ProjectConfig.ensure(for: project)

        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectConfig.pluginRoot(for: project).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectConfig.opencodeConfig(for: project).path))
    }
}
