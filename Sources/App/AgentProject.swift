import Foundation

/// PetAgent agent 工作项目(P1a 多项目数据地基)。
///
/// 一个项目 = 一个 agent 工作上下文:cwd(项目根)+ opencode config(`.open-pet-agent/opencode.json`)
/// + 产出位置(`.open-pet-agent/outputs/`)。`applySelectedAgentEngine` 用 `ProjectStore.current()`
/// 选中的项目做 ACP engine 的 cwd + `OPENCODE_CONFIG` env。
///
/// - 托管项目(`isExternal=false`):`~/.open-pet-agent/projects/<id>/`,app 统一管理。
/// - 外部项目(`isExternal=true`,P1b):用户外部目录(如 `~/work/my-app/`),跟项目走(VSCode 模式)。
///
/// 详见 `docs/project-config-architecture-design.md`。
struct AgentProject: Identifiable, Codable, Sendable, Equatable {
    /// 稳定身份。default 项目 id="default"(确定性,跨机器一致);用户创建项目用 UUID。
    let id: String
    /// 展示名(UI 列表用)。
    var name: String
    /// 项目根(托管:`~/.open-pet-agent/projects/<id>/`;外部:用户目录)。
    var rootURL: URL
    /// 托管 vs 外部。P1a 仅托管;外部预留 P1b。
    var isExternal: Bool
    /// 创建时间(UI 排序用)。
    var createdAt: Date
}
