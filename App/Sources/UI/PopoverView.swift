import SwiftUI
import AppKit
import ClocktopusCore

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = state.recoveryNotice {
                HStack(alignment: .top, spacing: 4) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Button("✕") { state.recoveryNotice = nil }.buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }
            Divider().padding(.vertical, 6)
            projectList
            Divider().padding(.vertical, 6)
            totals
            if !state.pendingBlocks.isEmpty { pendingLine }
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Text("🐙 Clocktopus").font(.headline)
            Spacer()
            if let error = state.configError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.projects) { project in
                let isRunning = state.runningEntry?.projectId == project.id
                Button {
                    isRunning ? state.clockOut() : state.clockIn(projectId: project.id)
                } label: {
                    HStack {
                        Circle().fill(state.color(for: project.id))
                            .frame(width: 7, height: 7)
                        Text(project.emoji.map { "\($0) \(project.name)" } ?? project.name)
                            .fontWeight(isRunning ? .bold : .regular)
                        if project.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Private — tracked but not exported to xledger")
                        }
                        Spacer()
                        if isRunning, let entry = state.runningEntry {
                            Text(Self.hm(entry.duration(asOf: Date())))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "stop.fill")
                                .font(.caption).foregroundStyle(.secondary)
                                .help("Stop")
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption).foregroundStyle(.secondary)
                                .help("Clock in")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if state.projects.isEmpty {
                Text("No projects — check config in Preferences")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var totals: some View {
        HStack {
            Text("Today: \(Self.hm(state.todayTotal))")
            Text("·").foregroundStyle(.secondary)
            Text("Week: \(Self.hm(state.weekTotal))")
        }
        .font(.callout)
        .monospacedDigit()
    }

    private var pendingLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            Text("\(state.pendingBlocks.count) unlogged block\(state.pendingBlocks.count == 1 ? "" : "s")")
            Spacer()
            Button("Review") { openReview() }
                .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.top, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open Review") { openReview() }
            Spacer()
            preferencesButton
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.top, 8)
        .font(.callout)
    }

    private var preferencesButton: some View {
        Button("Preferences") { open("preferences") }
    }

    /// Bring the app forward before opening a window — otherwise an accessory
    /// (LSUIElement) app's window appears behind other apps with no focus.
    private func openReview() { open("review") }

    private func open(_ id: String) {
        WindowPolicy.shared.willOpenWindow()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    static func hm(_ interval: TimeInterval) -> String {
        let secs = Int(interval)
        return String(format: "%d:%02d", secs / 3600, (secs % 3600) / 60)
    }
}
