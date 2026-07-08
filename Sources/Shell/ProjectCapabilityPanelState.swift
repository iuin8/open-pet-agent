import Foundation

public struct ProjectCapabilityPanelState: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case ready
            case warning
            case failed
            case empty
        }

        public let engineName: String
        public let status: Status
        public let ownership: String?
        public let rows: [Row]
        public let diagnostics: [Diagnostic]

        public init(engineName: String, status: Status, ownership: String?, rows: [Row], diagnostics: [Diagnostic]) {
            self.engineName = engineName
            self.status = status
            self.ownership = ownership
            self.rows = rows
            self.diagnostics = diagnostics
        }
    }

    public struct Row: Sendable, Equatable {
        public let kind: String
        public let target: String
        public let detail: String?
        public let copyText: String

        public init(kind: String, target: String, detail: String?, copyText: String) {
            self.kind = kind
            self.target = target
            self.detail = detail
            self.copyText = copyText
        }
    }

    public struct Diagnostic: Sendable, Equatable {
        public let severity: String
        public let message: String
        public let path: String?

        public init(severity: String, message: String, path: String?) {
            self.severity = severity
            self.message = message
            self.path = path
        }
    }

    public let fullText: String
    public let sections: [Section]

    public init(fullText: String, sections: [Section]) {
        self.fullText = fullText
        self.sections = sections
    }
}
