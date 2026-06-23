import Testing
@testable import ToolMode

@Test("ToolEngineKind 列出三种 engine")
func toolEngineKindListsThreeEngines() {
    #expect(ToolEngineKind.allCases.count == 3)
    #expect(ToolEngineKind.allCases.contains(.claudeCode))
    #expect(ToolEngineKind.allCases.contains(.codex))
    #expect(ToolEngineKind.allCases.contains(.openCode))
}

@Test("ToolEngineKind displayName 是人类可读字面值")
func toolEngineKindDisplayNameIsHumanReadable() {
    #expect(ToolEngineKind.claudeCode.displayName == "Claude Code")
    #expect(ToolEngineKind.codex.displayName == "Codex")
    #expect(ToolEngineKind.openCode.displayName == "opencode")
}

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
