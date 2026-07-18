import Foundation

enum ProjectCapabilityMCPHealth {
    static func diagnostics(name: String, value: ACPJSON, pluginRoot: URL, environment: [String: String] = CLIProcessEnvironment.augmented()) -> [ProjectConfigDiagnostic] {
        guard let object = value.objectValue else { return [] }
        let transport = object["type"]?.stringValue ?? object["transport"]?.stringValue
        switch transport {
        case "http", "sse":
            return remoteDiagnostics(name: name, object: object, path: pluginRoot.path)
        default:
            return object["url"]?.stringValue == nil
                ? stdioDiagnostics(name: name, value: value, object: object, pluginRoot: pluginRoot, environment: environment)
                : remoteDiagnostics(name: name, object: object, path: pluginRoot.path)
        }
    }

    static func hasMalformedRemoteURL(_ value: ACPJSON) -> Bool {
        guard let object = value.objectValue else { return false }
        let transport = object["type"]?.stringValue ?? object["transport"]?.stringValue
        guard transport == "http" || transport == "sse" || (transport == nil && object["url"]?.stringValue != nil) else {
            return false
        }
        return !ProjectCapabilityMCPResolver.validRemoteURL(object["url"]?.stringValue)
    }

    private static func remoteDiagnostics(name: String, object: [String: ACPJSON], path: String?) -> [ProjectConfigDiagnostic] {
        ProjectCapabilityMCPResolver.validRemoteURL(object["url"]?.stringValue)
            ? []
            : [.warning("MCP URL malformed: \(name) — 修正为 http(s) URL，例如 https://host/path", path: path)]
    }

    private static func stdioDiagnostics(name: String, value: ACPJSON, object: [String: ACPJSON], pluginRoot: URL, environment: [String: String]) -> [ProjectConfigDiagnostic] {
        var diagnostics: [ProjectConfigDiagnostic] = []
        let cwd = object["cwd"]?.stringValue
        if let command = ProjectCapabilityMCPResolver.commandParts(for: value)?.first, !commandExists(command, cwd: cwd, pluginRoot: pluginRoot, environment: environment) {
            diagnostics.append(.warning("MCP command not found: \(name) — 安装命令或改成绝对路径: \(command)", path: pluginRoot.path))
        }
        if let cwd, !cwd.isEmpty, !directoryExists(cwd, pluginRoot: pluginRoot) {
            diagnostics.append(.warning("MCP cwd missing: \(name) — 创建目录或修正 cwd: \(cwd)", path: pluginRoot.path))
        }
        if object["args"]?.arrayValue?.isEmpty == true {
            diagnostics.append(.warning("MCP args empty: \(name) — 添加参数或移除空 args", path: pluginRoot.path))
        }
        let missingEnvKeys = object["env"]?.objectValue?
            .compactMap { key, value in value.stringValue?.isEmpty == true ? key : nil }
            .sorted() ?? []
        if !missingEnvKeys.isEmpty {
            diagnostics.append(.warning("MCP env missing: \(name) \(missingEnvKeys.joined(separator: ", ")) — 填写 env 值或移除空 key", path: pluginRoot.path))
        }
        return diagnostics
    }

    private static func commandExists(_ command: String, cwd: String?, pluginRoot: URL, environment: [String: String]) -> Bool {
        if command.contains("/") {
            let url = commandURL(command, cwd: cwd, pluginRoot: pluginRoot)
            return FileManager.default.isExecutableFile(atPath: url.path)
        }
        let paths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return paths.contains { dir in
            FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: dir).appendingPathComponent(command).path)
        }
    }

    private static func commandURL(_ command: String, cwd: String?, pluginRoot: URL) -> URL {
        if command.hasPrefix("/") { return URL(fileURLWithPath: command) }
        let base = cwd.map { directoryURL($0, pluginRoot: pluginRoot) } ?? pluginRoot
        return base.appendingPathComponent(command)
    }

    private static func directoryExists(_ raw: String, pluginRoot: URL) -> Bool {
        let url = directoryURL(raw, pluginRoot: pluginRoot)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func directoryURL(_ raw: String, pluginRoot: URL) -> URL {
        raw.hasPrefix("/") ? URL(fileURLWithPath: raw, isDirectory: true) : pluginRoot.appendingPathComponent(raw, isDirectory: true)
    }
}
