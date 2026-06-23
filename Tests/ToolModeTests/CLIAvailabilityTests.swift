import Foundation
import Testing
@testable import ToolMode

@Test("CLIAvailability 在注入的 searchPaths 找到 /bin/ls")
func cliAvailabilityFindsLsInInjectedSearchPaths() async {
    let availability = CLIAvailability()
    let result = await availability.locate(binary: "ls", searchPaths: ["/bin", "/usr/bin"])
    // /bin/ls 在所有支持的 macOS 版本上都存在
    #expect(result == "/bin/ls")
}

@Test("CLIAvailability 找不到不存在的 binary 返回 nil")
func cliAvailabilityReturnsNilForMissingBinary() async {
    let availability = CLIAvailability()
    let result = await availability.locate(
        binary: "fake-binary-xyz-does-not-exist",
        searchPaths: ["/tmp", "/var/empty"]
    )
    #expect(result == nil)
}

@Test("CLIAvailability 跳过空字符串 searchPaths")
func cliAvailabilitySkipsEmptySearchPaths() async {
    let availability = CLIAvailability()
    let result = await availability.locate(
        binary: "ls",
        searchPaths: ["", "/bin"]
    )
    #expect(result == "/bin/ls")
}

@Test("CLIAvailability.binaryName 映射所有 engine kind")
func cliAvailabilityBinaryNameMapsAllKinds() {
    #expect(CLIAvailability.binaryName(for: .claudeCode) == "claude")
    #expect(CLIAvailability.binaryName(for: .codex) == "codex")
    #expect(CLIAvailability.binaryName(for: .openCode) == "opencode")
}

@Test("CLIAvailability 默认走 PATH 环境变量")
func cliAvailabilityUsesEnvPathByDefault() async {
    let availability = CLIAvailability()
    // ls 几乎肯定在 PATH 里(macOS /bin 通常在默认 PATH)
    // 这个测试在某些极端 sandboxed 环境可能不可靠,但作为冒烟测试足够
    let result = await availability.locate(binary: "ls")
    #expect(result != nil)
}
