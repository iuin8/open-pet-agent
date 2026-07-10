import Foundation

public struct ProjectCapabilityCardState: Sendable, Equatable {
    public struct VisibleRow: Sendable, Equatable {
        public let rowID: Int
        public let item: Item
    }

    public enum Tab: String, Sendable, Equatable, CaseIterable {
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

    public init(selectedTab: Tab, items: [Item]) {
        self.selectedTab = selectedTab
        self.items = items
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
        case .skills: return item.kind == .skill
        case .mcp: return item.kind == .mcp
        case .profiles: return item.kind == .profile
        }
    }
}
