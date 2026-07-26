import Foundation

public struct XledgerExporter {
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
        dayFormatter.dateFormat = "yyyy-MM-dd"
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

        var header = "date,employee,project,activity,hours"
        if includeExact { header += ",exact_hours" }
        header += ",description"

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
                var row = "\(day),\(employee),\(project.xledgerProject)," +
                          "\(project.xledgerActivity),\(format(hours))"
                if includeExact { row += ",\(format(exactHours))" }
                row += ","
                rows.append(row)
            }
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func format(_ hours: Double) -> String {
        String(format: "%.2f", hours)
    }
}
