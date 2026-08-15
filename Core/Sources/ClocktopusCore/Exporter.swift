import Foundation

/// Emits xledger's PM10 "Time Transactions" import file: 24 semicolon-
/// separated columns, yyyymmdd dates, period decimals, and no trailing
/// newline (xledger rejects a blank last line). We fill Employee, Project,
/// Activity, AssignmentDate and WorkingHours/InvoiceHours; every other
/// column stays blank, except Dummy24 which carries the "x" each row in
/// xledger's own example file ends with. The exact-hours option goes into
/// Comment (internal note) — PM10 has no exact-hours column.
public struct XledgerExporter {
    static let separator = ";"
    static let header = [
        "Employee", "Project", "Customer", "Assignment", "Action", "Activity",
        "Position", "ObjectValue", "TimeType", "AssignmentDate", "StartTime",
        "EndTime", "WorkingHours", "InvoiceHours", "Value", "Text", "Comment",
        "Product", "Unit", "UnitPrice", "Quantity", "Dummy22", "Dummy23",
        "Dummy24",
    ].joined(separator: separator)

    let employee: String
    let incrementHours: Double
    let includeExact: Bool

    public init(employee: String, incrementHours: Double, includeExact: Bool) {
        self.employee = employee
        self.incrementHours = incrementHours
        self.includeExact = includeExact
    }

    public func csv(entries: [TimeEntry], projects: [Project],
                    timeZone: TimeZone, asOf now: Date, dayStartHour: Int = 0) -> String {
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let workday = WorkdayCalendar(dayStartHour: dayStartHour, timeZone: timeZone)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyyMMdd"
        dayFormatter.timeZone = timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        // day -> projectId -> exact hours
        var days: [String: [String: Double]] = [:]
        for entry in entries {
            // Skip unknown and private projects — neither belongs in the export.
            guard let project = projectsById[entry.projectId], !project.isPrivate else { continue }
            let day = dayFormatter.string(from: workday.logicalDayMidnight(for: entry.start))
            let hours = entry.duration(asOf: now) / 3600
            days[day, default: [:]][entry.projectId, default: 0] += hours
        }

        var rows: [String] = []
        for day in days.keys.sorted() {
            let exact = days[day]!
            let rounded = Rounding.allocate(exactHours: exact, incrementHours: incrementHours)
            let ordered = rounded
                .compactMap { id, hours -> (Project, Double, Double)? in
                    guard hours > 0, let project = projectsById[id] else { return nil }
                    return (project, hours, exact[id] ?? 0)
                }
                .sorted { $0.0.xledgerProject < $1.0.xledgerProject }
            for (project, hours, exactHours) in ordered {
                var fields = Array(repeating: "", count: 24)
                fields[0] = employee                    // Employee
                fields[1] = project.xledgerProject      // Project
                fields[5] = project.xledgerActivity     // Activity
                fields[9] = day                         // AssignmentDate
                fields[12] = format(hours)              // WorkingHours
                fields[13] = format(hours)              // InvoiceHours
                if includeExact {
                    fields[16] = "exact \(format(exactHours))h"  // Comment
                }
                fields[23] = "x"                        // Dummy24
                rows.append(fields.joined(separator: Self.separator))
            }
        }
        return ([Self.header] + rows).joined(separator: "\n")
    }

    /// PM10 wants "nnnnnn.nn" with minimal decimals — its example file writes
    /// 7.5 and 8, not 7.50 and 8.00.
    private func format(_ hours: Double) -> String {
        var s = String(format: "%.2f", hours)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
