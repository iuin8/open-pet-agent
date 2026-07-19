import Foundation

public struct ProjectCapabilityImportScanner: Sendable {
    public init() {}

    public func scan(project: AgentProject) -> ProjectCapabilityImportScan {
        var scan = ProjectCapabilityImportScan()
        scanSkills(project: project, relativeRoot: ".claude/skills", sourceKind: .claudeSkill, scan: &scan)
        scanSkills(project: project, relativeRoot: ".agents/skills", sourceKind: .agentsSkill, scan: &scan)
        scanSkills(project: project, relativeRoot: ".opencode/skills", sourceKind: .opencodeSkill, scan: &scan)
        scanJSONMCP(project: project, scan: &scan)
        scanCodexMCP(project: project, scan: &scan)
        scanOpencodeMCP(project: project, scan: &scan)
        scan.candidates = markConflicts(mergeIdentical(scan.candidates))
        scan.candidates.sort {
            ($0.kind.rawValue, $0.name, $0.id) < ($1.kind.rawValue, $1.name, $1.id)
        }
        return scan
    }

    private func scanSkills(
        project: AgentProject,
        relativeRoot: String,
        sourceKind: ProjectCapabilityImportSourceKind,
        scan: inout ProjectCapabilityImportScan
    ) {
        let projectRoot = project.rootURL.standardizedFileURL
        let resolvedProjectRoot = projectRoot.resolvingSymlinksInPath()
        let skillsRoot = projectRoot
            .appendingPathComponent(relativeRoot, isDirectory: true)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: skillsRoot.path) else {
            return
        }
        let resolvedSkillsRoot = skillsRoot.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(skillsRoot, inside: projectRoot),
              ProjectionTrust.isPath(
                  resolvedSkillsRoot,
                  inside: resolvedProjectRoot
              ) else {
            scan.diagnostics.append(.error(
                "Import source escapes project: \(relativeRoot)",
                path: skillsRoot.path
            ))
            return
        }
        guard (try? resolvedSkillsRoot.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) == true else {
            scan.diagnostics.append(.error(
                "Unable to read import source: \(relativeRoot)",
                path: skillsRoot.path
            ))
            return
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: resolvedSkillsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            scan.diagnostics.append(.error(
                "Unable to read import source: \(relativeRoot)",
                path: skillsRoot.path
            ))
            return
        }

        for directory in children.sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            let resolved = directory.resolvingSymlinksInPath()
            guard ProjectionTrust.isPath(resolved, inside: resolvedProjectRoot) else {
                scan.diagnostics.append(.error(
                    "Import source escapes project: \(directory.lastPathComponent)",
                    path: directory.path
                ))
                continue
            }
            guard (try? resolved.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true else { continue }
            scanSkill(
                directory: directory,
                resolved: resolved,
                sourceKind: sourceKind,
                projectRoot: project.rootURL,
                scan: &scan
            )
        }
    }

    private func scanSkill(
        directory: URL,
        resolved: URL,
        sourceKind: ProjectCapabilityImportSourceKind,
        projectRoot: URL,
        scan: inout ProjectCapabilityImportScan
    ) {
        // 跳过 PetAgent 自身生成的投影(清单 ∪ 旧版 marker),避免同步后重复导入。
        if ProjectionGeneratedManifestStore.isGeneratedTarget(resolved, projectRoot: projectRoot) {
            return
        }
        do {
            let files = try skillFiles(in: resolved)
            guard let skillData = files.first(where: {
                $0.relativePath == "SKILL.md"
            })?.contents,
                  let body = String(data: skillData, encoding: .utf8) else {
                throw ProjectCapabilityValidationError(
                    "Missing import skill: \(directory.lastPathComponent)"
                )
            }
            let name = directory.lastPathComponent
            scan.candidates.append(ProjectCapabilityImportCandidate(
                id: "skill:\(name):\(sourceKind.rawValue)",
                kind: .skill,
                name: name,
                sources: [ProjectCapabilityImportSource(
                    kind: sourceKind,
                    url: resolved.appendingPathComponent("SKILL.md")
                )],
                skillBody: body,
                skillFiles: files
            ))
        } catch let error as ProjectCapabilityValidationError {
            scan.diagnostics.append(.error(error.message, path: directory.path))
        } catch {
            scan.diagnostics.append(.error(
                "Malformed import skill: \(directory.lastPathComponent)",
                path: directory.path
            ))
        }
    }

    private func scanJSONMCP(
        project: AgentProject,
        scan: inout ProjectCapabilityImportScan
    ) {
        let projectRoot = project.rootURL.standardizedFileURL
        let url = projectRoot.appendingPathComponent(
            ".mcp.json",
            isDirectory: false
        ).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard !ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot) else {
            return
        }
        let resolvedURL = url.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(url, inside: projectRoot),
              ProjectionTrust.isPath(
                  resolvedURL,
                  inside: projectRoot.resolvingSymlinksInPath()
              ) else {
            scan.diagnostics.append(.error(
                "Import source escapes project: .mcp.json",
                path: url.path
            ))
            return
        }
        do {
            let root = try JSONDecoder().decode(
                ACPJSON.self,
                from: Data(contentsOf: resolvedURL)
            )
            guard let servers = root.objectValue?["mcpServers"]?.objectValue else {
                throw ProjectCapabilityValidationError("Malformed MCP import file: .mcp.json")
            }
            for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                guard ProjectCapabilityMCPResolver.isValidConfiguration(value) else {
                    scan.diagnostics.append(.error(
                        "Malformed MCP import: \(name)",
                        path: url.path
                    ))
                    continue
                }
                scan.candidates.append(ProjectCapabilityImportCandidate(
                    id: "mcp:\(name):claude",
                    kind: .mcp,
                    name: name,
                    sources: [.init(kind: .claudeMCP, url: url)],
                    mcpValue: value
                ))
            }
        } catch {
            scan.diagnostics.append(.error(
                "Malformed MCP import file: .mcp.json",
                path: url.path
            ))
        }
    }

    private func scanCodexMCP(
        project: AgentProject,
        scan: inout ProjectCapabilityImportScan
    ) {
        let projectRoot = project.rootURL.standardizedFileURL
        let url = projectRoot.appendingPathComponent(
            ".codex/config.toml",
            isDirectory: false
        ).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let resolvedURL = url.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(url, inside: projectRoot),
              ProjectionTrust.isPath(
                  resolvedURL,
                  inside: projectRoot.resolvingSymlinksInPath()
              ) else {
            scan.diagnostics.append(.error(
                "Import source escapes project: .codex/config.toml",
                path: url.path
            ))
            return
        }
        let text: String
        do {
            text = try String(contentsOf: resolvedURL, encoding: .utf8)
        } catch {
            scan.diagnostics.append(.error(
                "Unable to read import source: .codex/config.toml",
                path: url.path
            ))
            return
        }
        guard !ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot) else { return }
        do {
            for (name, value) in try CodexMCPImportParser.parse(text) {
                scan.candidates.append(ProjectCapabilityImportCandidate(
                    id: "mcp:\(name):codex",
                    kind: .mcp,
                    name: name,
                    sources: [.init(kind: .codexMCP, url: url)],
                    mcpValue: value
                ))
            }
        } catch let error as ProjectCapabilityValidationError {
            scan.diagnostics.append(.error(error.message, path: url.path))
        } catch {
            scan.diagnostics.append(.error(
                "Malformed MCP import file: .codex/config.toml",
                path: url.path
            ))
        }
    }

    private func scanOpencodeMCP(
        project: AgentProject,
        scan: inout ProjectCapabilityImportScan
    ) {
        let projectRoot = project.rootURL.standardizedFileURL
        let url = projectRoot.appendingPathComponent(
            "opencode.json",
            isDirectory: false
        ).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard !ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot) else {
            return
        }
        let resolvedURL = url.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(url, inside: projectRoot),
              ProjectionTrust.isPath(
                  resolvedURL,
                  inside: projectRoot.resolvingSymlinksInPath()
              ) else {
            scan.diagnostics.append(.error(
                "Import source escapes project: opencode.json",
                path: url.path
            ))
            return
        }
        do {
            let root = try JSONDecoder().decode(
                ACPJSON.self,
                from: Data(contentsOf: resolvedURL)
            )
            guard let object = root.objectValue else {
                throw ProjectCapabilityValidationError("Malformed MCP import file: opencode.json")
            }
            guard let mcp = object["mcp"] else { return }
            guard let servers = mcp.objectValue else {
                throw ProjectCapabilityValidationError("Malformed MCP import file: opencode.json")
            }
            for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                guard ProjectCapabilityMCPResolver.isValidConfiguration(value) else {
                    scan.diagnostics.append(.error(
                        "Malformed MCP import: \(name)",
                        path: url.path
                    ))
                    continue
                }
                scan.candidates.append(ProjectCapabilityImportCandidate(
                    id: "mcp:\(name):opencode",
                    kind: .mcp,
                    name: name,
                    sources: [.init(kind: .opencodeMCP, url: url)],
                    mcpValue: value
                ))
            }
        } catch {
            scan.diagnostics.append(.error(
                "Malformed MCP import file: opencode.json",
                path: url.path
            ))
        }
    }

    private func skillFiles(
        in root: URL
    ) throws -> [ProjectCapabilityImportFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw ProjectCapabilityValidationError(
                "Malformed import skill: \(root.lastPathComponent)"
            )
        }
        var files: [ProjectCapabilityImportFile] = []
        let rootComponents = root.standardizedFileURL.pathComponents
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw ProjectCapabilityValidationError(
                    "Import skill contains symbolic link: \(root.lastPathComponent)"
                )
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw ProjectCapabilityValidationError(
                    "Import skill contains unsupported file: \(root.lastPathComponent)"
                )
            }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            guard !relative.isEmpty,
                  ProjectionTrust.isPath(url.standardizedFileURL, inside: root) else {
                throw ProjectCapabilityValidationError(
                    "Import skill escapes project: \(root.lastPathComponent)"
                )
            }
            files.append(.init(
                relativePath: relative,
                contents: try Data(contentsOf: url)
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func markConflicts(
        _ candidates: [ProjectCapabilityImportCandidate]
    ) -> [ProjectCapabilityImportCandidate] {
        let counts = Dictionary(grouping: candidates) {
            "\($0.kind.rawValue):\($0.name)"
        }.mapValues(\.count)
        return candidates.map { candidate in
            var candidate = candidate
            if counts["\(candidate.kind.rawValue):\(candidate.name)", default: 0] > 1 {
                candidate.diagnostics.append(.error(
                    "Conflicting import: \(candidate.name)",
                    path: candidate.sources.first?.url.path
                ))
            }
            return candidate
        }
    }

    private func mergeIdentical(
        _ candidates: [ProjectCapabilityImportCandidate]
    ) -> [ProjectCapabilityImportCandidate] {
        var merged: [ProjectCapabilityImportCandidate] = []
        for candidate in candidates {
            if let index = merged.firstIndex(where: {
                $0.kind == candidate.kind
                    && $0.name == candidate.name
                    && $0.skillBody == candidate.skillBody
                    && $0.skillFiles == candidate.skillFiles
                    && $0.mcpValue == candidate.mcpValue
            }) {
                merged[index].sources.append(contentsOf: candidate.sources)
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }
}
