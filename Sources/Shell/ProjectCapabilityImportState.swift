import AgentMode
import Combine
import Foundation

public enum ProjectCapabilityImportOutcome: Sendable, Equatable {
    case snapshot(ProjectCapabilitySnapshot)
    case partial(
        projectID: String,
        plugin: CapabilityPlugin,
        items: [ProjectCapabilityCardState.Item]
    )
}

@MainActor
public final class ProjectCapabilityImportState: ObservableObject {
    @Published public private(set)
    var candidates: [ProjectCapabilityImportCandidate]
    @Published public private(set) var diagnostics: [ProjectConfigDiagnostic]
    @Published public private(set) var selectedIDs: Set<String>
    @Published public var focusedCandidateID: String?
    @Published public var pluginID = "imported-local"
    @Published public var pluginName = "Imported Local"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var didImport = false

    private let onImport:
        ([ProjectCapabilityImportCandidate], String, String)
            throws -> ProjectCapabilityImportOutcome
    private let onApply: (ProjectCapabilityImportOutcome) -> Void

    public init(
        scan: ProjectCapabilityImportScan,
        onImport: @escaping (
            [ProjectCapabilityImportCandidate], String, String
        ) throws -> ProjectCapabilityImportOutcome,
        onApply: @escaping (ProjectCapabilityImportOutcome) -> Void = { _ in }
    ) {
        candidates = scan.candidates
        diagnostics = scan.diagnostics
        selectedIDs = []
        focusedCandidateID = scan.candidates.first?.id
        self.onImport = onImport
        self.onApply = onApply
    }

    public var focusedCandidate: ProjectCapabilityImportCandidate? {
        candidates.first { $0.id == focusedCandidateID }
    }

    public var selectedCandidates: [ProjectCapabilityImportCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    public var canImport: Bool {
        !pluginID.isEmpty
            && !selectedCandidates.isEmpty
            && selectedCandidates.allSatisfy(\.diagnostics.isEmpty)
    }

    public func focus(_ id: String) {
        guard candidates.contains(where: { $0.id == id }) else { return }
        focusedCandidateID = id
    }

    public func toggleSelection(_ id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }),
              candidate.diagnostics.isEmpty else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    public func importSelected() {
        guard canImport else { return }
        do {
            let outcome = try onImport(
                selectedCandidates,
                pluginID,
                pluginName
            )
            onApply(outcome)
            selectedIDs.removeAll()
            didImport = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            didImport = false
        }
    }
}
