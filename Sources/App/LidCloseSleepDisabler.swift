import Foundation
import os

private let screenAwakeLog = Logger(subsystem: "io.openpetagent", category: "ScreenAwake")

/// 提权设置 + 读取系统 `SleepDisabled`(`pmset disablesleep`)的执行协议。
/// 抽成协议是为了**可注入 mock 单测**(真实现走 osascript 提权,测试不能弹密码框)。
protocol SleepDisableExecuting {
    /// 设系统 `SleepDisabled`(需管理员权限)。返回成功;用户取消密码 / 失败 → false。
    func setSleepDisabled(_ on: Bool) async -> Bool
    /// 读当前 `SleepDisabled`(不需权限)。nil = 读取失败。
    func readSleepDisabled() -> Bool?
}

/// 真实现:`set` 走 `NSAppleScript` 的 `do shell script ... with administrator privileges`
/// (弹系统密码 / Touch ID 框);`read` 走无权限的 `pmset -g` 解析。
///
/// **零命令注入面**:提权命令是两条**固定字符串**(只内插 0/1),不接受外部输入拼接。
struct OSAScriptSleepDisableExecutor: SleepDisableExecuting {
    func setSleepDisabled(_ on: Bool) async -> Bool {
        // 固定命令,绝不内插外部字符串 → 无注入面。
        let pmsetCommand = on
            ? "/usr/bin/pmset -a disablesleep 1"
            : "/usr/bin/pmset -a disablesleep 0"
        let script = "do shell script \"\(pmsetCommand)\" with administrator privileges"
        return await withCheckedContinuation { continuation in
            // 提权框会阻塞调用线程 → 必须离开 main，否则冻结 UI。
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                _ = appleScript?.executeAndReturnError(&error)
                if let error {
                    // 记日志便于诊断(区分用户取消 -128 vs pmset 真失败 vs 未来 OS 限制)。
                    // error dict 是 AppleScript 错误信息,无敏感数据。
                    screenAwakeLog.error("pmset disablesleep \(on, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
                continuation.resume(returning: error == nil)
            }
        }
    }

    func readSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseSleepDisabled(from: output)
    }

    /// 从 `pmset -g` 输出解析 `SleepDisabled` 行(`SleepDisabled  1` / `0`)。纯函数,可单测。
    static func parseSleepDisabled(from pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            // 行尾是 0 / 1;取末尾 token 判断。
            let tail = trimmed.dropFirst("SleepDisabled".count).trimmingCharacters(in: .whitespaces)
            return tail == "1"
        }
        return nil
    }
}

/// 「合盖也保持唤醒」靠的全局 `pmset disablesleep` 开关封装 —— 单一职责:开 / 关 / 读 / 启动自愈。
/// 执行器可注入(默认 osascript 真实现)。
@MainActor
final class LidCloseSleepDisabler {
    private let executor: SleepDisableExecuting

    init(executor: SleepDisableExecuting = OSAScriptSleepDisableExecutor()) {
        self.executor = executor
    }

    /// 开启(disablesleep=1)。返回成功(取消密码 → false)。
    /// **读回校验**:提权报成功但全局值没翻(MDM/sandbox/未来 OS 限制)→ 视为失败,
    /// 让状态机据实回退,避免 UI 说「已开」而系统其实没生效。读回失败(nil)时信任提权结果。
    func enable() async -> Bool {
        guard await executor.setSleepDisabled(true) else { return false }
        if executor.readSleepDisabled() == false {
            screenAwakeLog.error("disablesleep enable reported success but readback != 1")
            return false
        }
        return true
    }

    /// 关闭(disablesleep=0)。返回成功(取消密码 → false)。读回校验同 `enable`。
    func disable() async -> Bool {
        guard await executor.setSleepDisabled(false) else { return false }
        if executor.readSleepDisabled() == true {
            screenAwakeLog.error("disablesleep disable reported success but readback != 0")
            return false
        }
        return true
    }

    /// 当前系统是否 SleepDisabled=1。nil = 读取失败。
    func isSystemSleepDisabled() -> Bool? { executor.readSleepDisabled() }

    /// 启动自愈:若系统残留 `SleepDisabled=1` 但本次**不该**开(崩溃 / 退出未复位)→ 复位 0。
    /// 返回是否执行了复位。这是防「开了忘关」残留的硬保证(启动时弹一次密码)。
    @discardableResult
    func selfHealIfOrphaned(shouldBeActive: Bool) async -> Bool {
        guard !shouldBeActive, isSystemSleepDisabled() == true else { return false }
        return await disable()
    }
}
