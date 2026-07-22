import AgentMode
import Foundation

public struct ProjectCapabilitySkillDraft: Sendable, Equatable {
    public enum Template: String, CaseIterable, Sendable {
        case blank
        case command
        case review

        public var title: String {
            switch self {
            case .blank: return "空白"
            case .command: return "命令助手"
            case .review: return "Review"
            }
        }

        public var description: String {
            switch self {
            case .blank: return "描述这个 Skill 的用途。"
            case .command: return "Run a focused project command and summarize the result."
            case .review: return "Review staged diffs before commit."
            }
        }

        public var body: String {
            switch self {
            case .blank:
                return "描述这个 Skill 应该如何工作。"
            case .command:
                return "Run the requested project command, read the output, and report actionable next steps."
            case .review:
                return "Inspect git diff and report correctness, safety, and maintainability issues before committing."
            }
        }
    }

    public var name: String
    public var description: String
    public var body: String

    public init(
        name: String = "code-review",
        description: String = Template.review.description,
        body: String = Template.review.body
    ) {
        self.name = name
        self.description = description
        self.body = body
    }

    public mutating func apply(_ template: Template) {
        description = template.description
        body = template.body
    }

    public var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var previewText: String {
        """
        ---
        name: \(name.trimmingCharacters(in: .whitespacesAndNewlines))
        description: \(description.trimmingCharacters(in: .whitespacesAndNewlines))
        ---

        # \(name.trimmingCharacters(in: .whitespacesAndNewlines))

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}

public struct ProjectCapabilityMCPDraft: Sendable, Equatable {
    public var transport: MCPTransport
    public var command: String
    public var arguments: String
    public var url: String
    public var environment: String
    public var cwd: String

    public init(
        transport: MCPTransport = .stdio,
        command: String = "npx",
        arguments: String = "-y\n@modelcontextprotocol/server-filesystem",
        url: String = "",
        environment: String = "",
        cwd: String = ""
    ) {
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environment = environment
        self.cwd = cwd
    }

    public func value() throws -> ACPJSON {
        switch transport {
        case .stdio:
            let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("stdio transport 必须填写 command")
            }
            return .object(try Self.withSharedFields(
                [
                    "type": .string("local"),
                    "command": .string(command),
                    "args": .array(Self.lines(arguments).map(ACPJSON.string)),
                    "enabled": .bool(true)
                ],
                environment: environment,
                cwd: cwd
            ))
        case .http, .sse:
            let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: value),
                  let scheme = parsed.scheme?.lowercased(),
                  parsed.host?.isEmpty == false,
                  scheme == "http" || scheme == "https" else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("http/sse transport 必须填写有效的 HTTP URL")
            }
            return .object(try Self.withSharedFields(
                [
                    "type": .string(transport.rawValue),
                    "url": .string(value),
                    "enabled": .bool(true)
                ],
                environment: environment,
                cwd: cwd
            ))
        }
    }

    public static func value(command: [String]) -> ACPJSON {
        let effective = command.isEmpty ? ["npx", "-y", "@modelcontextprotocol/server-filesystem"] : command
        let head = effective[0]
        let tail = effective.dropFirst().map(ACPJSON.string)
        var object: [String: ACPJSON] = [
            "type": .string("local"),
            "command": .string(head),
            "enabled": .bool(true)
        ]
        if !tail.isEmpty { object["args"] = .array(Array(tail)) }
        return .object(object)
    }

    public var previewText: String {
        let value = (try? value()) ?? .object([:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func withSharedFields(_ object: [String: ACPJSON], environment: String, cwd: String) throws -> [String: ACPJSON] {
        var result = object.filter { key, value in
            key != "args" || value != .array([])
        }
        let env = try parseEnvironment(environment)
        if !env.isEmpty { result["env"] = .object(env.mapValues(ACPJSON.string)) }
        let cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty { result["cwd"] = .string(cwd) }
        return result
    }

    private static func parseEnvironment(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(text) {
            guard let index = line.firstIndex(of: "="), index != line.startIndex else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("env 每行必须使用 KEY=VALUE 格式")
            }
            let key = String(line[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ProjectCapabilityMCPDetailError.invalidConfiguration("env 每行必须使用 KEY=VALUE 格式")
            }
            result[key] = value
        }
        return result
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
