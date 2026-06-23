import Foundation
import os

/// 用户对一个权限请求的处置。`abstain`(弃权)把决定权交还正常权限流 / 其它 hook 工具 ——
/// 用户没在 OpenPetAgent 卡片上选时,我们回弃权(官方:空输出 = 不决策走正常流程)。
public enum PermissionDecision: String, Sendable, Equatable {
    case allow
    case deny
    case abstain
}

/// 把决策构造成 Claude Code `PermissionRequest` hook 期望的回写 JSON(官方 schema)。
///
/// 官方:`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny","updatedInput"?:{…}}}}`;
/// 弃权 = 省略 decision(回 `{}`)。`updatedInput` 用于改写工具输入(如 AskUserQuestion 答案)。
public enum PermissionResponse {

    public static let hookEventName = "PermissionRequest"
    private static let log = Logger(subsystem: "io.openpetagent", category: "AgentSensing.response")

    /// 决策 → hookSpecificOutput 字典。弃权返回空 `[:]`(序列化成 `{}`)。
    public static func hookOutput(
        _ decision: PermissionDecision,
        updatedInput: [String: Any]? = nil
    ) -> [String: Any] {
        switch decision {
        case .abstain:
            return [:]
        case .allow:
            var inner: [String: Any] = ["behavior": "allow"]
            if let updatedInput, !updatedInput.isEmpty { inner["updatedInput"] = updatedInput }
            return ["hookSpecificOutput": ["hookEventName": hookEventName, "decision": inner]]
        case .deny:
            return ["hookSpecificOutput": ["hookEventName": hookEventName, "decision": ["behavior": "deny"]]]
        }
    }

    /// 决策 → HTTP 响应体(JSON)。弃权 = **空 body**(官方:`type:"http"` hook「2xx + 空 body」
    /// = exit 0 无输出 = 无决策,把决定权交还正常流程 / 另一个 hook;不发 `{}`,
    /// 也避免给客户端渲染塞一个可解析但空的 decision 对象)。序列化失败同样降级为空 body(安全弃权)。
    public static func httpBody(
        _ decision: PermissionDecision,
        updatedInput: [String: Any]? = nil
    ) -> Data {
        let obj = hookOutput(decision, updatedInput: updatedInput)
        if obj.isEmpty { return Data() }   // 弃权 → 空 body
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            // 固定结构理论上不该失败;真失败=代码 bug,记下来别让用户的「允许」静默变弃权。
            log.error("决策序列化失败,降级为弃权(空 body)")
            return Data()
        }
        return data
    }
}
