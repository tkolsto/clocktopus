import SwiftUI
import ClocktopusCore

struct ReviewWindow: View {
    @EnvironmentObject var state: AppState
    // A time inside the selected work-day; set to the current one on appear.
    @State private var selectedDay = Date()
    @State private var showDayPicker = false

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
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle.fill").font(.caption).foregroundStyle(.orange)
                        Text("\(state.pendingBlocks.count) unverified").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                    .help("Dashed cards on the timeline — click one to confirm or dismiss")
                }
                Spacer()
            }
            .padding(8)
            DayTimelineView(day: selectedDay)
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
