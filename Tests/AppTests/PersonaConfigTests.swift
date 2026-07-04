import XCTest
@testable import App
@testable import AgentMode

/// P2a persona 配置测试。测试用 `homeDirectoryOverride` 隔离真 `~/.open-pet-agent/workspace/`。
final class PersonaConfigTests: XCTestCase {
    private var tmpHome: URL!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonaConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testReadSoulNilIfMissing() {
        XCTAssertNil(PersonaConfig.readSoul())
    }

    func testEnsureDefaultSoulCreatesAndPersists() throws {
        let url = try PersonaConfig.ensureDefaultSoul()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let content = PersonaConfig.readSoul()
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("OpenPetAgent") == true)
    }

    func testEnsureDefaultSoulIdempotentPreservesUserEdits() throws {
        try PersonaConfig.ensureDefaultSoul()
        // 用户改 SOUL.md
        let modified = "# 自定义人格\n我是自定义"
        try modified.data(using: .utf8)?.write(to: PersonaConfig.soulMDURL, options: .atomic)
        // 再次 ensure 不覆盖
        try PersonaConfig.ensureDefaultSoul()
        XCTAssertEqual(PersonaConfig.readSoul(), modified)
    }

    func testSoulMDURLUnderWorkspace() {
        XCTAssertTrue(PersonaConfig.soulMDURL.path.hasSuffix(".open-pet-agent/workspace/SOUL.md"))
    }

    func testWriteSoulPersistsAndReads() throws {
        try PersonaConfig.writeSoul("# 自定义人格\n测试内容")
        XCTAssertEqual(PersonaConfig.readSoul(), "# 自定义人格\n测试内容")
    }

    func testResolveSourceDefaultsAuto() {
        let defaults = UserDefaults(suiteName: "PersonaConfigTests-\(UUID().uuidString)")!
        XCTAssertEqual(PersonaConfig.resolveSource(from: defaults), .auto)
    }

    func testSetCurrentSourcePersists() {
        let defaults = UserDefaults(suiteName: "PersonaConfigTests-\(UUID().uuidString)")!
        PersonaConfig.setCurrentSource(.pet, defaults: defaults)
        XCTAssertEqual(PersonaConfig.resolveSource(from: defaults), .pet)
    }

    func testWriteIdentityPersists() throws {
        try PersonaConfig.writeIdentity("# 身份\n小弹")
        XCTAssertEqual(PersonaConfig.readIdentity(), "# 身份\n小弹")
    }

    func testWriteUserPersists() throws {
        try PersonaConfig.writeUser("# 用户\n开发者")
        XCTAssertEqual(PersonaConfig.readUser(), "# 用户\n开发者")
    }

    func testReadPersonaContentConcatenatesAll() throws {
        try PersonaConfig.writeSoul("SOUL 内容")
        try PersonaConfig.writeIdentity("IDENTITY 内容")
        try PersonaConfig.writeUser("USER 内容")
        let content = PersonaConfig.readPersonaContent()
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("SOUL 内容") == true)
        XCTAssertTrue(content?.contains("IDENTITY 内容") == true)
        XCTAssertTrue(content?.contains("USER 内容") == true)
    }

    func testReadPersonaContentSkipsEmpty() throws {
        try PersonaConfig.writeSoul("SOUL 内容")
        try PersonaConfig.writeIdentity("")   // 空 → 跳过
        try PersonaConfig.writeUser("USER 内容")
        let content = PersonaConfig.readPersonaContent()
        XCTAssertTrue(content?.contains("SOUL 内容") == true)
        XCTAssertTrue(content?.contains("USER 内容") == true)
        XCTAssertFalse(content?.contains("IDENTITY 内容") == true)
    }
}
