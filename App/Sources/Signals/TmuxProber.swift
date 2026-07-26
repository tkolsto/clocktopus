import Foundation
import ClocktopusCore

enum TmuxProber {
    /// Pane cwds via `tmux list-panes -a`. Empty when tmux is absent or no
    /// server is running — both are silent non-errors per spec.
    static func probe(tmuxPath: String = "/opt/homebrew/bin/tmux") -> [ObservedDir] {
        let candidates = [tmuxPath, "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["list-panes", "-a", "-F",
                             "#{pane_current_path}|#{window_active}|#{pane_active}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }

            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[0].isEmpty else { return nil }
                let isActive = parts[1] == "1" && parts[2] == "1"
                return ObservedDir(path: String(parts[0]),
                                   kind: isActive ? .tmuxActivePane : .tmuxPane)
            }
        } catch { return [] }
    }
}
