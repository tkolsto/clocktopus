import SwiftUI
import ClocktopusCore

struct ReviewWindow: View {
    @EnvironmentObject var state: AppState
    // A time inside the selected work-day; set to the current one on appear.
    @State private var selectedDay = Date()
    @State private var showDayPicker = false
    @State private var confirmDismissAll = false

    var body: some View {
        TabView {
            dayTab.tabItem { Text("Day") }
            WeekView().tabItem { Text("Week") }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { selectedDay = state.workday.dayInterval(for: Date()).start }
    }

    private var dayTab: some View {
        VStack(spacing: 0) {
            HStack {
                Button("◀") { shift(-1) }
                dayLabelButton
                Button("▶") { shift(1) }
                Button("Today") { selectedDay = state.workday.dayInterval(for: Date()).start }
                if !state.pendingBlocks.isEmpty {
                    // The chip is a menu: with dozens of stale suggestions the
                    // one-by-one flow needs a bulk exit.
                    Menu {
                        Button("Dismiss all before today") {
                            state.dismissBlocks(endedBefore: state.workday.dayInterval(for: Date()).start)
                        }
                        Button("Dismiss all…", role: .destructive) { confirmDismissAll = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle.fill").font(.caption).foregroundStyle(.orange)
                            Text("\(state.pendingBlocks.count) unverified").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Dashed cards on the timeline — click one to confirm or dismiss, or bulk-dismiss here")
                }
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
