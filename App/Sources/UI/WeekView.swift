import SwiftUI
import ClocktopusCore
import AppKit

struct WeekView: View {
    @EnvironmentObject var state: AppState
    @State private var weekAnchor = Date()
    @State private var exportMessage: String?

    private var increment: Double { state.team?.roundingIncrementHours ?? 0.25 }
    private var week: DateInterval { state.workday.weekInterval(for: weekAnchor) }
    private var todayMidnight: Date { state.workday.logicalDayMidnight(for: Date()) }

    /// Everything the week view needs, computed from one store snapshot per
    /// render. The Core report keeps billable and personal rounding separate.
    private func makeReport() -> WeekReport {
        let cal = state.workday.calendar
        let weekStartMidnight = state.workday.logicalDayMidnight(for: week.start)
        let days = (0..<7).compactMap {
            cal.date(byAdding: .day, value: $0, to: weekStartMidnight)
        }
        return WeekReport(entries: (try? state.store.entries(in: week)) ?? [],
                          projects: state.projects, days: days,
                          workday: state.workday, incrementHours: increment,
                          asOf: Date())
    }

    var body: some View {
        let report = makeReport()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("◀") { shift(-1) }
                Text(weekLabel).font(.headline)
                Button("▶") { shift(1) }
                Button("This week") { weekAnchor = Date() }
                Spacer()
                Button("Export CSV…") { export() }
                    .help("Export billable time to CSV — personal projects are excluded")
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    gridTable(report)
                    weekSummary(report)
                }
            }
            if let message = exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Grid

    private func gridTable(_ report: WeekReport) -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                gridContent(report, width: max(760, proxy.size.width))
            }
        }
        .frame(height: gridHeight(report))
    }

    private func gridContent(_ report: WeekReport, width: CGFloat) -> some View {
        let innerWidth = width - 28
        let projectWidth = min(240, max(150, innerWidth * 0.22))
        let totalWidth: CGFloat = 72
        let dayWidth = max(62, (innerWidth - projectWidth - totalWidth - 32) / 7)
        return Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 3) {
            GridRow {
                Text("Project").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: projectWidth, alignment: .leading)
                    .gridColumnAlignment(.leading)
                ForEach(report.days, id: \.self) { day in
                    headerCell(day, width: dayWidth)
                }
                Text("Total").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: totalWidth, alignment: .trailing)
            }
            Divider().gridCellColumns(report.days.count + 2)

            if report.visibleProjects.isEmpty {
                GridRow {
                    Text("No time logged this week.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(width: projectWidth, alignment: .leading)
                    Color.clear.gridCellColumns(report.days.count + 1)
                }
            }

            ForEach(report.visibleProjects) { project in
                GridRow {
                    HStack(spacing: 7) {
                        Circle().fill(state.color(for: project.id)).frame(width: 9, height: 9)
                        Text(project.name).lineLimit(1)
                        if project.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(project.isPrivate ? .secondary : .primary)
                    .frame(width: projectWidth, alignment: .leading)
                    .help(project.isPrivate ? "Personal — tracked here but not exported" : project.name)
                    ForEach(report.days, id: \.self) { day in
                        dayCell(project, day, report, width: dayWidth)
                    }
                    Text(fmt(report.rowTotal[project.id] ?? 0))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(project.isPrivate ? .secondary : .primary)
                        .frame(width: totalWidth, alignment: .trailing)
                }
            }

            Divider().gridCellColumns(report.days.count + 2)
            totalsRow("Billable", dayTotals: report.billableDayTotal,
                      weekTotal: report.billableTotal, report: report,
                      projectWidth: projectWidth, dayWidth: dayWidth,
                      totalWidth: totalWidth, showExportStatus: true)
            if report.personalTotal > 0 {
                totalsRow("Personal", dayTotals: report.personalDayTotal,
                          weekTotal: report.personalTotal, report: report,
                          projectWidth: projectWidth, dayWidth: dayWidth,
                          totalWidth: totalWidth, subdued: true)
            }
            totalsRow("Total tracked", dayTotals: report.trackedDayTotal,
                      weekTotal: report.trackedTotal, report: report,
                      projectWidth: projectWidth, dayWidth: dayWidth,
                      totalWidth: totalWidth, bold: true)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func totalsRow(_ label: String, dayTotals: [Date: Double], weekTotal: Double,
                           report: WeekReport, projectWidth: CGFloat, dayWidth: CGFloat,
                           totalWidth: CGFloat, showExportStatus: Bool = false,
                           subdued: Bool = false, bold: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.callout.weight(bold ? .bold : .semibold))
                .foregroundStyle(subdued ? .tertiary : .secondary)
                .frame(width: projectWidth, alignment: .leading)
            ForEach(report.days, id: \.self) { day in
                HStack(spacing: 2) {
                    if showExportStatus, report.dayExported[day] == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9)).foregroundStyle(.green.opacity(0.8))
                            .help("All billable entries this day have been exported")
                    }
                    Text(fmt(dayTotals[day] ?? 0))
                        .font(.callout.monospacedDigit().weight(bold ? .bold : .semibold))
                }
                .foregroundStyle(subdued ? .secondary : .primary)
                .frame(width: dayWidth, alignment: .trailing)
            }
            Text(fmt(weekTotal))
                .font(.callout.monospacedDigit().weight(bold ? .bold : .semibold))
                .foregroundStyle(subdued ? .secondary : .primary)
                .frame(width: totalWidth, alignment: .trailing)
        }
    }

    private func headerCell(_ day: Date, width: CGFloat) -> some View {
        let isToday = state.workday.calendar.isDate(day, inSameDayAs: todayMidnight)
        return VStack(spacing: 1) {
            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text(day.formatted(.dateTime.day())).font(.caption.monospacedDigit().weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
        }
        .frame(width: width)
    }

    private func dayCell(_ project: Project, _ day: Date, _ report: WeekReport,
                         width: CGFloat) -> some View {
        let hours = report.rounded[project.id]?[day] ?? 0
        let cap = project.isPrivate ? 0.26 : 0.42
        let intensity = report.maxCell > 0 ? min(cap, hours / report.maxCell * cap) : 0
        let exact = report.exact[project.id]?[day] ?? 0
        return Text(hours > 0 ? fmt(hours) : "")
            .font(.callout.monospacedDigit())
            .foregroundStyle(project.isPrivate ? .secondary : .primary)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(state.color(for: project.id).opacity(intensity)))
            .help(hours > 0
                  ? String(format: project.isPrivate ? "Personal — exact %.2fh, not exported" : "Exact %.2fh", exact)
                  : "")
    }

    // MARK: - Summary

    private func weekSummary(_ report: WeekReport) -> some View {
        let totals = report.projectTotals
        let maxT = totals.map(\.hours).max() ?? 1
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 28) {
                summaryMetric("Billable", hours: report.billableTotal)
                summaryMetric("Total tracked", hours: report.trackedTotal)
                if report.personalTotal > 0 {
                    summaryMetric("Personal", hours: report.personalTotal, subdued: true)
                }
                Spacer()
            }
            Divider()
            if totals.isEmpty {
                Text("No time logged this week.").font(.callout).foregroundStyle(.secondary)
            }
            let billable = totals.filter { !$0.project.isPrivate }
            if !billable.isEmpty {
                projectBars(billable, maxHours: maxT)
            }
            let personal = totals.filter(\.project.isPrivate)
            if !personal.isEmpty {
                Text("Personal")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                projectBars(personal, maxHours: maxT)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func summaryMetric(_ label: String, hours: Double, subdued: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(fmt(hours)).font(.title2.weight(.bold).monospacedDigit())
                Text("h").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            .foregroundStyle(subdued ? .secondary : .primary)
        }
    }

    private func projectBars(_ totals: [WeekReport.ProjectTotal], maxHours: Double) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 12) {
            ForEach(totals, id: \.project.id) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(state.color(for: item.project.id)).frame(width: 8, height: 8)
                        Text(item.project.name).font(.callout).lineLimit(1)
                        if item.project.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(fmt(item.hours)).font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(state.color(for: item.project.id).gradient)
                            .frame(width: max(4, proxy.size.width * CGFloat(item.hours / maxHours)))
                            .opacity(item.project.isPrivate ? 0.68 : 1)
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private func gridHeight(_ report: WeekReport) -> CGFloat {
        let footerRows = report.personalTotal > 0 ? 3 : 2
        let projectRows = max(1, report.visibleProjects.count)
        return CGFloat(76 + projectRows * 34 + footerRows * 30)
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
        // time exports later, once closed). The grid shows the running entry's
        // live time, so the CSV can be slightly behind the grid mid-timer.
        let projectById = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
        let snapshot = ((try? state.store.entries(in: week)) ?? []).filter {
            $0.end != nil && projectById[$0.projectId]?.isPrivate == false
        }
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
