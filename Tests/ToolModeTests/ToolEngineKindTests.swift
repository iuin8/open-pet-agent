import Testing
@testable import ToolMode

@Test("ToolEngineKind 列出三种 engine")
func toolEngineKindListsThreeEngines() {
    #expect(ToolEngineKind.allCases.count == 3)
    #expect(ToolEngineKind.allCases.contains(.claudeCode))
    #expect(ToolEngineKind.allCases.contains(.codex))
    #expect(ToolEngineKind.allCases.contains(.openCode))
}

// 注:展示名已迁到 `ToolEngineRegistry`(id 取代写死 enum,镜像「形象插件化」),
// 见 `ToolEngineRegistryTests`。enum 只保留 rawValue + userDefaultsKey 身份。

@Test("ToolEngineKind userDefaultsKey 是 tool.engine.kind")
func toolEngineKindUserDefaultsKeyIsExpected() {
    #expect(ToolEngineKind.userDefaultsKey == "tool.engine.kind")
}

@Test("ToolEngineKind 可由 raw string 双向序列化")
func toolEngineKindRoundTripsThroughRawValue() {
    for kind in ToolEngineKind.allCases {
        let raw = kind.rawValue
        #expect(ToolEngineKind(rawValue: raw) == kind)
    }
}
