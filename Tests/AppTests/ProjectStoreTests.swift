import XCTest
@testable import App

/// P1a 多项目数据地基测试。测试用 `homeDirectoryOverride` 隔离真 `~/.open-pet-agent/`,
/// 用临时 HOME + 隔离 UserDefaults suite,绝不污染真环境。
final class ProjectStoreTests: XCTestCase {
    private var tmpHome: URL!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome {
            try? FileManager.default.removeItem(at: tmpHome)
        }
        super.tearDown()
    }

    // MARK: - list / current fallback

    func testListEmptyReturnsDefault() {
        // projects.json 不存在 → [default]
        let projects = ProjectStore.list()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.id, "default")
    }

    func testCurrentUDMissingFallsBackToDefault() {
        let current = ProjectStore.current(defaults: makeIsolatedDefaults())
        XCTAssertEqual(current.id, "default")
    }

    func testCurrentUnknownIDFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        defaults.set("nonexistent-id", forKey: ProjectStore.currentProjectIDKey)
        let current = ProjectStore.current(defaults: defaults)
        XCTAssertEqual(current.id, "default")
    }

    // MARK: - create / setCurrent

    func testCreateEnsuresOpencodeJSONAndPersists() throws {
        let project = try ProjectStore.create(name: "新项目")
        // .open-pet-agent/opencode.json 存在
        let config = ProjectConfig.opencodeConfig(for: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        // 写入 projects.json(list 含新项目 + default)
        let projects = ProjectStore.list()
        XCTAssertTrue(projects.contains { $0.id == project.id })
        XCTAssertEqual(project.name, "新项目")
        XCTAssertFalse(project.isExternal)
    }

    func testSetCurrentThenCurrentReturnsIt() throws {
        let defaults = makeIsolatedDefaults()
        let project = try ProjectStore.create(name: "我的项目")
        ProjectStore.setCurrent(project.id, defaults: defaults)
        let current = ProjectStore.current(defaults: defaults)
        XCTAssertEqual(current.id, project.id)
        XCTAssertEqual(current.name, "我的项目")
    }

    // MARK: - ensureDefaultProjectRegistered

    func testEnsureDefaultProjectRegisteredIdempotent() {
        ProjectStore.ensureDefaultProjectRegistered(defaults: makeIsolatedDefaults())
        ProjectStore.ensureDefaultProjectRegistered(defaults: makeIsolatedDefaults())
        let projects = ProjectStore.list()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.id, "default")
        // default 的 opencode.json 存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectConfig.defaultOpencodeConfig.path))
    }

    func testEnsureDefaultProjectRegisteredSetsUD() {
        let defaults = makeIsolatedDefaults()
        ProjectStore.ensureDefaultProjectRegistered(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ProjectStore.currentProjectIDKey), "default")
    }

    // MARK: - AgentProject Codable

    func testAgentProjectCodableRoundTrip() throws {
        let project = AgentProject(
            id: "test-id",
            name: "测试项目",
            rootURL: URL(fileURLWithPath: "/tmp/test"),
            isExternal: true,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(AgentProject.self, from: data)
        XCTAssertEqual(project, decoded)
    }

    // MARK: - createExternal / rename / delete

    func testCreateExternalEnsuresOpencodeJSONAndPersists() throws {
        let externalRoot = tmpHome.appendingPathComponent("external-app", isDirectory: true)
        let project = try ProjectStore.createExternal(name: "外部项目", rootURL: externalRoot)
        XCTAssertTrue(project.isExternal)
        XCTAssertEqual(project.rootURL, externalRoot)
        // .open-pet-agent/opencode.json 建在外部目录
        let config = ProjectConfig.opencodeConfig(for: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        // 写入 projects.json
        XCTAssertTrue(ProjectStore.list().contains { $0.id == project.id })
    }

    func testRenameChangesName() throws {
        let project = try ProjectStore.create(name: "旧名")
        try ProjectStore.rename(id: project.id, newName: "新名")
        let updated = ProjectStore.list().first { $0.id == project.id }
        XCTAssertEqual(updated?.name, "新名")
    }

    func testRenameDefaultNoOp() throws {
        // default 不可改名(系统项目)
        try ProjectStore.rename(id: ProjectConfig.defaultProject.id, newName: "不该改")
        XCTAssertEqual(ProjectStore.list().first { $0.id == "default" }?.name, "默认项目")
    }

    func testDeleteRemovesProject() throws {
        let project = try ProjectStore.create(name: "待删")
        try ProjectStore.delete(id: project.id)
        XCTAssertFalse(ProjectStore.list().contains { $0.id == project.id })
    }

    func testDeleteDefaultNoOp() throws {
        // default 不可删(系统项目)
        try ProjectStore.delete(id: ProjectConfig.defaultProject.id)
        XCTAssertTrue(ProjectStore.list().contains { $0.id == "default" })
    }

    // MARK: - helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
