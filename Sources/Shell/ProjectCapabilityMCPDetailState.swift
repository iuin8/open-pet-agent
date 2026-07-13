import AgentMode
import Combine
import Foundation

public enum ProjectCapabilityMCPDetailError: Error, LocalizedError {
    case savingUnavailable
    case invalidRawJSON
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .savingUnavailable: return "当前 MCP server 无法保存"
        case .invalidRawJSON: return "Advanced JSON 必须是一个有效的 JSON object"
        case .invalidConfiguration(let message): return message
        }
    }
}

@MainActor
public final class ProjectCapabilityMCPDetailState: ObservableObject {
    public enum EditorMode: String, CaseIterable, Sendable {
        case basic = "Basic"
        case raw = "Advanced JSON"
    }

    @Published public private(set) var server: CapabilityMCPServer
    @Published public private(set) var isEditing = false
    @Published public private(set) var isDeleted = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var editorMode: EditorMode = .basic
    @Published public var draftTransport: MCPTransport
    @Published public var draftCommand: String
    @Published public var draftArguments: String
    @Published public var draftURL: String
    @Published public var draftEnvironment: String
    @Published public var draftCWD: String
    @Published public var draftRawJSON: String

    public let pluginID: String
    public let sourcePath: String
    private let onSave: (ACPJSON) throws -> CapabilityMCPServer
    private let onDelete: () throws -> Void

    public init(
        pluginID: String,
        sourcePath: String,
        server: CapabilityMCPServer,
        onSave: @escaping (ACPJSON) throws -> CapabilityMCPServer,
        onDelete: @escaping () throws -> Void = { throw ProjectCapabilityMCPDetailError.savingUnavailable }
    ) {
        self.pluginID = pluginID
        self.sourcePath = sourcePath
        self.server = server
        self.onSave = onSave
        self.onDelete = onDelete
        self.draftTransport = server.transport
        self.draftCommand = server.command.first ?? ""
        self.draftArguments = server.command.dropFirst().joined(separator: "\n")
        self.draftURL = server.url ?? ""
        self.draftEnvironment = Self.environmentText(server.env)
        self.draftCWD = server.cwd ?? ""
        self.draftRawJSON = server.rawJSON ?? "{}"
    }

    public func beginEditing() {
        resetDrafts()
        isEditing = true
    }

    public func cancelEditing() {
        resetDrafts()
        isEditing = false
    }

    public func selectEditorMode(_ mode: EditorMode) {
        guard mode != editorMode else { return }
        do {
            switch mode {
            case .basic:
                let value = try rawValue()
                try populateBasic(from: value)
            case .raw:
                draftRawJSON = try Self.encode(basicValue())
            }
            editorMode = mode
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func save() {
        do {
            let value = try editorMode == .raw ? rawValue() : basicValue()
            server = try onSave(value)
            resetDrafts()
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete() {
        do {
            try onDelete()
            isDeleted = true
            isEditing = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetDrafts() {
        editorMode = .basic
        draftTransport = server.transport
        draftCommand = server.command.first ?? ""
        draftArguments = server.command.dropFirst().joined(separator: "\n")
        draftURL = server.url ?? ""
        draftEnvironment = Self.environmentText(server.env)
        draftCWD = server.cwd ?? ""
        draftRawJSON = server.rawJSON ?? "{}"
        errorMessage = nil
    }

    private func basicValue() throws -> ACPJSON {
        var object = ACPJSON.parse(draftRawJSON)?.objectValue
            ?? ACPJSON.parse(server.rawJSON ?? "")?.objectValue
            ?? [:]
        let env = try Self.parseEnvironment(draftEnvironment)
        let cwd = draftCWD.trimmingCharacters(in: .whitespacesAndNewlines)

        switch draftTransport {
        case .stdio:
            let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("stdio transport 必须填写 command")
            }
            object["type"] = .string("local")
            object.removeValue(forKey: "transport")
            object["command"] = .string(command)
            let args = Self.lines(draftArguments)
            if args.isEmpty { object.removeValue(forKey: "args") }
            else { object["args"] = .array(args.map(ACPJSON.string)) }
            object.removeValue(forKey: "url")
        case .http, .sse:
            let url = try Self.validRemoteURL(draftURL)
            object["type"] = .string(draftTransport.rawValue)
            object.removeValue(forKey: "transport")
            object["url"] = .string(url)
            object.removeValue(forKey: "command")
            object.removeValue(forKey: "args")
        }

        if env.isEmpty { object.removeValue(forKey: "env") }
        else { object["env"] = .object(env.mapValues(ACPJSON.string)) }
        if cwd.isEmpty { object.removeValue(forKey: "cwd") }
        else { object["cwd"] = .string(cwd) }
        return .object(object)
    }

    private func rawValue() throws -> ACPJSON {
        guard let value = ACPJSON.parse(draftRawJSON), value.objectValue != nil else {
            throw ProjectCapabilityMCPDetailError.invalidRawJSON
        }
        try Self.validate(value)
        return value
    }

    private func populateBasic(from value: ACPJSON) throws {
        guard let object = value.objectValue else {
            throw ProjectCapabilityMCPDetailError.invalidRawJSON
        }
        let transport = try Self.transport(for: object)
        draftTransport = transport
        if transport == .stdio {
            let command = try Self.commandParts(object)
            draftCommand = command[0]
            draftArguments = command.dropFirst().joined(separator: "\n")
            draftURL = ""
        } else {
            draftCommand = ""
            draftArguments = ""
            draftURL = try Self.validRemoteURL(object["url"]?.stringValue ?? "")
        }
        draftEnvironment = Self.environmentText(try Self.environment(object["env"]))
        draftCWD = object["cwd"]?.stringValue ?? ""
    }

    static func updatedServer(_ server: CapabilityMCPServer, with value: ACPJSON) throws -> CapabilityMCPServer {
        try validate(value)
        let object = value.objectValue ?? [:]
        let transport = try transport(for: object)
        var refreshed = server
        refreshed.transport = transport
        refreshed.command = transport == .stdio ? try commandParts(object) : []
        refreshed.url = transport == .stdio ? nil : try validRemoteURL(object["url"]?.stringValue ?? "")
        refreshed.env = try environment(object["env"])
        refreshed.cwd = object["cwd"]?.stringValue
        refreshed.rawJSON = try encode(value)
        return refreshed
    }

    private static func validate(_ value: ACPJSON) throws {
        guard let object = value.objectValue else {
            throw ProjectCapabilityMCPDetailError.invalidRawJSON
        }
        let transport = try transport(for: object)
        if transport == .stdio {
            guard object["url"] == nil else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("stdio transport 不能包含 URL")
            }
            _ = try commandParts(object)
        } else {
            _ = try validRemoteURL(object["url"]?.stringValue ?? "")
        }
        _ = try environment(object["env"])
        if let cwd = object["cwd"], cwd.stringValue == nil {
            throw ProjectCapabilityMCPDetailError.invalidConfiguration("cwd 必须是字符串")
        }
    }

    private static func transport(for object: [String: ACPJSON]) throws -> MCPTransport {
        let raw = object["type"]?.stringValue ?? object["transport"]?.stringValue
        switch raw {
        case "local", "stdio": return .stdio
        case "http": return .http
        case "sse": return .sse
        case nil: return object["url"] == nil ? .stdio : .http
        default: throw ProjectCapabilityMCPDetailError.invalidConfiguration("transport 只支持 stdio、http 或 sse")
        }
    }

    private static func commandParts(_ object: [String: ACPJSON]) throws -> [String] {
        var command: [String]
        if let value = object["command"]?.stringValue, !value.isEmpty {
            command = [value]
        } else if let values = object["command"]?.arrayValue {
            command = values.compactMap(\.stringValue)
            guard command.count == values.count, !command.isEmpty else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("stdio transport 的 command 格式无效")
            }
        } else {
            throw ProjectCapabilityMCPDetailError.invalidConfiguration("stdio transport 必须填写 command")
        }
        if let values = object["args"]?.arrayValue {
            let args = values.compactMap(\.stringValue)
            guard args.count == values.count else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("args 必须是字符串数组")
            }
            command.append(contentsOf: args)
        }
        return command
    }

    private static func validRemoteURL(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty,
              scheme == "http" || scheme == "https" else {
            throw ProjectCapabilityMCPDetailError.invalidConfiguration("http/sse transport 必须填写有效的 HTTP URL")
        }
        return value
    }

    private static func parseEnvironment(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(text) {
            guard let separator = line.firstIndex(of: "="), separator != line.startIndex else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("env 每行必须使用 KEY=VALUE 格式")
            }
            result[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return result
    }

    private static func environment(_ value: ACPJSON?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let object = value.objectValue else {
            throw ProjectCapabilityMCPDetailError.invalidConfiguration("env 必须是字符串 object")
        }
        let result = object.compactMapValues(\.stringValue)
        guard result.count == object.count else {
            throw ProjectCapabilityMCPDetailError.invalidConfiguration("env 的值必须是字符串")
        }
        return result
    }

    private static func environmentText(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private static func encode(_ value: ACPJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }
}
