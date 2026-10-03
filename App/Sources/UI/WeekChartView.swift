import SwiftUI
import ClocktopusCore

/// Compact week-at-a-glance chart for the popover: one bar per ISO weekday,
/// stacked by project color, a faint dashed guide at the daily target, and a
/// per-project legend. Uses the report's exact (unrounded) hours so everything
/// ties out with the popover's Week total; rounding stays an export concern.
///
/// Pending (unlogged) detection blocks render as ghost segments on top of the
/// logged time — the week as Clocktopus saw it, not just what was clocked.
/// The scaffold always shows, so an untouched week still reads as a week.
struct WeekChartView: View {
    @EnvironmentObject var state: AppState
    let report: WeekReport
    let targetHours: Double
    let pendingBlocks: [ProvisionalBlock]
    /// Called with the chart day (logical-day midnight) the user clicked.
    let onSelectDay: (Date) -> Void

    @State private var hoveredDay: Date?
    @State private var chartWidth: CGFloat = 276

    private static let chartHeight: CGFloat = 56
    private static let barSpacing: CGFloat = 5
    private static let ghostOpacity = 0.3
    private static let cardWidth: CGFloat = 168

    /// One ghost stripe in a day's bar: a pending block's hours, keyed to its
    /// guessed project (nil = ambiguous evidence, drawn gray).
    private struct GhostSlice {
        let projectId: String?
        let hours: Double
    }

    var body: some View {
        let items = legendItems()
        let ghosts = ghostSlices()
        let maxHours = scaleHours(ghosts: ghosts)
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 0) {
                        HStack(alignment: .bottom, spacing: Self.barSpacing) {
                            ForEach(report.days, id: \.self) { day in
                                dayBar(day, items: items, ghosts: ghosts[day] ?? [],
                                       maxHours: maxHours)
                            }
                        }
                        .frame(height: Self.chartHeight, alignment: .bottom)
                        // Hairline baseline anchors the scaffold on quiet weeks.
                        Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                    }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { chartWidth = geo.size.width }
                            .onChange(of: geo.size.width) { chartWidth = $0 }
                    })
                    if targetHours > 0 {
                        targetGuide(maxHours: maxHours)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let day = hoveredDay {
                        dayCard(day, items: items, ghosts: ghosts[day] ?? [])
                            .frame(width: Self.cardWidth)
                            .offset(x: cardX(for: day), y: -3)
                            // Never steal the hover from the bars beneath.
                            .allowsHitTesting(false)
                    }
                }
                HStack(spacing: Self.barSpacing) {
                    ForEach(report.days, id: \.self) { day in
                        Text(Self.dayLetter(day))
                            .font(.caption2)
                            .fontWeight(day == today ? .bold : .regular)
                            .foregroundStyle(day == today ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            legend(items)
        }
    }

    private var today: Date { state.workday.logicalDayMidnight(for: Date()) }

    /// Projects with tracked time this week and their exact week totals, in
    /// stacking/legend order: billable by hours descending, then private.
    private func legendItems() -> [(project: Project, hours: Double)] {
        report.visibleProjects
            .map { ($0, report.exact[$0.id]?.values.reduce(0, +) ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.0.isPrivate != b.0.isPrivate { return !a.0.isPrivate }
                return a.1 > b.1
            }
    }

    /// Pending hours clipped and split by the displayed workdays, matching
    /// the chart report, merged per guessed project.
    private func ghostSlices() -> [Date: [GhostSlice]] {
        var hoursByProject: [Date: [String?: Double]] = [:]
        for block in pendingBlocks {
            for (day, duration) in state.workday.durations(from: block.start, to: block.end, days: report.days) {
                hoursByProject[day, default: [:]][block.guessedProjectId, default: 0] += duration / 3600
            }
        }
        return hoursByProject.mapValues { perProject in
            perProject.map { GhostSlice(projectId: $0.key, hours: $0.value) }
                // Stable stacking: known projects first, ambiguous gray on top.
                .sorted { ($0.projectId ?? "\u{FFFF}") < ($1.projectId ?? "\u{FFFF}") }
        }
    }

    /// Y-scale: the busiest day (logged + ghost) or the target, whichever is
    /// taller, so the guide line always sits inside the chart.
    private func scaleHours(ghosts: [Date: [GhostSlice]]) -> Double {
        var busiest = 0.0
        for day in report.days {
            var total = 0.0
            for project in report.visibleProjects {
                total += report.exact[project.id]?[day] ?? 0
            }
            for slice in ghosts[day] ?? [] {
                total += slice.hours
            }
            busiest = max(busiest, total)
        }
        return max(targetHours, busiest, 1)
    }

    private func dayBar(_ day: Date, items: [(project: Project, hours: Double)],
                        ghosts: [GhostSlice], maxHours: Double) -> some View {
        // VStack lays out top-down: ghosts sit above the logged stack, and the
        // reversed legend order puts the biggest billable at the bottom.
        VStack(spacing: 0) {
            ForEach(Array(ghosts.enumerated()), id: \.offset) { _, slice in
                Rectangle()
                    .fill(slice.projectId.map { state.color(for: $0) } ?? Color.gray)
                    .opacity(Self.ghostOpacity)
                    .frame(height: max(1, Self.chartHeight * slice.hours / maxHours))
            }
            ForEach(items.reversed(), id: \.project.id) { item in
                let hours = report.exact[item.project.id]?[day] ?? 0
                if hours > 0 {
                    Rectangle()
                        .fill(state.color(for: item.project.id))
                        .frame(height: max(1, Self.chartHeight * hours / maxHours))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .frame(maxWidth: .infinity, alignment: .bottom)
        .opacity(day == today ? 1.0 : 0.55)
        // Full-height hit target so hover/click work above short bars too.
        .frame(height: Self.chartHeight, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredDay = day
            } else if hoveredDay == day {
                // Exit can arrive after the neighbour's enter — don't clobber it.
                hoveredDay = nil
            }
        }
        .onTapGesture { onSelectDay(day) }
    }

    private func cardX(for day: Date) -> CGFloat {
        let index = CGFloat(report.days.firstIndex(of: day) ?? 0)
        let columnWidth = (chartWidth - Self.barSpacing * 6) / 7
        let center = index * (columnWidth + Self.barSpacing) + columnWidth / 2
        return min(max(0, center - Self.cardWidth / 2), chartWidth - Self.cardWidth)
    }

    /// Hover tooltip: the day's logged time per project, then its pending
    /// (detected but unlogged) time, matching the ghost segments above.
    private func dayCard(_ day: Date, items: [(project: Project, hours: Double)],
                         ghosts: [GhostSlice]) -> some View {
        let logged: [(project: Project, hours: Double)] = items.compactMap {
            let hours = report.exact[$0.project.id]?[day] ?? 0
            return hours > 0 ? ($0.project, hours) : nil
        }
        let loggedTotal = logged.reduce(0) { $0 + $1.hours }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.abbreviated).day().month()))
                    .font(.caption.weight(.semibold))
                Spacer()
                if loggedTotal > 0 {
                    Text(PopoverView.hm(loggedTotal * 3600))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
            if logged.isEmpty && ghosts.isEmpty {
                Text("Nothing logged").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(logged, id: \.project.id) { row in
                cardRow(color: state.color(for: row.project.id), solid: true,
                        name: row.project.name, hours: row.hours)
            }
            if !ghosts.isEmpty {
                Divider()
                ForEach(Array(ghosts.enumerated()), id: \.offset) { _, slice in
                    cardRow(color: slice.projectId.map { state.color(for: $0) } ?? .gray,
                            solid: false,
                            name: slice.projectId.map { state.project($0)?.name ?? $0 }
                                  ?? "unmatched",
                            hours: slice.hours)
                }
                Text("detected · not logged")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Text("Click to review this day")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        )
    }

    private func cardRow(color: Color, solid: Bool, name: String,
                         hours: Double) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).opacity(solid ? 1 : Self.ghostOpacity)
                .frame(width: 6, height: 6)
            Text(name).font(.caption)
                .foregroundStyle(solid ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            Text(PopoverView.hm(hours * 3600))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func targetGuide(maxHours: Double) -> some View {
        let y = Self.chartHeight * (1 - targetHours / maxHours)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(targetHours.formatted(.number.precision(.fractionLength(0...1))) + "h")
                .font(.system(size: 8)).foregroundStyle(.secondary)
            DashedHLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(height: 1)
        }
        // Anchor the line itself (not the label above it) at the target height.
        .alignmentGuide(.top) { dims in dims.height - 1 - y }
        .allowsHitTesting(false)
    }

    private func legend(_ items: [(project: Project, hours: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.project.id) { item in
                HStack(spacing: 6) {
                    Circle().fill(state.color(for: item.project.id))
                        .frame(width: 7, height: 7)
                    Text(item.project.emoji.map { "\($0) \(item.project.name)" }
                         ?? item.project.name)
                        .font(.caption)
                    if item.project.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(PopoverView.hm(item.hours * 3600))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func dayLetter(_ day: Date) -> String {
        String(day.formatted(.dateTime.weekday(.abbreviated)).prefix(2))
    }
}

private struct DashedHLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
