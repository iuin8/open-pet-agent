import Foundation

public struct ProjectionPlan: Sendable, Equatable {
    public let projectID: String
    public let engineID: String
    public let pluginID: String
    public let operations: [ProjectionOperation]
    public let diagnostics: [ProjectConfigDiagnostic]

    public init(projectID: String, engineID: String, pluginID: String, operations: [ProjectionOperation], diagnostics: [ProjectConfigDiagnostic] = []) {
        self.projectID = projectID
        self.engineID = engineID
        self.pluginID = pluginID
        self.operations = operations
        self.diagnostics = diagnostics
    }
}

public enum ProjectionOperation: Sendable, Equatable {
    case writeFile(sourceDescription: String, destination: URL)
    case copyDirectory(source: URL, destination: URL)
    case symlinkDirectory(source: URL, destination: URL)
    case removeGenerated(URL)
}

public struct ProjectionState: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let projectID: String
    public let engineID: String
    public let pluginID: String
    public let pluginVersion: String?
    public let materializedAt: Date
    public let operations: [RecordedProjectionOperation]
    public let warnings: [String]

    public init(schemaVersion: Int, projectID: String, engineID: String, pluginID: String, pluginVersion: String?, materializedAt: Date, operations: [RecordedProjectionOperation], warnings: [String]) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.engineID = engineID
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.materializedAt = materializedAt
        self.operations = operations
        self.warnings = warnings
    }
}

public struct RecordedProjectionOperation: Codable, Sendable, Equatable {
    public let kind: String
    public let destinationPath: String
    public let sourcePath: String?

    public init(kind: String, destinationPath: String, sourcePath: String?) {
        self.kind = kind
        self.destinationPath = destinationPath
        self.sourcePath = sourcePath
    }
}

public enum ProjectionTrust {
    public static func isPath(_ path: URL, inside root: URL) -> Bool {
        let p = normalize(path)
        let r = normalize(root)
        return p == r || p.hasPrefix(r + "/")
    }

    private static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
