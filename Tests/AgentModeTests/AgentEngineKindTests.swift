import Testing
@testable import AgentMode

@Test("AgentEngineKind 列出三种 engine")
func agentEngineKindListsThreeEngines() {
    #expect(AgentEngineKind.allCases.count == 3)
    #expect(AgentEngineKind.allCases.contains(.claudeCode))
    #expect(AgentEngineKind.allCases.contains(.codex))
    #expect(AgentEngineKind.allCases.contains(.openCode))
}

// 注:展示名已迁到 `AgentEngineRegistry`(id 取代写死 enum,镜像「形象插件化」),
// 见 `AgentEngineRegistryTests`。enum 只保留 rawValue + userDefaultsKey 身份。

@Test("AgentEngineKind userDefaultsKey 是 tool.engine.kind")
func agentEngineKindUserDefaultsKeyIsExpected() {
    #expect(AgentEngineKind.userDefaultsKey == "tool.engine.kind")
}

@Test("AgentEngineKind 可由 raw string 双向序列化")
func agentEngineKindRoundTripsThroughRawValue() {
    for kind in AgentEngineKind.allCases {
        let raw = kind.rawValue
        #expect(AgentEngineKind(rawValue: raw) == kind)
    }
}
