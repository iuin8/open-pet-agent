import Foundation
import Darwin

/// 读进程 cwd(pid) via libproc(P3 current-project 检测)。
///
/// 用 `proc_pidinfo` + `PROC_PIDVNODEPATHINFO` 拿进程当前工作目录。
/// 用于前台 app cwd → 匹配 `ProjectStore` project rootURL → 自动切 project。
///
/// 限制:GUI app cwd 常为 `/`(启动 cwd)→ 不匹配任何 project → 不切(保持当前);
/// 终端/编辑器 cwd 是项目目录 → 匹配切。需要 Accessibility?不需要(proc_pidinfo 对
/// 其他进程读 cwd 在 macOS 上无需特殊权限,仅返回路径;无路径则 nil)。
enum ProcCWDReader {

    /// 拿进程 cwd。失败/无权限/无 cwd → nil。
    static func cwd(of pid: pid_t) -> URL? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &vnodeInfo,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard size > 0 else { return nil }
        // pvi_cdir.vip_path 是 char[MAXPATHLEN]
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                let path = String(cString: $0)
                return path.isEmpty ? nil : URL(fileURLWithPath: path)
            }
        }
    }
}
