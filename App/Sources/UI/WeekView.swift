import SwiftUI
import ClocktopusCore
import AppKit

struct WeekView: View {
    @EnvironmentObject var state: AppState
    @State private var weekAnchor = Date()
    @State private var exportMessage: String?

    private static let cellWidth: CGFloat = 54
    private var increment: Double { state.team?.roundingIncrementHours ?? 0.25 }
    private var week: DateInterval { state.workday.weekInterval(for: weekAnchor) }
    private var todayMidnight: Date { state.workday.logicalDayMidnight(for: Date()) }

    /// Everything the week view needs, computed once per render. Avoids the
    /// per-cell DB queries + re-rounding that made switching weeks slow.
    private struct WeekData {
        var days: [Date] = []
        var visibleProjects: [Project] = []
        var rounded: [String: [Date: Double]] = [:]   // projectId -> day -> rounded hours
        var exact: [String: [Date: Double]] = [:]      // projectId -> day -> exact hours
        var rowTotal: [String: Double] = [:]
        var dayTotal: [Date: Double] = [:]
        var weekTotal: Double = 0
        var maxCell: Double = 0
        var dayExported: [Date: Bool] = [:]
        var totalsSorted: [(project: Project, hours: Double)] = []
    }

    private func makeWeekData() -> WeekData {
        var data = WeekData()
        let cal = state.workday.calendar
        let weekStartMidnight = state.workday.logicalDayMidnight(for: week.start)
        data.days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStartMidnight) }

        let entries = (try? state.store.entries(in: week)) ?? []   // ONE query per render

        var dayEntries: [Date: [TimeEntry]] = [:]
        for e in entries where e.end != nil {
            let day = state.workday.logicalDayMidnight(for: e.start)
            dayEntries[day, default: []].append(e)
            guard state.project(e.projectId)?.isPrivate != true else { continue }  // private excluded
            data.exact[e.projectId, default: [:]][day, default: 0] += e.duration(asOf: e.end!) / 3600
        }

        // Round once per day (allocate across that day's projects), not per cell.
        for day in data.days {
            var dayExact: [String: Double] = [:]
            for (pid, dh) in data.exact { if let h = dh[day] { dayExact[pid] = h } }
            for (pid, h) in Rounding.allocate(exactHours: dayExact, incrementHours: increment) where h > 0 {
                data.rounded[pid, default: [:]][day] = h
            }
        }

        data.visibleProjects = state.projects.filter { !(data.exact[$0.id]?.isEmpty ?? true) }

        for (pid, dh) in data.rounded {
            var total = 0.0
            for (_, h) in dh { total += h; data.maxCell = max(data.maxCell, h) }
            data.rowTotal[pid] = total
        }
        for day in data.days {
            data.dayTotal[day] = data.rounded.values.reduce(0.0) { $0 + ($1[day] ?? 0) }
        }
        data.weekTotal = data.rowTotal.values.reduce(0, +)
        for day in data.days {
            let closed = dayEntries[day] ?? []
            data.dayExported[day] = !closed.isEmpty && closed.allSatisfy { $0.exportedAt != nil }
        }
        data.totalsSorted = data.visibleProjects
            .map { (project: $0, hours: data.rowTotal[$0.id] ?? 0) }
            .filter { $0.hours > 0 }
            .sorted { $0.hours > $1.hours }
        return data
    }

    var body: some View {
        let data = makeWeekData()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("◀") { shift(-1) }
                Text(weekLabel).font(.headline)
                Button("▶") { shift(1) }
                Button("This week") { weekAnchor = Date() }
                Spacer()
                Button("Export CSV…") { export() }
            }
            HStack(alignment: .top, spacing: 16) {
                gridTable(data)
                weekSummary(data)
            }
            if let message = exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Grid

    private func gridTable(_ data: WeekData) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 2) {
            GridRow {
                Text("Project").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                ForEach(data.days, id: \.self) { day in headerCell(day) }
                Text("Total").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: Self.cellWidth)
            }
            Divider().gridCellColumns(data.days.count + 2)

            ForEach(data.visibleProjects) { project in
                GridRow {
                    HStack(spacing: 7) {
                        Circle().fill(state.color(for: project.id)).frame(width: 9, height: 9)
                        Text(project.name).lineLimit(1)
                    }
                    .frame(minWidth: 120, alignment: .leading)
                    ForEach(data.days, id: \.self) { day in dayCell(project, day, data) }
                    Text(fmt(data.rowTotal[project.id] ?? 0))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .frame(width: Self.cellWidth)
                }
            }

            Divider().gridCellColumns(data.days.count + 2)

            GridRow {
                Text("Day total").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                ForEach(data.days, id: \.self) { day in
                    HStack(spacing: 2) {
                        if data.dayExported[day] == true {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9)).foregroundStyle(.green.opacity(0.8))
                                .help("All entries this day have been exported")
                        }
                        Text(fmt(data.dayTotal[day] ?? 0))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    .frame(width: Self.cellWidth, alignment: .trailing)
                }
                Text(fmt(data.weekTotal)).font(.callout.monospacedDigit().weight(.bold))
                    .frame(width: Self.cellWidth)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
        .fixedSize()
    }

    private func headerCell(_ day: Date) -> some View {
        let isToday = state.workday.calendar.isDate(day, inSameDayAs: todayMidnight)
        return VStack(spacing: 1) {
            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text(day.formatted(.dateTime.day())).font(.caption.monospacedDigit().weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
        }
        .frame(width: Self.cellWidth)
    }

    private func dayCell(_ project: Project, _ day: Date, _ data: WeekData) -> some View {
        let hours = data.rounded[project.id]?[day] ?? 0
        let intensity = data.maxCell > 0 ? min(0.42, hours / data.maxCell * 0.42) : 0
        return Text(hours > 0 ? fmt(hours) : "")
            .font(.callout.monospacedDigit())
            .frame(width: Self.cellWidth, height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(state.color(for: project.id).opacity(intensity)))
            .help(hours > 0 ? String(format: "exact %.2fh", data.exact[project.id]?[day] ?? 0) : "")
    }

    // MARK: - Summary

    private func weekSummary(_ data: WeekData) -> some View {
        let totals = data.totalsSorted
        let maxT = totals.map(\.hours).max() ?? 1
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(fmt(data.weekTotal)).font(.title2.weight(.bold).monospacedDigit())
                    + Text(" h").font(.callout.weight(.medium)).foregroundColor(.secondary)
            }
            Divider()
            if totals.isEmpty {
                Text("No time logged this week.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(totals, id: \.project.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(state.color(for: item.project.id)).frame(width: 8, height: 8)
                        Text(item.project.name).font(.callout).lineLimit(1)
                        Spacer()
                        Text(fmt(item.hours)).font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        Capsule().fill(state.color(for: item.project.id).gradient)
                            .frame(width: max(4, g.size.width * CGFloat(item.hours / maxT)))
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func fmt(_ h: Double) -> String { String(format: "%.2f", h) }

    private var weekLabel: String {
        // Week number and bounds both come from the workday calendar (ISO
        // weeks) — Calendar.current can disagree with the grid's calendar.
        // The interval's real end is dayStartHour on the day after the last
        // logical day; show the last logical day instead.
        let weekNum = state.workday.calendar.component(.weekOfYear, from: week.start)
        let lastDay = state.workday.calendar.date(byAdding: .day, value: 6, to: week.start)!
        return "Week \(weekNum) — \(week.start.formatted(.dateTime.day().month())) – " +
               lastDay.formatted(.dateTime.day().month())
    }

    private func shift(_ weeks: Int) {
        weekAnchor = state.workday.calendar.date(byAdding: .weekOfYear, value: weeks, to: weekAnchor)!
    }

    private func export() {
        guard let personal = state.personal else { return }
        // Single snapshot of closed entries — excludes any running entry (that
        // time exports later, once closed), so the CSV always matches the grid.
        let snapshot = ((try? state.store.entries(in: week)) ?? []).filter { $0.end != nil }
        let alreadyExported = snapshot.filter { $0.exportedAt != nil }
        if !alreadyExported.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(alreadyExported.count) entries in this week were already exported."
            alert.informativeText = "Exporting again may create duplicates in xledger."
            alert.addButton(withTitle: "Export anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let exporter = XledgerExporter(
            employee: personal.employee,
            incrementHours: state.team?.roundingIncrementHours ?? 0.25,
            includeExact: state.effectiveIncludeExactColumn)
        let csv = exporter.csv(entries: snapshot, projects: state.projects,
                               timeZone: .current, asOf: Date(),
                               dayStartHour: state.effectiveDayStartHour)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clocktopus-week\(state.workday.calendar.component(.weekOfYear, from: week.start)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            let now = Date()
            for var entry in snapshot {
                entry.exportedAt = now
                try state.store.save(entry)
            }
            state.refreshDerived()
            exportMessage = "Exported to \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
