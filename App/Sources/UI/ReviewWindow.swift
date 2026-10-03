import SwiftUI
import ClocktopusCore

struct ReviewWindow: View {
    @EnvironmentObject var state: AppState
    // A time inside the selected work-day; set to the current one on appear.
    @State private var selectedDay = Date()
    @State private var selectedTab = "day"
    @State private var showDayPicker = false
    @State private var confirmDismissAll = false

    var body: some View {
        TabView(selection: $selectedTab) {
            dayTab.tabItem { Text("Day") }.tag("day")
            WeekView().tabItem { Text("Week") }.tag("week")
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            if !adoptFocusDay() {
                selectedDay = state.workday.dayInterval(for: Date()).start
            }
        }
        // The popover chart deep-links into an already-open window too.
        .onChange(of: state.reviewFocusDay) { _ in _ = adoptFocusDay() }
    }

    /// Jump to the day the popover chart asked for, consuming the request.
    private func adoptFocusDay() -> Bool {
        guard let focus = state.reviewFocusDay else { return false }
        selectedDay = state.workday.dayInterval(for: focus).start
        selectedTab = "day"
        state.reviewFocusDay = nil
        return true
    }

    private var dayTab: some View {
        VStack(spacing: 0) {
            HStack {
                Button("◀") { shift(-1) }
                dayLabelButton
                Button("▶") { shift(1) }
                Button("Today") { selectedDay = state.workday.dayInterval(for: Date()).start }
                if !state.pendingBlocks.isEmpty { unverifiedMenu }
                Spacer()
            }
            .padding(8)
            DayTimelineView(day: selectedDay)
        }
        .confirmationDialog("Dismiss all \(state.pendingBlocks.count) unverified blocks?",
                            isPresented: $confirmDismissAll) {
            Button("Dismiss all", role: .destructive) { state.dismissBlocks(endedBefore: nil) }
        } message: {
            Text("They disappear from the timeline and won't be suggested again.")
        }
    }

    private var selectedDayInterval: DateInterval { state.workday.dayInterval(for: selectedDay) }
    private var selectedDayLabel: String {
        selectedDay.formatted(.dateTime.weekday(.abbreviated).day().month())
    }

    /// The chip is a menu: with dozens of stale suggestions the one-by-one
    /// flow needs bulk exits. The first two act on the day being viewed —
    /// collapse its same-project slivers into one ghost each, or clear it so
    /// the day can be drawn in from memory.
    private var unverifiedMenu: some View {
        let dayBlocks = state.pendingBlocks(in: selectedDayInterval)
        let runs = state.mergeableBlockRuns(in: selectedDayInterval)
        let fragments = runs.reduce(0) { $0 + $1.count }
        let total = state.pendingBlocks.count
        return Menu {
            Button("Merge \(fragments) nearby blocks on \(selectedDayLabel) into \(runs.count)") {
                state.mergeBlocks(in: selectedDayInterval)
            }
            .disabled(runs.isEmpty)
            Button("Dismiss all \(dayBlocks.count) on \(selectedDayLabel)") {
                state.dismissBlocks(in: selectedDayInterval)
            }
            .disabled(dayBlocks.isEmpty)
            Divider()
            Button("Dismiss all before today") {
                state.dismissBlocks(endedBefore: state.workday.dayInterval(for: Date()).start)
            }
            Button("Dismiss all…", role: .destructive) { confirmDismissAll = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle.fill").font(.caption).foregroundStyle(.orange)
                Text(dayBlocks.count == total
                     ? "\(total) unverified"
                     : "\(dayBlocks.count) unverified · \(total) total")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dashed cards on the timeline — click one to confirm or dismiss, or merge / bulk-dismiss here. "
              + "You can also just draw an entry over them.")
    }

    // Styled like the Week header: the date as text, click for a calendar —
    // replaces the stock spinner DatePicker, which looked out of place.
    private var dayLabelButton: some View {
        Button { showDayPicker.toggle() } label: {
            HStack(spacing: 4) {
                Text(selectedDay.formatted(.dateTime.weekday(.abbreviated).day().month()))
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDayPicker, arrowEdge: .bottom) {
            DatePicker("Day", selection: $selectedDay, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
    }

    private func shift(_ days: Int) {
        selectedDay = state.workday.calendar.date(byAdding: .day, value: days, to: selectedDay)!
    }
}
