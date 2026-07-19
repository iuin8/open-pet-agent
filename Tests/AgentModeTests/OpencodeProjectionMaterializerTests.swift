import XCTest
@testable import AgentMode

final class OpencodeProjectionMaterializerTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpencodeProjectionMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testApplyCopiesGeneratedPluginDirectory() throws {
        let source = try makeSourcePlugin(id: "dev-toolkit")
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )
        let plan = ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "opencode",
            operations: [.copyDirectory(source: source, destination: destination)]
        )

        try OpencodeProjectionMaterializer().apply([plan])

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugin.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".open-pet-agent-generated").path))
        XCTAssertTrue(ProjectionGeneratedManifestStore.isGeneratedTarget(destination, projectRoot: project.rootURL))
    }

    func testApplyReplacesOwnedGeneratedPluginDirectoryAndRemovesStaleFiles() throws {
        let source = try makeSourcePlugin(id: "dev-toolkit", contents: "fresh")
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )
        let plan = ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "opencode",
            operations: [.copyDirectory(source: source, destination: destination)]
        )
        try OpencodeProjectionMaterializer().apply([plan])
        try "stale".write(to: destination.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        try "fresh-2".write(to: source.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        try OpencodeProjectionMaterializer().apply([plan])

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.txt").path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("plugin.json"), encoding: .utf8), "fresh-2")
    }

    func testApplyRejectsExistingUnmarkedDirectory() throws {
        let source = try makeSourcePlugin(id: "dev-toolkit")
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: source, destination: destination)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .unownedDestination(destination))
        }
    }

    func testApplyRejectsSymlinkedDestinationEscapingProject() throws {
        let source = try makeSourcePlugin(id: "dev-toolkit")
        let root = project.rootURL
            .appendingPathComponent(".open-pet-agent/plugins/.materialized", isDirectory: true)
        let externalRoot = tmpHome.appendingPathComponent("external-materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: externalRoot)
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: source, destination: destination)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .destinationEscapesProject(destination))
        }
    }

    func testApplyRejectsProjectOpencodeJSONDestination() throws {
        let configURL = ProjectConfig.opencodeConfig(for: project)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"model\":\"user/model\"}".write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.writeFile(contents: "{}", destination: configURL)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .destinationEscapesProject(configURL))
            XCTAssertEqual(try? String(contentsOf: configURL, encoding: .utf8), "{\"model\":\"user/model\"}")
        }
    }

    func testApplyCopiesOnlyConfigDataDirectories() throws {
        let source = try makeSourcePlugin(id: "dev-toolkit")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills/code-review", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("hooks", isDirectory: true), withIntermediateDirectories: true)
        try "server".write(to: source.appendingPathComponent("mcp/servers.json"), atomically: true, encoding: .utf8)
        try "skill".write(to: source.appendingPathComponent("skills/code-review/SKILL.md"), atomically: true, encoding: .utf8)
        try "exec".write(to: source.appendingPathComponent("bin/run"), atomically: true, encoding: .utf8)
        try "hook".write(to: source.appendingPathComponent("hooks/pre.sh"), atomically: true, encoding: .utf8)
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )

        try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: source, destination: destination)]
            )
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("mcp/servers.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("skills/code-review/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bin/run").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("hooks/pre.sh").path))
    }

    func testApplyRejectsSymlinkedConfigDataSourceOutsidePlugin() throws {
        let source = try makeSourcePlugin(id: "dev-toolkit")
        let externalSkills = tmpHome.appendingPathComponent("external-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("skills", isDirectory: true),
            withDestinationURL: externalSkills
        )
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: source, destination: destination)]
            )
        ])) { error in
            guard case let .sourceEscapesPlugin(url) = error as? OpencodeProjectionMaterializerError else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertEqual(
                url.standardizedFileURL.path,
                source.appendingPathComponent("skills", isDirectory: true).standardizedFileURL.path
            )
        }
    }

    func testApplyRejectsSymlinkedPluginRootOutsideProject() throws {
        let realSource = try makeSourcePlugin(id: "real-dev-toolkit")
        let source = tmpHome.appendingPathComponent("source-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: realSource)
        let destination = ProjectConfig.materializedPluginDirectory(
            for: project,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "dev-toolkit"
        )

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: source, destination: destination)]
            )
        ])) { error in
            guard case let .sourceEscapesPlugin(url) = error as? OpencodeProjectionMaterializerError else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertEqual(url.standardizedFileURL.path, source.standardizedFileURL.path)
        }
    }

    func testApplyWritesRootOpencodeConfigAndCopiesNativeSkills() throws {
        let configURL = project.rootURL.appendingPathComponent("opencode.json")
        let skillSource = try makeSourceSkill()
        let skillDestination = project.rootURL.appendingPathComponent(".opencode/skills/dev-toolkit-code-review", isDirectory: true)
        let plan = ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "opencode",
            operations: [
                .writeFile(contents: #"{"mcp":{"filesystem":{"command":["npx"]}}}"#, destination: configURL),
                .copyDirectory(source: skillSource, destination: skillDestination)
            ]
        )

        try OpencodeProjectionMaterializer().apply([plan])

        let config = try JSONDecoder().decode(ACPJSON.self, from: Data(contentsOf: configURL))
        XCTAssertNotNil(config.objectValue?["mcp"]?.objectValue?["filesystem"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDestination.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillDestination.appendingPathComponent(".open-pet-agent-generated").path))
        XCTAssertTrue(ProjectionGeneratedManifestStore.isGeneratedTarget(skillDestination, projectRoot: project.rootURL))
    }

    func testApplyRejectsExistingUserRootOpencodeConfig() throws {
        let configURL = project.rootURL.appendingPathComponent("opencode.json")
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        try #"{"model":"user/model"}"#.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.writeFile(contents: #"{"mcp":{}}"#, destination: configURL)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .unownedDestination(configURL))
            XCTAssertEqual(try? String(contentsOf: configURL, encoding: .utf8), #"{"model":"user/model"}"#)
        }
    }

    func testApplyRejectsExistingUserNativeSkillDirectory() throws {
        let skillSource = try makeSourceSkill()
        let destination = project.rootURL.appendingPathComponent(".opencode/skills/dev-toolkit-code-review", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "user".write(to: destination.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: skillSource, destination: destination)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .unownedDestination(destination))
        }
    }

    func testApplyRejectsSymlinkedNativeSkillsDirectoryOutsideProject() throws {
        let skillSource = try makeSourceSkill()
        let opencodeDir = project.rootURL.appendingPathComponent(".opencode", isDirectory: true)
        let skillsDir = opencodeDir.appendingPathComponent("skills", isDirectory: true)
        let externalSkills = tmpHome.appendingPathComponent("external-opencode-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillsDir, withDestinationURL: externalSkills)
        let destination = skillsDir.appendingPathComponent("dev-toolkit-code-review", isDirectory: true)

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.copyDirectory(source: skillSource, destination: destination)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .destinationEscapesProject(destination))
        }
    }

    func testApplyRejectsSymlinkedRootOpencodeJSONOutsideProject() throws {
        let configURL = project.rootURL.appendingPathComponent("opencode.json")
        let externalConfig = tmpHome.appendingPathComponent("external-opencode.json")
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        try "{}".write(to: externalConfig, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: externalConfig)

        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.writeFile(contents: #"{"mcp":{}}"#, destination: configURL)]
            )
        ])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .destinationEscapesProject(configURL))
        }
    }

    func testApplyDoesNotBlockWhenManifestBookkeepingFails() throws {
        // `.open-pet-agent/state` 被同名文件占用 → 登记静默放行,不阻断 materialize,也不写任何旁路文件。
        let statePath = project.rootURL.appendingPathComponent(".open-pet-agent/state", isDirectory: true)
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: statePath, options: .atomic)
        let configURL = project.rootURL.appendingPathComponent("opencode.json")
        let skillSource = try makeSourceSkill()
        let skillDestination = project.rootURL.appendingPathComponent(".opencode/skills/dev-toolkit-code-review", isDirectory: true)
        let plan = ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: "opencode",
            operations: [
                .writeFile(contents: #"{"mcp":{}}"#, destination: configURL),
                .copyDirectory(source: skillSource, destination: skillDestination)
            ]
        )

        try OpencodeProjectionMaterializer().apply([plan])

        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDestination.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent(".open-pet-agent-generated.opencode").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillDestination.appendingPathComponent(".open-pet-agent-generated").path))
        // 簿记失败 → 无 ownership 记录。
        XCTAssertFalse(ProjectionGeneratedManifestStore.isGeneratedTarget(configURL, projectRoot: project.rootURL))

        // state 修复后:目标已存在但 ownership 无法证明 → fail-closed 拒绝覆盖。
        try FileManager.default.removeItem(at: statePath)
        XCTAssertThrowsError(try OpencodeProjectionMaterializer().apply([plan])) { error in
            XCTAssertEqual(error as? OpencodeProjectionMaterializerError, .unownedDestination(configURL))
        }

        // 恢复路径:删掉无归属 payload 重新 sync,成功并恢复登记。
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.removeItem(at: skillDestination)
        try OpencodeProjectionMaterializer().apply([plan])
        XCTAssertTrue(ProjectionGeneratedManifestStore.isGeneratedTarget(configURL, projectRoot: project.rootURL))
        XCTAssertTrue(ProjectionGeneratedManifestStore.isGeneratedTarget(skillDestination, projectRoot: project.rootURL))
    }

    func testApplyRemoveGeneratedReleasesManifest() throws {
        let configURL = project.rootURL.appendingPathComponent("opencode.json")
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        var manifest = ProjectionGeneratedManifest()
        manifest.claim(path: "opencode.json", kind: .file, engineID: AgentEngineKind.openCode.rawValue)
        try ProjectionGeneratedManifestStore.save(manifest, projectRoot: project.rootURL)

        try OpencodeProjectionMaterializer().apply([
            ProjectionPlan(
                projectID: project.id,
                engineID: AgentEngineKind.openCode.rawValue,
                pluginID: "opencode",
                operations: [.removeGenerated(configURL)]
            )
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(try ProjectionGeneratedManifestStore.load(projectRoot: project.rootURL).contains(path: "opencode.json"))
    }

    private func makeSourcePlugin(id: String, contents: String = "source") throws -> URL {
        let source = tmpHome.appendingPathComponent("source-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try contents.write(to: source.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        return source
    }

    private func makeSourceSkill() throws -> URL {
        let source = tmpHome.appendingPathComponent("source-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: code-review\ndescription: Review code\n---\n".write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return source
    }
}
