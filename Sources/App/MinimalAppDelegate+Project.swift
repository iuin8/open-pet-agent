import AppKit
import Shell

// MARK: - 项目配置(P1b 多项目 UI 接线)

extension MinimalAppDelegate {

    /// 注入项目配置 provider + 切换/创建回调到 chat card(P1b 多项目 UI)。
    ///
    /// mirror `replyConfiguration` 注入模式:`ProjectStore.current()` 派生 current + `list()` 派生列表,
    /// 切项目 → 写 UD `tool.project.id` + `applySelectedAgentEngine` 重 apply + wireACPPermission;
    /// 创建项目 → NSAlert 收名字 + `ProjectStore.create` + 刷新 Menu。
    /// 详见 `docs/project-config-architecture-design.md` §9 留后(多项目系统 P1b)。
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
        }
        cardCtrl.onRequestCreateProject = { [weak self, weak cardCtrl] in
            self?.promptForProjectNameAndCreate(refresh: { cardCtrl?.refreshProjectConfiguration() })
        }
    }

    /// 弹 NSAlert 收项目名 → 创建托管项目(`~/.open-pet-agent/projects/<id>/`)+ 刷新 chat card Menu。
    /// 创建失败(磁盘满/权限)不致命,弹 alert 提示。外部项目(NSOpenPanel)留 P1b 后续。
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
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        do {
            try ProjectStore.create(name: input.stringValue)
            refresh()
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "创建项目失败"
            errAlert.informativeText = "\(error)"
            errAlert.alertStyle = .warning
            errAlert.runModal()
        }
    }
}
