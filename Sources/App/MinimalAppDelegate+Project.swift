import AppKit
import AgentMode
import Shell

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
    @MainActor func syncCodexProjectionForCurrentProject() -> String {
        let project = ProjectStore.current(defaults: userDefaults)
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
    @MainActor func syncClaudeCodeProjectionForCurrentProject() -> String {
        let project = ProjectStore.current(defaults: userDefaults)
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

    /// 项目操作失败提示(创建/外部/重命名/删除/Codex/Claude Code 同步 共用)。
    @MainActor private func showProjectError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
