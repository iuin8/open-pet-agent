import Foundation
import Testing
import AgentMode
import Shell
@testable import App

// ACP-2 permission UI 纯映射单测:ACPPermissionRequest → PermissionCardModel +
// allow/deny → ACPPermissionOutcome optionId 映射。presentACPPermission 的 continuation
// /wiring 是集成(需 store + controller),不在此单测。

@Suite("ACPPermission")
struct ACPPermissionTests {

    private func option(_ id: String, _ kind: String) -> ACPPermissionRequest.Option {
        ACPPermissionRequest.Option(optionId: id, name: id, kind: kind)
    }

    /// 便利构造(默认 title/kind + 自定义 options)。
    private func req(title: String? = "Bash: npm test", kind: String? = "execute",
                     options: [ACPPermissionRequest.Option] = []) -> ACPPermissionRequest {
        ACPPermissionRequest(toolCallId: "tc1", title: title, kind: kind, options: options)
    }

    // MARK: - permissionCardModel 映射

    @Test("permissionCardModel: title 取 req.title 优先,kind=standard")
    func modelTitleFromReq() {
        let m = MinimalAppDelegate.permissionCardModel(from: req(title: "Bash: npm test", kind: "execute"))
        #expect(m.kind == .standard)
        #expect(m.title == "Bash: npm test")
        #expect(m.detail == nil)
        #expect(m.project == nil)
    }

    @Test("permissionCardModel: 无 title 退 kind")
    func modelTitleFallbackKind() {
        let m = MinimalAppDelegate.permissionCardModel(from: req(title: nil, kind: "edit"))
        #expect(m.title == "edit")
    }

    @Test("permissionCardModel: 无 title 无 kind 退默认")
    func modelTitleFallbackDefault() {
        let m = MinimalAppDelegate.permissionCardModel(from: req(title: nil, kind: nil))
        #expect(m.title == "工具权限")
    }

    // MARK: - outcomeForAllow

    @Test("outcomeForAllow: allow_once option → selected(allow_once id)")
    func allowOnceSelected() {
        let r = req(options: [option("a1", "allow_once"), option("r1", "reject_once")])
        #expect(MinimalAppDelegate.outcomeForAllow(req: r) == .selected(optionId: "a1"))
    }

    @Test("outcomeForAllow: 无 allow_once 但有 allow_always → selected(allow_always)(hasPrefix allow)")
    func allowAlwaysFallback() {
        let r = req(options: [option("a2", "allow_always"), option("r1", "reject_once")])
        #expect(MinimalAppDelegate.outcomeForAllow(req: r) == .selected(optionId: "a2"))
    }

    @Test("outcomeForAllow: 无 allow option → safeDefault(reject_once)")
    func allowNoAllowOption() {
        let r = req(options: [option("r1", "reject_once")])
        #expect(MinimalAppDelegate.outcomeForAllow(req: r) == .selected(optionId: "r1"))
    }

    @Test("outcomeForAllow: 无 option → safeDefault(cancelled)")
    func allowNoOptions() {
        let r = req(options: [])
        #expect(MinimalAppDelegate.outcomeForAllow(req: r) == .cancelled)
    }

    // MARK: - outcomeForDeny

    @Test("outcomeForDeny: reject_once option → selected(reject_once id)")
    func denyOnceSelected() {
        let r = req(options: [option("a1", "allow_once"), option("r1", "reject_once")])
        #expect(MinimalAppDelegate.outcomeForDeny(req: r) == .selected(optionId: "r1"))
    }

    @Test("outcomeForDeny: 无 reject_once 但有 reject_always → selected(reject_always)")
    func denyAlwaysFallback() {
        let r = req(options: [option("a1", "allow_once"), option("r2", "reject_always")])
        #expect(MinimalAppDelegate.outcomeForDeny(req: r) == .selected(optionId: "r2"))
    }

    @Test("outcomeForDeny: 无 reject option → cancelled")
    func denyNoRejectOption() {
        let r = req(options: [option("a1", "allow_once")])
        #expect(MinimalAppDelegate.outcomeForDeny(req: r) == .cancelled)
    }
}
