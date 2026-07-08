import Foundation

public struct ProjectCapabilityDiagnosticSection: Sendable, Equatable {
    public let engineName: String
    public let plans: [ProjectionPlan]
    public let errorDescription: String?

    public init(engineName: String, plans: [ProjectionPlan], errorDescription: String? = nil) {
        self.engineName = engineName
        self.plans = plans
        self.errorDescription = errorDescription
    }
}

public enum ProjectCapabilityDiagnostics {
    public static func render(_ sections: [ProjectCapabilityDiagnosticSection]) -> String {
        sections.map(render).joined(separator: "\n\n")
    }

    private static func render(_ section: ProjectCapabilityDiagnosticSection) -> String {
        var lines = ["【\(section.engineName)】"]
        if let error = section.errorDescription {
            lines.append("失败: \(error)")
            return lines.joined(separator: "\n")
        }

        let operations = section.plans.flatMap(\.operations)
        if operations.isEmpty {
            lines.append("无计划写入")
        } else {
            lines.append("ownership: OpenPetAgent 生成内容；遇到用户自有内容由 materializer fail-closed")
            lines.append(contentsOf: operations.map(render))
        }

        let diagnostics = section.plans.flatMap(\.diagnostics)
        if !diagnostics.isEmpty {
            lines.append("诊断:")
            lines.append(contentsOf: diagnostics.map { diagnostic in
                let path = diagnostic.path.map { " (\($0))" } ?? ""
                return "- \(diagnostic.severity.rawValue): \(diagnostic.message)\(path)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ operation: ProjectionOperation) -> String {
        switch operation {
        case .writeFile(_, let destination):
            return "写入生成文件: \(destination.path)"
        case .copyDirectory(let source, let destination):
            return "复制生成目录: \(source.path) → \(destination.path)"
        case .symlinkDirectory(let source, let destination):
            return "链接生成目录: \(source.path) → \(destination.path)"
        case .removeGenerated(let url):
            return "移除生成内容: \(url.path)"
        }
    }
}
