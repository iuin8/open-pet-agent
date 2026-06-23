import Foundation
import ShimejiImport

// 工作块 C Commit 2 —— Shimeji → petdex CLI 薄壳。核心编排在 `ShimejiPackConverter`。
//   shimeji-convert <Shimeji 包目录> [输出父目录] [--slug <slug>] [--name <显示名>]
// 默认输出 ~/.codex/pets/，转好即被 app 的 CodexSpritePackLoader.discover() 发现。

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

var positional: [String] = []
var slug: String?
var displayName: String?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--slug": slug = it.next()
    case "--name": displayName = it.next()
    case "-h", "--help":
        print("用法: shimeji-convert <Shimeji 包目录> [输出父目录] [--slug <slug>] [--name <显示名>]")
        print("默认输出 ~/.codex/pets/")
        exit(0)
    default: positional.append(arg)
    }
}

guard let packArg = positional.first else {
    fail("用法: shimeji-convert <Shimeji 包目录> [输出父目录] [--slug <slug>] [--name <显示名>]")
}
let packDir = URL(fileURLWithPath: packArg)
let outputParent = positional.count > 1
    ? URL(fileURLWithPath: positional[1])
    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/pets", isDirectory: true)

do {
    let outs = try ShimejiPackConverter.convert(
        packDir: packDir, outputParentDir: outputParent, slug: slug, displayName: displayName)
    for out in outs { print("✅ 已转换 → \(out.path)") }
    if outs.count > 1 {
        print("   (检测到 \(outs.count) 个角色,各转一个包;--slug/--name 多角色时忽略,按目录名推导)")
    }
    print("   重启 OpenPetAgent 即可在形象列表看到（CodexSpritePackLoader 自动发现）。")
} catch ShimejiPackConverter.ConvertError.noFramesFound {
    fail("✗ 在 \(packDir.path) 找不到 shimeN.png（确认是 Shimeji 包目录：含 img/<角色>/shime1.png）")
} catch {
    fail("✗ 转换失败：\(error)")
}
