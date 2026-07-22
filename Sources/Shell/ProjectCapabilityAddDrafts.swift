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
    public var rawJSON: String

    public init(rawJSON: String = Self.defaultRawJSON) {
        self.rawJSON = rawJSON
    }

    public func value() throws -> ACPJSON {
        guard let value = ACPJSON.parse(rawJSON), value.objectValue != nil else {
            throw ProjectCapabilityMCPDetailError.invalidRawJSON
        }
        try ProjectCapabilityMCPDetailState.validateCreationValue(value)
        return value
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
        guard let value = try? value() else { return rawJSON }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return rawJSON }
        return text
    }

    public var errorMessage: String? {
        do {
            _ = try value()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static let defaultRawJSON = """
    {
      "type": "local",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"],
      "enabled": true
    }
    """
}
