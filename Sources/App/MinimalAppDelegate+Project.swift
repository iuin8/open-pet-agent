import AppKit
import AgentMode
import Shell

enum ProjectCapabilityManagerError: Error, Equatable, CustomStringConvertible {
    case invalidPluginID(String)
    case invalidManifest(String)

    var description: String {
        switch self {
        case .invalidPluginID(let pluginID): return "无效项目能力 plugin id: \(pluginID)"
        case .invalidManifest(let pluginID): return "无效项目能力 manifest: \(pluginID)"
        }
    }
}

// MARK: - 项目配置(P1b 多项目 UI 接线 + P1c 外部项目/删除/重命名)

extension MinimalAppDelegate {

    /// P3:建前台 project 检测器 + NSWorkspace notification(前台 app 切换 → 检测 cwd → 自动切 project)。
    @MainActor func setupFrontmostProjectDetector() {
        let detector = FrontmostProjectDetector(defaults: userDefaults, router: agentModeRouter)
        frontmostProjectDetector = detector
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in detector.detect() }
        }
    }

    /// 注入项目配置 provider + 切换/创建/删除回调到 chat card(P1b/P1c 多项目 UI)。
    ///
    /// mirror `replyConfiguration` 注入模式:`ProjectStore.current()` 派生 current + `list()` 派生列表,
    /// 切项目 → 写 UD + 重 apply engine;创建(托管/外部)→ NSAlert/NSOpenPanel + create + 刷新;
    /// 重命名/删除 → NSAlert + rename/delete + 刷新。详见 `docs/project-config-architecture-design.md`。
    @MainActor func wireProjectConfiguration(to cardCtrl: ChatCardWindowController) {
        cardCtrl.projectProvider = { [weak self] in
            let defaults = self?.userDefaults ?? .standard
            let current = ProjectStore.current(defaults: defaults)
            let projects = ProjectStore.list()
            return (
                current: ProjectOption(id: current.id, name: current.name, isExternal: current.isExternal),
                projects: projects.map { ProjectOption(id: $0.id, name: $0.name, isExternal: $0.isExternal) }
            )
        }
        cardCtrl.onCommitProject = { [weak self] id in
            guard let self else { return }
            ProjectStore.setCurrent(id, defaults: self.userDefaults)
            Self.applySelectedAgentEngine(to: self.agentModeRouter, defaults: self.userDefaults)
            self.wireACPPermissionHandler()
            self.frontmostProjectDetector?.reset()  // P3:手动切后 reset,避免 detector 切回
        }
        cardCtrl.onRequestCreateProject = { [weak self, weak cardCtrl] in
            self?.promptForProjectNameAndCreate(refresh: { cardCtrl?.refreshProjectConfiguration() })
        }
        cardCtrl.onRequestCreateExternal = { [weak self, weak cardCtrl] in
            self?.promptForExternalProjectAndCreate(refresh: { cardCtrl?.refreshProjectConfiguration() })
        }
        cardCtrl.onRequestRenameCurrent = { [weak self, weak cardCtrl] in
            self?.promptForRenameCurrentProject(refresh: { cardCtrl?.refreshProjectConfiguration() })
        }
        cardCtrl.onRequestDeleteCurrent = { [weak self, weak cardCtrl] in
            self?.confirmDeleteCurrentProject(refresh: { cardCtrl?.refreshProjectConfiguration() })
        }
        cardCtrl.onRequestSyncCodexProjection = { [weak self] in
            self?.syncCodexProjectionForCurrentProject() ?? "同步 Codex 配置失败：App 已释放"
        }
        cardCtrl.onRequestSyncClaudeCodeProjection = { [weak self] in
            self?.syncClaudeCodeProjectionForCurrentProject() ?? "同步 Claude Code 配置失败：App 已释放"
        }
        cardCtrl.onRequestSyncOpencodeProjection = { [weak self] in
            self?.syncOpencodeProjectionForCurrentProject() ?? "同步 opencode 配置失败：App 已释放"
        }
        cardCtrl.onRequestShowProjectCapabilityDiagnostics = { [weak self] in
            self?.projectCapabilityPanelForCurrentProject() ?? ProjectCapabilityPanelState(
                fullText: "项目能力诊断失败：App 已释放",
                sections: [ProjectCapabilityPanelState.Section(
                    engineName: "项目能力诊断",
                    status: .failed,
                    ownership: nil,
                    rows: [],
                    diagnostics: [ProjectCapabilityPanelState.Diagnostic(severity: "error", message: "App 已释放", path: nil)]
                )]
            )
        }
        cardCtrl.onRequestOpenProjectCapabilityManager = { [weak self] in
            self?.showProjectCapabilityManagerCard()
        }
    }

    /// 弹 NSAlert 收项目名 → 创建托管项目(`~/.open-pet-agent/projects/<id>/`)+ 刷新 chat card Menu。
    @MainActor func promptForProjectNameAndCreate(refresh: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "新建项目"
        alert.informativeText = "为 agent 工作起个项目名(托管在 ~/.open-pet-agent/projects/)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "项目名"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        do {
            try ProjectStore.create(name: input.stringValue)
            refresh()
        } catch {
            showProjectError(title: "创建项目失败", error: error)
        }
    }

    /// NSOpenPanel 选外部目录 → `createExternal`(name=目录名)+ 刷新。外部项目跟项目走(VSCode 模式)。
    @MainActor func promptForExternalProjectAndCreate(refresh: @escaping @MainActor () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选一个目录作为 agent 工作项目(跟项目走,VSCode 模式)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectStore.createExternal(name: url.lastPathComponent, rootURL: url)
            refresh()
        } catch {
            showProjectError(title: "添加外部项目失败", error: error)
        }
    }

    /// NSAlert 收新名(默认当前名)→ `rename` + 刷新。default 不可改名(系统项目)。
    @MainActor func promptForRenameCurrentProject(refresh: @escaping @MainActor () -> Void) {
        let current = ProjectStore.current(defaults: userDefaults)
        guard current.id != ProjectConfig.defaultProject.id else { return }
        let alert = NSAlert()
        alert.messageText = "重命名项目"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = current.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        do {
            try ProjectStore.rename(id: current.id, newName: input.stringValue)
            refresh()
        } catch {
            showProjectError(title: "重命名失败", error: error)
        }
    }

    /// NSAlert 确认 → `delete` + `setCurrent(default)` + 重 apply engine + 刷新。default 不可删。
    @MainActor func confirmDeleteCurrentProject(refresh: @escaping @MainActor () -> Void) {
        let current = ProjectStore.current(defaults: userDefaults)
        guard current.id != ProjectConfig.defaultProject.id else { return }
        let alert = NSAlert()
        alert.messageText = "删除项目「\(current.name)」?"
        alert.informativeText = "从项目列表移除(不删文件,托管项目目录留给你手动清理)。删除后切回默认项目。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ProjectStore.delete(id: current.id)
            ProjectStore.setCurrent(ProjectConfig.defaultProject.id, defaults: userDefaults)
            Self.applySelectedAgentEngine(to: agentModeRouter, defaults: userDefaults)
            refresh()
        } catch {
            showProjectError(title: "删除失败", error: error)
        }
    }

    /// 显式把当前项目的 Codex projection 落盘。只响应用户点击,不在聊天时自动写项目文件。
    @MainActor func syncCodexProjectionForCurrentProject(project: AgentProject? = nil) -> String {
        let project = project ?? ProjectStore.current(defaults: userDefaults)
        do {
            try ProjectConfig.ensure(for: project)
            let plans = try CodexProjectAdapter().plans(for: project)
            let operationCount = plans.reduce(0) { $0 + $1.operations.count }
            try CodexProjectionMaterializer().apply(plans)
            return operationCount == 0 ? "没有可同步的 Codex 配置" : "Codex 配置已同步"
        } catch {
            showProjectError(title: "同步 Codex 配置失败", error: error)
            return "同步 Codex 配置失败：\(error)"
        }
    }

    /// 显式把当前项目的 Claude Code projection 落盘。只响应用户点击,不在聊天时自动写项目文件。
    @MainActor func syncClaudeCodeProjectionForCurrentProject(project: AgentProject? = nil) -> String {
        let project = project ?? ProjectStore.current(defaults: userDefaults)
        do {
            try ProjectConfig.ensure(for: project)
            let plans = try ClaudeCodeProjectAdapter().plans(for: project)
            let operationCount = plans.reduce(0) { $0 + $1.operations.count }
            try ClaudeCodeProjectionMaterializer().apply(plans)
            return operationCount == 0 ? "没有可同步的 Claude Code 配置" : "Claude Code 配置已同步"
        } catch {
            showProjectError(title: "同步 Claude Code 配置失败", error: error)
            return "同步 Claude Code 配置失败：\(error)"
        }
    }

    /// 显式把当前项目的 opencode projection 落盘。只响应用户点击,不在聊天时自动写项目文件。
    /// 只 materialize plugin/data 到 `.open-pet-agent/plugins/.materialized/openCode/`,不覆盖用户 opencode.json。
    @MainActor func syncOpencodeProjectionForCurrentProject(project: AgentProject? = nil) -> String {
        let project = project ?? ProjectStore.current(defaults: userDefaults)
        do {
            try ProjectConfig.ensure(for: project)
            let plans = try OpencodeProjectAdapter().plans(for: project)
            let operationCount = plans.reduce(0) { $0 + $1.operations.count }
            try OpencodeProjectionMaterializer().apply(plans)
            return operationCount == 0 ? "没有可同步的 opencode 配置" : "opencode 配置已同步"
        } catch {
            showProjectError(title: "同步 opencode 配置失败", error: error)
            return "同步 opencode 配置失败：\(error)"
        }
    }

    @MainActor func projectCapabilityColumnState(for project: AgentProject) -> ProjectCapabilityColumnState {
        func card(for project: AgentProject) -> ProjectCapabilityCardState {
            (try? Self.projectCapabilityCard(for: project, selectedTab: .skills)) ?? ProjectCapabilityCardState(selectedTab: .skills, items: [])
        }
        return ProjectCapabilityColumnState(
            card: card(for: project),
            onSetEnabled: { [weak self] pluginID, enabled in
                guard let self else { return ProjectCapabilityCardState(selectedTab: .skills, items: []) }
                do {
                    try Self.setProjectPluginEnabled(project: project, pluginID: pluginID, enabled: enabled)
                } catch {
                    self.showProjectError(title: "更新项目能力失败", error: error)
                }
                return card(for: project)
            },
            onCreatePlugin: { [weak self] pluginID, name in
                guard let self else { return ProjectCapabilityCardState(selectedTab: .skills, items: []) }
                do {
                    try Self.createProjectCapabilityPlugin(project: project, pluginID: pluginID, name: name)
                } catch {
                    self.showProjectError(title: "创建项目能力失败", error: error)
                }
                return card(for: project)
            },
            onAddSkill: { [weak self] pluginID, skillName in
                guard let self else { return ProjectCapabilityCardState(selectedTab: .skills, items: []) }
                do {
                    try Self.addProjectCapabilitySkill(project: project, pluginID: pluginID, skillName: skillName)
                } catch {
                    self.showProjectError(title: "添加 Skill 失败", error: error)
                }
                return card(for: project)
            },
            onAddMCP: { [weak self] pluginID, serverName, command in
                guard let self else { return ProjectCapabilityCardState(selectedTab: .mcp, items: []) }
                do {
                    try Self.addProjectCapabilityMCP(project: project, pluginID: pluginID, serverName: serverName, command: command)
                } catch {
                    self.showProjectError(title: "添加 MCP 失败", error: error)
                }
                return card(for: project)
            },
            onSyncCodex: { [weak self] in self?.syncCodexProjectionForCurrentProject(project: project) ?? "同步 Codex 配置失败：App 已释放" },
            onSyncClaudeCode: { [weak self] in self?.syncClaudeCodeProjectionForCurrentProject(project: project) ?? "同步 Claude Code 配置失败：App 已释放" },
            onSyncOpencode: { [weak self] in self?.syncOpencodeProjectionForCurrentProject(project: project) ?? "同步 opencode 配置失败：App 已释放" }
        )
    }

    @MainActor func showProjectCapabilityManagerCard() {
        projectCapabilityCardWindowController?.hide()
        let project = ProjectStore.current(defaults: userDefaults)
        let model = projectCapabilityColumnState(for: project)
        columnContainerWindowController.openRoot(
            .projectCapabilityManager(model),
            sourceKey: "project-capability-manager",
            besideMain: mainCardFrame(),
            screen: currentScreenFrame()
        )
    }

    /// 只读汇总当前项目的项目能力管理卡片:catalog + dry-run projection targets,不执行 materializer。
    @MainActor func projectCapabilityCardForCurrentProject() -> ProjectCapabilityCardState {
        (try? Self.projectCapabilityCard(for: ProjectStore.current(defaults: userDefaults), selectedTab: .skills)) ?? ProjectCapabilityCardState(selectedTab: .skills, items: [])
    }

    static func projectCapabilityCard(for project: AgentProject, selectedTab: ProjectCapabilityCardState.Tab) throws -> ProjectCapabilityCardState {
        let catalog = ProjectPluginCatalog()
        let plugins = try catalog.listPlugins(for: project)
        let modelDiagnostics = try ProjectCapabilityValidator().validate(project: project, catalog: catalog)
        let diagnosticsByPlugin = Dictionary(grouping: modelDiagnostics) { diagnostic in
            diagnostic.path.flatMap { pluginID(fromPath: $0) } ?? ""
        }
        let sections = [
            Self.projectCapabilitySection(engineName: "opencode") { try OpencodeProjectAdapter().plans(for: project) },
            Self.projectCapabilitySection(engineName: "Codex") { try CodexProjectAdapter().plans(for: project) },
            Self.projectCapabilitySection(engineName: "Claude Code") { try ClaudeCodeProjectAdapter().plans(for: project) }
        ]
        let targetsBySource = projectionTargetsBySource(sections)
        let mcpTargets = projectionConfigTargets(sections)
        let diagnostics = sections.flatMap { section -> [ProjectCapabilityPanelState.Diagnostic] in
            if let error = section.errorDescription {
                return [ProjectCapabilityPanelState.Diagnostic(severity: "error", message: error, path: nil)]
            }
            return section.plans.flatMap(\.diagnostics).map { ProjectCapabilityPanelState.Diagnostic(
                severity: $0.severity.rawValue,
                message: $0.message,
                path: $0.path
            ) }
        }
        let items = plugins.flatMap { plugin in
            capabilityItems(
                for: plugin,
                diagnostics: diagnosticsByPlugin[plugin.id] ?? catalog.validate(plugin),
                projectionDiagnostics: diagnostics,
                targetsBySource: targetsBySource,
                mcpTargets: mcpTargets
            )
        }
        return ProjectCapabilityCardState(selectedTab: selectedTab, items: items)
    }

    static func createProjectCapabilityPlugin(project: AgentProject, pluginID: String, name: String) throws {
        try validateProjectCapabilityPluginID(pluginID)
        let pluginDirectory = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID)
        let pluginRoot = ProjectConfig.pluginRoot(for: project)
        guard ProjectionTrust.isPath(pluginDirectory, inside: pluginRoot),
              (!FileManager.default.fileExists(atPath: pluginDirectory.path) || ProjectionTrust.isPath(pluginDirectory.resolvingSymlinksInPath(), inside: pluginRoot.resolvingSymlinksInPath())) else {
            throw ProjectCapabilityManagerError.invalidPluginID(pluginID)
        }
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        let manifestURL = pluginDirectory.appendingPathComponent("plugin.json")
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "id": pluginID,
            "name": name,
            "enabled": true,
            "capabilities": [],
            "engines": [
                AgentEngineKind.codex.rawValue: ["enabled": true, "projection": ProjectionPolicy.skillsAndMCPFiles.rawValue],
                "claude-code": ["enabled": true, "projection": ProjectionPolicy.skillsAndMCPFiles.rawValue]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
    }

    static func addProjectCapabilitySkill(project: AgentProject, pluginID: String, skillName: String) throws {
        try createProjectCapabilityPlugin(project: project, pluginID: pluginID, name: pluginID)
        let safeSkill = sanitizedCapabilityName(skillName)
        let skillRef = "skills/\(safeSkill)"
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent(skillRef, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skillFile = dir.appendingPathComponent("SKILL.md", isDirectory: false)
        if !FileManager.default.fileExists(atPath: skillFile.path) {
            try "# \(safeSkill)\n\n项目级 Skill，占位内容。\n".data(using: .utf8)!.write(to: skillFile, options: .atomic)
        }
        try updateProjectCapabilityManifest(project: project, pluginID: pluginID) { manifest in
            var capabilities = manifest["capabilities"] as? [String] ?? []
            if !capabilities.contains(ProjectPluginCapability.skills.rawValue) { capabilities.append(ProjectPluginCapability.skills.rawValue) }
            manifest["capabilities"] = capabilities
            var skills = manifest["skills"] as? [String] ?? []
            if !skills.contains(skillRef) { skills.append(skillRef) }
            manifest["skills"] = skills
        }
    }

    static func addProjectCapabilityMCP(project: AgentProject, pluginID: String, serverName: String, command: [String] = ["npx", "-y", "@modelcontextprotocol/server-filesystem"]) throws {
        try createProjectCapabilityPlugin(project: project, pluginID: pluginID, name: pluginID)
        let safeServer = sanitizedCapabilityName(serverName)
        let mcpDir = ProjectConfig.pluginMCPDirectory(for: project, pluginID: pluginID)
        try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        let mcpURL = mcpDir.appendingPathComponent("servers.json", isDirectory: false)
        let object: [String: Any] = [
            "mcpServers": [
                safeServer: [
                    "type": "local",
                    "command": command.isEmpty ? ["npx", "-y", "@modelcontextprotocol/server-filesystem"] : command,
                    "enabled": true
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: mcpURL, options: .atomic)
        try updateProjectCapabilityManifest(project: project, pluginID: pluginID) { manifest in
            var capabilities = manifest["capabilities"] as? [String] ?? []
            if !capabilities.contains(ProjectPluginCapability.mcp.rawValue) { capabilities.append(ProjectPluginCapability.mcp.rawValue) }
            manifest["capabilities"] = capabilities
            let ref = "mcp/servers.json#\(safeServer)"
            var mcp = manifest["mcp"] as? [String] ?? []
            if !mcp.contains(ref) { mcp.append(ref) }
            manifest["mcp"] = mcp
        }
    }

    private static func updateProjectCapabilityManifest(project: AgentProject, pluginID: String, mutate: (inout [String: Any]) -> Void) throws {
        let manifestURL = try projectCapabilityManifestURL(project: project, pluginID: pluginID)
        let data = try Data(contentsOf: manifestURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] as? String == pluginID else {
            throw ProjectCapabilityManagerError.invalidManifest(pluginID)
        }
        mutate(&object)
        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: manifestURL, options: .atomic)
    }

    private static func projectCapabilityManifestURL(project: AgentProject, pluginID: String) throws -> URL {
        try validateProjectCapabilityPluginID(pluginID)
        let manifestURL = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("plugin.json")
        let pluginRoot = ProjectConfig.pluginRoot(for: project)
        guard ProjectionTrust.isPath(manifestURL, inside: pluginRoot),
              ProjectionTrust.isPath(manifestURL.resolvingSymlinksInPath(), inside: pluginRoot.resolvingSymlinksInPath()) else {
            throw ProjectCapabilityManagerError.invalidPluginID(pluginID)
        }
        return manifestURL
    }

    private static func validateProjectCapabilityPluginID(_ pluginID: String) throws {
        guard !pluginID.isEmpty, !pluginID.contains("/"), pluginID != ".", pluginID != ".." else {
            throw ProjectCapabilityManagerError.invalidPluginID(pluginID)
        }
    }

    private static func sanitizedCapabilityName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "example" : result
    }

    static func setProjectPluginEnabled(project: AgentProject, pluginID: String, enabled: Bool) throws {
        guard !pluginID.isEmpty, !pluginID.contains("/"), pluginID != ".", pluginID != ".." else {
            throw ProjectCapabilityManagerError.invalidPluginID(pluginID)
        }
        let manifestURL = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("plugin.json")
        let pluginRoot = ProjectConfig.pluginRoot(for: project)
        guard ProjectionTrust.isPath(manifestURL, inside: pluginRoot),
              ProjectionTrust.isPath(manifestURL.resolvingSymlinksInPath(), inside: pluginRoot.resolvingSymlinksInPath()) else {
            throw ProjectCapabilityManagerError.invalidPluginID(pluginID)
        }
        let data = try Data(contentsOf: manifestURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectCapabilityManagerError.invalidManifest(pluginID)
        }
        guard object["id"] as? String == pluginID else {
            throw ProjectCapabilityManagerError.invalidManifest(pluginID)
        }
        object["enabled"] = enabled
        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: manifestURL, options: .atomic)
    }

    private static func projectionTargetsBySource(_ sections: [ProjectCapabilityDiagnosticSection]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for operation in sections.flatMap(\.plans).flatMap(\.operations) {
            switch operation {
            case .copyDirectory(let source, let destination), .symlinkDirectory(let source, let destination):
                result[source.path, default: []].append(destination.path)
            case .writeFile, .removeGenerated:
                continue
            }
        }
        return result
    }

    private static func projectionConfigTargets(_ sections: [ProjectCapabilityDiagnosticSection]) -> [String] {
        sections
            .flatMap(\.plans)
            .flatMap(\.operations)
            .compactMap { operation -> String? in
                if case let .writeFile(_, destination) = operation { return destination.path }
                return nil
            }
    }

    private static func capabilityItems(
        for plugin: ProjectPluginDescriptor,
        diagnostics: [ProjectConfigDiagnostic],
        projectionDiagnostics: [ProjectCapabilityPanelState.Diagnostic],
        targetsBySource: [String: [String]],
        mcpTargets: [String]
    ) -> [ProjectCapabilityCardState.Item] {
        let itemDiagnostics = diagnostics.map { ProjectCapabilityPanelState.Diagnostic(
            severity: $0.severity.rawValue,
            message: $0.message,
            path: $0.path
        ) } + projectionDiagnostics
        let status = capabilityStatus(enabled: plugin.enabled, diagnostics: itemDiagnostics)
        let skillItems = plugin.skills.map { ref in
            let source = plugin.rootURL.appendingPathComponent(ref, isDirectory: true).path
            return ProjectCapabilityCardState.Item(
                id: "skill:\(plugin.id):\(source)",
                kind: .skill,
                name: URL(fileURLWithPath: ref).lastPathComponent,
                pluginID: plugin.id,
                sourcePath: source,
                targetPaths: targetsBySource[source] ?? [],
                isEnabled: plugin.enabled,
                status: status,
                diagnostics: itemDiagnostics
            )
        }
        let mcpItems = plugin.mcp.map { ref in
            let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
            let file = parts.first ?? ref
            let name = parts.count == 2 ? parts[1] : ref
            let source = plugin.rootURL.appendingPathComponent(file, isDirectory: false).path + (parts.count == 2 ? "#\(name)" : "")
            return ProjectCapabilityCardState.Item(
                id: "mcp:\(plugin.id):\(name)",
                kind: .mcp,
                name: name,
                pluginID: plugin.id,
                sourcePath: source,
                targetPaths: mcpTargets,
                isEnabled: plugin.enabled,
                status: status,
                diagnostics: itemDiagnostics
            )
        }
        return skillItems + mcpItems
    }

    private static func capabilityStatus(enabled: Bool, diagnostics: [ProjectCapabilityPanelState.Diagnostic]) -> ProjectCapabilityCardState.Item.Status {
        if diagnostics.contains(where: { $0.severity == "error" }) { return .failed }
        if diagnostics.contains(where: { $0.severity == "warning" }) { return .warning }
        return enabled ? .enabled : .disabled
    }

    /// 只读汇总当前项目三路 projection dry-run:targets / ownership / diagnostics / plan 构建失败原因。
    @MainActor func projectCapabilityPanelForCurrentProject() -> ProjectCapabilityPanelState {
        let project = ProjectStore.current(defaults: userDefaults)
        let sections = [
            Self.projectCapabilitySection(engineName: "opencode") { try OpencodeProjectAdapter().plans(for: project) },
            Self.projectCapabilitySection(engineName: "Codex") { try CodexProjectAdapter().plans(for: project) },
            Self.projectCapabilitySection(engineName: "Claude Code") { try ClaudeCodeProjectAdapter().plans(for: project) }
        ]
        return ProjectCapabilityPanelState(
            fullText: ProjectCapabilityDiagnostics.render(sections),
            sections: sections.map(projectCapabilityPanelSection)
        )
    }

    private static func projectCapabilitySection(engineName: String, load: () throws -> [ProjectionPlan]) -> ProjectCapabilityDiagnosticSection {
        do {
            return ProjectCapabilityDiagnosticSection(engineName: engineName, plans: try load())
        } catch {
            return ProjectCapabilityDiagnosticSection(engineName: engineName, plans: [], errorDescription: "\(error)")
        }
    }

    private func projectCapabilityPanelSection(_ section: ProjectCapabilityDiagnosticSection) -> ProjectCapabilityPanelState.Section {
        if let errorDescription = section.errorDescription {
            return ProjectCapabilityPanelState.Section(
                engineName: section.engineName,
                status: .failed,
                ownership: nil,
                rows: [],
                diagnostics: [ProjectCapabilityPanelState.Diagnostic(severity: "error", message: errorDescription, path: nil)]
            )
        }
        let operations = section.plans.flatMap(\.operations)
        let diagnostics = section.plans.flatMap(\.diagnostics)
        let status: ProjectCapabilityPanelState.Section.Status
        if operations.isEmpty && diagnostics.isEmpty { status = .empty }
        else if diagnostics.contains(where: { $0.severity == .error }) { status = .failed }
        else if !diagnostics.isEmpty { status = .warning }
        else { status = .ready }
        return ProjectCapabilityPanelState.Section(
            engineName: section.engineName,
            status: status,
            ownership: operations.isEmpty ? nil : "OpenPetAgent 生成内容",
            rows: section.plans.flatMap { plan in
                plan.operations.map(projectCapabilityPanelRow)
            },
            diagnostics: diagnostics.map { ProjectCapabilityPanelState.Diagnostic(
                severity: $0.severity.rawValue,
                message: $0.message,
                path: $0.path
            ) }
        )
    }

    private func projectCapabilityPanelRow(_ operation: ProjectionOperation) -> ProjectCapabilityPanelState.Row {
        switch operation {
        case .writeFile(_, let destination):
            return ProjectCapabilityPanelState.Row(kind: "写入生成文件", target: destination.path)
        case .copyDirectory(let source, let destination):
            return ProjectCapabilityPanelState.Row(kind: "复制生成目录", target: destination.path, detail: "来源: \(source.path)", source: source.path, pluginID: pluginID(from: source))
        case .symlinkDirectory(let source, let destination):
            return ProjectCapabilityPanelState.Row(kind: "链接生成目录", target: destination.path, detail: "来源: \(source.path)", source: source.path, pluginID: pluginID(from: source))
        case .removeGenerated(let url):
            return ProjectCapabilityPanelState.Row(kind: "移除生成内容", target: url.path)
        }
    }

    private static func pluginID(fromPath path: String) -> String? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let pluginsIndex = parts.lastIndex(of: "plugins"), parts.indices.contains(pluginsIndex + 1) else { return nil }
        let candidate = parts[pluginsIndex + 1]
        return candidate == ".materialized" ? nil : candidate
    }

    private func pluginID(from source: URL) -> String? {
        Self.pluginID(fromPath: source.path)
    }

    /// 项目操作失败提示(创建/外部/重命名/删除/Codex/Claude Code/opencode 同步 共用)。
    @MainActor private func showProjectError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
