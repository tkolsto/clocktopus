import Foundation
import ClocktopusCore
import Darwin

enum ShellProber {
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh"]

    /// All running pids with their executable names, via sysctl KERN_PROC_ALL.
    ///
    /// NOTE: the process table can grow between the sizing call and the fetch
    /// call (a classic sysctl race), which would otherwise make the fetch
    /// return ENOMEM. We retry a few times with slack added to the reported
    /// size to make that race harmless rather than silently returning [].
    static func allProcesses() -> [(pid: pid_t, name: String, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            // Slack for processes spawned between the sizing call and the fetch.
            size += size / 10 + Int(MemoryLayout<kinfo_proc>.stride)
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let fetchResult = sysctl(&mib, 4, &procs, &size, nil, 0)
            if fetchResult == 0 {
                let count = size / MemoryLayout<kinfo_proc>.stride
                return procs.prefix(count).map { proc in
                    var p = proc
                    let name = withUnsafePointer(to: &p.kp_proc.p_comm) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
                    }
                    return (p.kp_proc.p_pid, name, p.kp_eproc.e_ppid)
                }
            }
            // ENOMEM (still grew) — loop and retry with a fresh size.
        }
        return []
    }

    /// cwd of a pid via proc_pidvnodepathinfo. Returns nil for pids we can't
    /// inspect (other users, entitlement limits, or the pid has since exited).
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Shell cwds + AI-tool cwds. Shells whose ancestor chain includes the
    /// frontmost terminal's pid are .frontmostShell, others .backgroundShell.
    static func probe(aiTools: [String], frontmostTerminalPid: pid_t?) -> [ObservedDir] {
        let processes = allProcesses()
        let parentOf = Dictionary(processes.map { ($0.pid, $0.ppid) },
                                  uniquingKeysWith: { a, _ in a })

        func descendsFromFrontmost(_ pid: pid_t) -> Bool {
            guard let target = frontmostTerminalPid else { return false }
            var current = pid
            for _ in 0..<20 {   // bounded ancestor walk
                if current == target { return true }
                guard let parent = parentOf[current], parent > 1 else { return false }
                current = parent
            }
            return false
        }

        var dirs: [ObservedDir] = []
        for proc in processes {
            if shellNames.contains(proc.name), let path = cwd(of: proc.pid) {
                dirs.append(ObservedDir(
                    path: path,
                    kind: descendsFromFrontmost(proc.pid) ? .frontmostShell : .backgroundShell))
            } else if aiTools.contains(proc.name), let path = cwd(of: proc.pid) {
                dirs.append(ObservedDir(path: path, kind: .aiTool))
            }
        }
        return dirs
    }
}
