import SwiftUI
import ClocktopusCore

@main
struct ClocktopusApp: App {
    @StateObject private var state = AppState()
    @State private var bootstrapped = false
    @State private var engine: SignalEngine?

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
        } label: {
            // Startup is anchored to the label, not the popover content: the
            // label renders as soon as the menubar item appears at launch,
            // whereas the popover's `.onAppear` only fires on the first click —
            // which left detection dormant until the user opened the menu.
            menuBarLabel
                .onAppear { startup() }
        }
        .menuBarExtraStyle(.window)

        Window("Clocktopus Review", id: "review") {
            ReviewWindow()
                .environmentObject(state)
        }

        // A plain Window (not the Settings scene): the SwiftUI Settings scene
        // fails to open for an LSUIElement menubar app when no other window is
        // present. This opens reliably via openWindow + activation.
        Window("Clocktopus Preferences", id: "preferences") {
            PreferencesView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }

    /// One-time app startup: config, notifications, and the detection engine.
    /// Runs at launch (anchored to the menubar label's `.onAppear`) so
    /// detection begins immediately, without waiting for the popover to open.
    private func startup() {
        guard !bootstrapped else { return }
        bootstrapped = true
        state.bootstrap()
        WindowPolicy.shared.start()
        Notifier.shared.setup()
        Notifier.shared.onAction = { action in
            switch action {
            case .clockIn(let projectId, let backfillFrom):
                state.clockIn(projectId: projectId, backfillFrom: backfillFrom)
            case .switchProject(let projectId, let at):
                let switchPoint = max(at, state.runningEntry?.start ?? at)
                state.stopRunningEntry(at: switchPoint)
                state.clockIn(projectId: projectId, backfillFrom: switchPoint)
            case .idleGap(let keep, let from, let to):
                state.resolveIdleGap(keep: keep, from: from, to: to)
            }
        }
        engine = SignalEngine(state: state)
        engine?.start()
    }

    // The octopus is a template image: macOS forces it to the standard menubar
    // tint, so state is conveyed by SHAPE, not color (like the old SF Symbols):
    //   • confirmed running        → octopus + live timer text
    //   • detected but unverified  → octopus + "?" (a provisional block is open,
    //     project unconfirmed — the old clock.badge.questionmark)
    //   • idle                     → octopus alone
    // The "?" is a sibling in the layout, not an offset overlay — an overlay
    // that draws outside the icon's bounds is clipped when MenuBarExtra
    // rasterizes the label to its intrinsic size.
    // NB: keep this a single flat HStack. In a MenuBarExtra label, a nested
    // HStack as the first child causes trailing siblings not to render, and
    // Image(systemName:) SF Symbols don't render here either — hence Text("?").
    // Running and the "?" are mutually exclusive, so at most two elements show.
    private var menuBarLabel: some View {
        // HStack spacing is IGNORED when this label is rasterized (measured:
        // 5 vs 9 both render a ~3.5pt gap) — the icon-to-text gap is instead
        // baked into MenuBarOcto as transparent trailing padding in the PNGs.
        HStack(spacing: 0) {
            Image("MenuBarOcto")
            if let entry = state.runningEntry {
                Text(timerText(entry)).monospacedDigit()
            } else if !state.pendingBlocks.isEmpty {
                Text("?").font(.system(size: 12, weight: .bold))
            }
        }
    }

    private func timerText(_ entry: TimeEntry) -> String {
        let secs = Int(entry.duration(asOf: Date()))
        return String(format: "%d:%02d", secs / 3600, (secs % 3600) / 60)
    }
}
