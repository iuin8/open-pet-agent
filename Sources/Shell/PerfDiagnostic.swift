import AppKit
import Darwin

/// 性能自诊断「心跳」—— `PETAGENT_DEBUG_PERF=1` 启用,每 5s 往 stderr 打一行关键信号,
/// 让「CPU 跑久飙高 / 内存增长」这类问题**一看日志就知道是哪类**,不用反复采样/截图。
///
/// 为什么是 env 而非设置开关:这是开发/排查工具(输出内部计数),不该进用户面板(产品整洁);
/// 且「越跑越高」需从启动就开着采全程,env 启动即开正合适。登记见 docs/development-guide.md 调试开关表。
///
/// 一行示例:
///   `[PERF] t=120s rss=181MB Δrss=+0.4 | apply=9/5s earlyOut=6(67%) rows=412 | mainBusy~3%`
/// 判读:apply 调用多而 earlyOut 低 = 重渲染风暴(脏源没断 / 短路失效);rows 持续涨 + apply 高 =
/// 「每帧重算 × 增长数据」(§6.6);Δrss 持续正 = 泄漏/无界容器(§6.2)。
@MainActor
public enum PerfDiagnostic {
    public static var isEnabled: Bool { ProcessInfo.processInfo.environment["PETAGENT_DEBUG_PERF"] == "1" }

    // 由热点路径自增的计数(无成本:仅 Int++);心跳读取后清零算速率。
    /// `TranscriptListCoordinator.apply` 调用次数(重渲染压力)。
    public static var applyCalls = 0
    /// 其中走了 Equatable 短路早退的次数(健康时应≈applyCalls)。
    public static var applyEarlyOuts = 0
    /// 最近一次 apply 的 transcript 行数(增长探测)。
    public static var lastRowCount = 0

    private static var timer: Timer?
    private static var started = false
    private static var startTime: Date?
    private static var lastRSS: Double = 0

    /// 启动心跳(幂等)。未设 env → no-op、零成本。建议在 app 启动 setup 里调一次。
    public static func startIfEnabled() {
        guard isEnabled, !started else { return }
        started = true
        startTime = Date()
        lastRSS = residentMB()
        NSLog("[PERF] 心跳已启用(每 5s 一行)。读法见 PerfDiagnostic 文件头注释。")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { heartbeat() }
        }
    }

    private static func heartbeat() {
        let rss = residentMB()
        let dRSS = rss - lastRSS
        lastRSS = rss
        let elapsed = startTime.map { Int(-$0.timeIntervalSinceNow) } ?? 0
        let calls = applyCalls, early = applyEarlyOuts
        applyCalls = 0; applyEarlyOuts = 0
        let earlyPct = calls > 0 ? early * 100 / calls : 0
        let storm = calls > 90 && earlyPct < 50 ? " ⚠️风暴(脏源没断/短路失效)" : ""
        NSLog(String(
            format: "[PERF] t=%ds rss=%.0fMB Δrss=%+.1f | apply=%d/5s earlyOut=%d(%d%%) rows=%d%@",
            elapsed, rss, dRSS, calls, early, earlyPct, lastRowCount, storm
        ))
    }

    /// 进程常驻内存(MB)。task_info / MACH_TASK_BASIC_INFO。
    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
