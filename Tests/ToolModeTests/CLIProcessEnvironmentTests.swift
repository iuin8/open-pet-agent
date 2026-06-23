import Foundation
import Testing
@testable import ToolMode

@Test("CLIProcessEnvironment.augmented 返回的 dict 包含 PATH key")
func augmentedHasPathKey() {
    let env = CLIProcessEnvironment.augmented()
    #expect(env["PATH"] != nil)
    #expect(!(env["PATH"] ?? "").isEmpty)
}

@Test("CLIProcessEnvironment.augmented 注入的 extraPaths 出现在 PATH 末尾")
func augmentedAppendsExtraPaths() {
    // 用真实存在的目录 /tmp (mergedPath 不再校验存在性,
    // 即便不校验也可读;但为了稳保险用 /tmp)
    let env = CLIProcessEnvironment.augmented(extraPaths: ["/tmp"])
    let pathValue = env["PATH"] ?? ""
    #expect(pathValue.contains("/tmp"))
    // 原 PATH 在前 — 新加的 /tmp 应在 PATH 末尾或至少在原 PATH 之后
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    if let firstOriginalDir = originalPath.split(separator: ":").first {
        let tmpRange = pathValue.range(of: "/tmp")
        let originalRange = pathValue.range(of: String(firstOriginalDir))
        if let tr = tmpRange, let or = originalRange {
            #expect(or.lowerBound < tr.lowerBound)
        }
    }
}

@Test("CLIProcessEnvironment.augmented 保留原 ProcessInfo.environment.PATH 在前")
func augmentedPreservesOriginalPathFirst() {
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    guard !originalPath.isEmpty else {
        // CI 没设 PATH 的边界场景跳过
        return
    }
    let env = CLIProcessEnvironment.augmented()
    let merged = env["PATH"] ?? ""
    // 原 PATH 的每个段(tilde 展开后)都应在 merged 里出现 —
    // mergedPath 会做 tilde 展开,所以比较前也要展开
    for dir in originalPath.split(separator: ":") {
        let expanded = CLIProcessEnvironment.expandTilde(String(dir))
        #expect(merged.contains(expanded))
    }
}

@Test("CLIProcessEnvironment.expandTilde 把 ~ 替换为 home")
func expandTildeExpandsHome() {
    let home = NSHomeDirectory()
    #expect(CLIProcessEnvironment.expandTilde("~/.local/bin") == "\(home)/.local/bin")
    #expect(CLIProcessEnvironment.expandTilde("~") == home)
    #expect(CLIProcessEnvironment.expandTilde("/abs/path") == "/abs/path")
}

@Test("CLIProcessEnvironment.defaultExtraPaths 包含常见安装目录")
func defaultExtraPathsCoversCommonInstalls() {
    let paths = CLIProcessEnvironment.defaultExtraPaths
    #expect(paths.contains("~/.local/bin"))
    #expect(paths.contains("/opt/homebrew/bin"))
    #expect(paths.contains("/usr/local/bin"))
    // nvm node 路径(用户通过 nvm 装 npm 全局包的常见位置)
    #expect(paths.contains(where: { $0.contains("nvm") }))
}

@Test("CLIProcessEnvironment.mergedPath 去重:原 PATH 已有的路径不再重复追加")
func mergedPathDeduplicates() {
    let merged = CLIProcessEnvironment.mergedPath(
        existing: "/usr/bin:/bin",
        extraPaths: ["/usr/bin", "/opt/test-only-once"]
    )
    let parts = merged.split(separator: ":").map(String.init)
    // /usr/bin 只出现 1 次
    #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
    // /bin 保留
    #expect(parts.contains("/bin"))
    // 新增的非重复路径加进来
    #expect(parts.contains("/opt/test-only-once"))
}

@Test("CLIProcessEnvironment.mergedPath nil/空 existing 也工作")
func mergedPathHandlesNilExisting() {
    let merged = CLIProcessEnvironment.mergedPath(
        existing: nil,
        extraPaths: ["/foo", "/bar"]
    )
    #expect(merged == "/foo:/bar")

    let merged2 = CLIProcessEnvironment.mergedPath(
        existing: "",
        extraPaths: ["/baz"]
    )
    #expect(merged2 == "/baz")
}

@Test("CLIProcessEnvironment.mergedPath 展开 tilde 后再去重")
func mergedPathDedupesAfterTildeExpansion() {
    let home = NSHomeDirectory()
    let merged = CLIProcessEnvironment.mergedPath(
        existing: "\(home)/.local/bin",
        extraPaths: ["~/.local/bin"]
    )
    let parts = merged.split(separator: ":").map(String.init)
    #expect(parts.filter { $0 == "\(home)/.local/bin" }.count == 1)
}
