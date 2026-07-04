import Foundation
import AgentMode

/// Persona 来源(P2c:用户可配,覆盖能力闸自动)。
/// `auto` = 能力闸(nativePersona 后端不注入;云后端注入);`pet` = 强制注入 SOUL.md;`thirdParty` = 强制不注入。
public enum PersonaSource: String, CaseIterable, Sendable {
    case auto, pet, thirdParty
    public var displayName: String {
        switch self {
        case .auto:       return "自动(能力闸)"
        case .pet:        return "Pet(SOUL.md)"
        case .thirdParty: return "第三方(后端自带)"
        }
    }
}

/// PetAgent persona 配置(SOUL.md,pet 人格文件)。P2a:云后端注入 SOUL.md 到 system message。
///
/// `~/.open-pet-agent/workspace/SOUL.md`(默认中文 pet 人格,app 启动 ensure 幂等,用户改保留)。
/// `CompanionOrchestrator.personaResolver` 读 SOUL.md 注入 `buildSystemPrompt`(云后端;
/// `nativePersona` 后端如 openclaw 自管 SOUL,PetAgent 不注入 —— 能力闸自动)。
///
/// 详见 `docs/project-config-architecture-design.md` §9 留后(persona 注入机制)。
public enum PersonaConfig {

    /// workspace 根:`~/.open-pet-agent/workspace/`。
    public static var workspaceURL: URL {
        ProjectConfig.homeRoot.appendingPathComponent(".open-pet-agent/workspace", isDirectory: true)
    }

    /// SOUL.md 路径:`~/.open-pet-agent/workspace/SOUL.md`。
    public static var soulMDURL: URL {
        workspaceURL.appendingPathComponent("SOUL.md", isDirectory: false)
    }

    /// 读 SOUL.md 内容(不存在/损坏 → nil → 调用方用 base 硬编码)。
    public static func readSoul() -> String? {
        guard let data = try? Data(contentsOf: soulMDURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写 SOUL.md(用户编辑后保存)。原子写,创建父目录。下次 reply 读新内容(热更新)。
    @discardableResult
    public static func writeSoul(_ content: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: soulMDURL, options: .atomic)
        return soulMDURL
    }

    // MARK: - IDENTITY.md(pet 名/emoji)+ USER.md(用户画像)—— P2c-2/3

    /// IDENTITY.md 路径:`~/.open-pet-agent/workspace/IDENTITY.md`。
    public static var identityMDURL: URL {
        workspaceURL.appendingPathComponent("IDENTITY.md", isDirectory: false)
    }
    /// USER.md 路径:`~/.open-pet-agent/workspace/USER.md`。
    public static var userMDURL: URL {
        workspaceURL.appendingPathComponent("USER.md", isDirectory: false)
    }

    /// 读 IDENTITY.md(不存在 → nil)。
    public static func readIdentity() -> String? {
        guard let data = try? Data(contentsOf: identityMDURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// 读 USER.md(不存在 → nil)。
    public static func readUser() -> String? {
        guard let data = try? Data(contentsOf: userMDURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func writeIdentity(_ content: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: identityMDURL, options: .atomic)
        return identityMDURL
    }
    @discardableResult
    public static func writeUser(_ content: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: userMDURL, options: .atomic)
        return userMDURL
    }

    @discardableResult
    public static func ensureDefaultIdentity() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: identityMDURL.path) else { return identityMDURL }
        try defaultIdentityContent.data(using: .utf8)?.write(to: identityMDURL, options: .atomic)
        return identityMDURL
    }
    @discardableResult
    public static func ensureDefaultUser() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: userMDURL.path) else { return userMDURL }
        try defaultUserContent.data(using: .utf8)?.write(to: userMDURL, options: .atomic)
        return userMDURL
    }

    /// 读完整 persona 内容(SOUL.md + IDENTITY.md + USER.md 拼接,空跳过)。注入 system message。
    public static func readPersonaContent() -> String? {
        let parts = [readSoul(), readIdentity(), readUser()]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n---\n\n")
    }

    public static let defaultIdentityContent = """
# 身份

- 名字:小弹
- Emoji:🔮
"""

    public static let defaultUserContent = """
# 用户画像

(填你的名字/职业/偏好/工作内容,让 pet 更懂你。留空则不注入。)
"""

    /// UserDefaults key(当前 persona 来源)。沿用 `tool.*` 命名。
    public static var personaSourceKey: String { "tool.persona.source" }

    /// 读当前 persona 来源(UD 缺失/值无效 → .auto 默认)。
    public static func resolveSource(from defaults: UserDefaults = .standard) -> PersonaSource {
        guard let raw = defaults.string(forKey: personaSourceKey),
              let source = PersonaSource(rawValue: raw) else { return .auto }
        return source
    }

    /// 设置 persona 来源。
    public static func setCurrentSource(_ source: PersonaSource, defaults: UserDefaults = .standard) {
        defaults.set(source.rawValue, forKey: personaSourceKey)
    }

    /// 确保默认 SOUL.md 存在(幂等,已存在不覆盖)。app 启动调。
    @discardableResult
    public static func ensureDefaultSoul() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let url = soulMDURL
        guard !fm.fileExists(atPath: url.path) else { return url }
        try defaultSoulContent.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    /// 默认中文 pet 人格(用户改 SOUL.md 后保留,不覆盖)。
    public static let defaultSoulContent = """
# OpenPetAgent 人格

你是 OpenPetAgent,一颗生活在用户 macOS 桌面的 AI 弹力球桌宠。你和桌面的雪/雨物理沙盒共生 —— 能造雪、能感知桌面窗口、能聊天、能主动协助。

## 性格
- **友好活泼**:像一只聪明的桌面伴侣,语气轻松自然,不端着。
- **简洁直接**:用户问什么答什么,不啰嗦不绕弯。能用一句话说清楚就不用三句。
- **桌面感知**:你知道用户当前在用什么 app、看什么窗口、光标在哪、时段,回复贴合上下文。
- **不剧透思考**:只输出最终答复,永不展示推理过程/元叙述(如「用户问…」「根据系统…」),永不包 thinking 标签,永不复述任务。

## 语言
跟随用户语言,默认简体中文。代码/技术标识符保留原文。

## 边界
你是伴侣 + 助理,不是命令行工具。主动协助但不打扰;造雪/物理是趣味,聊天/协助是主业。
"""
}
