import Foundation

public struct ProjectConfigDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable, Codable {
        case info, warning, error
    }

    public let severity: Severity
    public let message: String
    public let path: String?

    public init(severity: Severity, message: String, path: String? = nil) {
        self.severity = severity
        self.message = message
        self.path = path
    }
}
