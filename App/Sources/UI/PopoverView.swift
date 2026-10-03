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
                        .fixedSize(horizontal: false, vertical: true)
                    Button("✕") { state.recoveryNotice = nil }.buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }
            if let suggestion = state.switchSuggestion {
                switchBanner(suggestion)
            }
            if let gap = state.pendingIdleGap {
                idleGapBanner(gap)
            }
            Divider().padding(.vertical, 6)
            projectList
            Divider().padding(.vertical, 6)
            totals
            if let report = state.popoverWeekReport {
                WeekChartView(report: report,
                              targetHours: state.effectiveDailyTargetHours,
                              pendingBlocks: state.pendingBlocks,
                              onSelectDay: { day in
                    // Chart days are calendar midnights; nudge past the work-day
                    // boundary so the review window resolves the same logical day.
                    state.reviewFocusDay = day.addingTimeInterval(
                        TimeInterval(state.effectiveDayStartHour * 3600 + 60))
                    openReview()
                })
                    .padding(.top, 8)
            }
            if !state.pendingBlocks.isEmpty { pendingLine }
            footer
        }
        .padding(12)
        .frame(width: 300)
        // The chart and totals are rebuilt on signal ticks; refresh on open so
        // a quiet stretch doesn't show minutes-old numbers.
        .onAppear { state.refreshDerived() }
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

    /// Persistent "looks like you switched" suggestion — the popover twin of
    /// the easy-to-miss switch notification. Stays until acted on or dismissed.
    private func switchBanner(_ suggestion: TimeKeeper.SwitchCandidate) -> some View {
        let name = state.project(suggestion.projectId)?.name ?? suggestion.projectId
        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.swap")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("Working on \(name)?").font(.callout.weight(.medium))
                Text("since \(suggestion.since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Switch") { state.acceptSwitchSuggestion() }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
            Button {
                state.dismissSwitchSuggestion()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Not now — stay on the current project")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
        .padding(.top, 6)
    }

    /// Unresolved "you were away" question — persists here so an unanswered
    /// notification can't silently bill the gap.
    private func idleGapBanner(_ gap: TimeKeeper.IdleGap) -> some View {
        let minutes = Int(gap.to.timeIntervalSince(gap.from) / 60)
        return HStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 0) {
                Text("Away \(Self.hm(gap.to.timeIntervalSince(gap.from)))")
                    .font(.callout.weight(.medium))
                Text("\(gap.from.formatted(date: .omitted, time: .shortened))–\(gap.to.formatted(date: .omitted, time: .shortened)) while clocked in")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep") { state.resolveIdleGap(keep: true, from: gap.from, to: gap.to) }
                .controlSize(.small)
                .help("Bill the \(minutes) min (meeting, whiteboard…)")
            Button("Discard") { state.resolveIdleGap(keep: false, from: gap.from, to: gap.to) }
                .controlSize(.small)
                .help("Split the entry around the gap")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.indigo.opacity(0.10)))
        .padding(.top, 6)
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
                            // Tick while the popover is open (a static Date()
                            // freezes the readout at whatever it was on open).
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Self.hm(entry.duration(asOf: context.date)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
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
                .contextMenu {
                    if !isRunning, state.runningEntry != nil {
                        Button("Move running timer here") {
                            state.reassignRunningEntry(to: project.id)
                        }
                    }
                }
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

    /// Caption for the chart's ghost segments too: the faint stacks above are
    /// exactly this detected-but-unlogged time.
    private var pendingLine: some View {
        let detected = state.pendingBlocks.reduce(0) {
            $0 + $1.end.timeIntervalSince($1.start)
        }
        return HStack(spacing: 4) {
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            Text("\(state.pendingBlocks.count) unlogged block\(state.pendingBlocks.count == 1 ? "" : "s") · \(Self.hm(detected))")
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

    private func openReview() { open("review") }

    private func open(_ id: String) {
        WindowPolicy.shared.present(id: id) { openWindow(id: id) }
    }

    static func hm(_ interval: TimeInterval) -> String {
        let secs = Int(interval)
        return String(format: "%d:%02d", secs / 3600, (secs % 3600) / 60)
    }
}
