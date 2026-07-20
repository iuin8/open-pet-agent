import Foundation
import AgentMode

public struct ProjectCapabilityCardState: Sendable, Equatable {
    public struct SyncPreview: Sendable, Equatable {
        public let target: CapabilityTarget
        public let operationSummaries: [String]
        public let diagnosticSummaries: [String]
        public let failureMessage: String?

        public init(
            target: CapabilityTarget,
            operationSummaries: [String],
            diagnosticSummaries: [String],
            failureMessage: String?
        ) {
            self.target = target
            self.operationSummaries = operationSummaries
            self.diagnosticSummaries = diagnosticSummaries
            self.failureMessage = failureMessage
        }
    }

    public struct ProjectionTargetState: Sendable, Equatable {
        public let target: CapabilityTarget
        public let isEnabled: Bool

        public init(target: CapabilityTarget, isEnabled: Bool) {
            self.target = target
            self.isEnabled = isEnabled
        }
    }
    public struct AuditSummary: Sendable, Equatable {
        public let lastValidationDescription: String?
        public let lastSyncDescription: String?
        public let warningCount: Int
        public let errorCount: Int
        public let backupCount: Int

        public init(
            lastValidationDescription: String? = nil,
            lastSyncDescription: String? = nil,
            warningCount: Int = 0,
            errorCount: Int = 0,
            backupCount: Int = 0
        ) {
            self.lastValidationDescription = lastValidationDescription
            self.lastSyncDescription = lastSyncDescription
            self.warningCount = warningCount
            self.errorCount = errorCount
            self.backupCount = backupCount
        }

        public var statusText: String {
            if errorCount > 0 { return "\(errorCount) 个错误" }
            if warningCount > 0 { return "\(warningCount) 个警告" }
            return "doctor 正常"
        }
    }

    public struct VisibleRow: Sendable, Equatable {
        public let rowID: Int
        public let item: Item
    }

    public enum Tab: String, Sendable, Equatable, CaseIterable {
        case overview
        case skills
        case mcp
        case profiles
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case skill
            case mcp
            case profile
        }

        public enum Status: Sendable, Equatable {
            case enabled
            case disabled
            case warning
            case failed
        }

        public let id: String
        public let kind: Kind
        public let name: String
        public let pluginID: String
        public let sourcePath: String
        public let targetPaths: [String]
        public let sourceProvenance: String?
        public let sourceTrust: String?
        public let targets: [ProjectionTargetState]
        public let isEnabled: Bool
        public let status: Status
        public let diagnostics: [ProjectCapabilityPanelState.Diagnostic]

        public init(
            id: String,
            kind: Kind,
            name: String,
            pluginID: String,
            sourcePath: String,
            targetPaths: [String],
            sourceProvenance: String? = nil,
            sourceTrust: String? = nil,
            targets: [ProjectionTargetState] = [],
            isEnabled: Bool = true,
            status: Status,
            diagnostics: [ProjectCapabilityPanelState.Diagnostic]
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.pluginID = pluginID
            self.sourcePath = sourcePath
            self.targetPaths = targetPaths
            self.sourceProvenance = sourceProvenance
            self.sourceTrust = sourceTrust
            self.targets = targets
            self.isEnabled = isEnabled
            self.status = status
            self.diagnostics = diagnostics
        }

        public var copyText: String {
            guard !targetPaths.isEmpty else { return sourcePath }
            return targetPaths.map { "\(sourcePath) → \($0)" }.joined(separator: "\n")
        }

        public var nextEnabledValue: Bool { !isEnabled }
    }

    public let selectedTab: Tab
    public let items: [Item]
    public let auditSummary: AuditSummary?
    public let syncPreview: SyncPreview?

    public init(
        selectedTab: Tab,
        items: [Item],
        auditSummary: AuditSummary? = nil,
        syncPreview: SyncPreview? = nil
    ) {
        self.selectedTab = selectedTab
        self.items = items
        self.auditSummary = auditSummary
        self.syncPreview = syncPreview
    }

    public var visibleRows: [VisibleRow] {
        items.enumerated().compactMap { rowID, item in
            isVisible(item) ? VisibleRow(rowID: rowID, item: item) : nil
        }
    }

    public var visibleItems: [Item] {
        visibleRows.map(\.item)
    }

    private func isVisible(_ item: Item) -> Bool {
        switch selectedTab {
        case .overview: return true
        case .skills: return item.kind == .skill
        case .mcp: return item.kind == .mcp
        case .profiles: return item.kind == .profile
        }
    }
}
