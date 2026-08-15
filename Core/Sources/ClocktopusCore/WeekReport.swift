import Foundation

/// A presentation-ready weekly snapshot with exportable and personal time kept
/// separate all the way through rounding and totals.
public struct WeekReport: Sendable {
    public struct ProjectTotal: Sendable {
        public let project: Project
        public let hours: Double
    }

    public let days: [Date]
    public let visibleProjects: [Project]
    public let exact: [String: [Date: Double]]
    public let rounded: [String: [Date: Double]]
    public let rowTotal: [String: Double]
    public let billableDayTotal: [Date: Double]
    public let personalDayTotal: [Date: Double]
    public let trackedDayTotal: [Date: Double]
    public let billableTotal: Double
    public let personalTotal: Double
    public let trackedTotal: Double
    public let maxCell: Double
    public let dayExported: [Date: Bool]
    public let projectTotals: [ProjectTotal]

    public init(entries: [TimeEntry], projects: [Project], days: [Date],
                workday: WorkdayCalendar, incrementHours: Double, asOf: Date) {
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let daysSet = Set(days)
        var exact: [String: [Date: Double]] = [:]
        var closedBillableEntries: [Date: [TimeEntry]] = [:]

        for entry in entries {
            guard let project = projectsById[entry.projectId] else { continue }
            let day = workday.logicalDayMidnight(for: entry.start)
            guard daysSet.contains(day) else { continue }
            if !project.isPrivate, entry.end != nil {
                closedBillableEntries[day, default: []].append(entry)
            }
            exact[entry.projectId, default: [:]][day, default: 0] +=
                entry.duration(asOf: asOf) / 3600
        }

        var rounded: [String: [Date: Double]] = [:]
        for day in days {
            let billableExact: [String: Double] = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
                guard !project.isPrivate, let hours = exact[project.id]?[day] else { return nil }
                return (project.id, hours)
            })
            let personalExact: [String: Double] = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
                guard project.isPrivate, let hours = exact[project.id]?[day] else { return nil }
                return (project.id, hours)
            })
            for allocation in [billableExact, personalExact] {
                for (projectId, hours) in Rounding.allocate(
                    exactHours: allocation, incrementHours: incrementHours
                ) where hours > 0 {
                    rounded[projectId, default: [:]][day] = hours
                }
            }
        }

        let visibleProjects = projects.filter { !(exact[$0.id]?.isEmpty ?? true) }
        var rowTotal: [String: Double] = [:]
        var maxCell = 0.0
        for project in visibleProjects {
            let hours = rounded[project.id]?.values.reduce(0, +) ?? 0
            rowTotal[project.id] = hours
            maxCell = max(maxCell, rounded[project.id]?.values.max() ?? 0)
        }

        var billableDayTotal: [Date: Double] = [:]
        var personalDayTotal: [Date: Double] = [:]
        var trackedDayTotal: [Date: Double] = [:]
        for day in days {
            let billable = projects.lazy.filter { !$0.isPrivate }
                .reduce(0) { $0 + (rounded[$1.id]?[day] ?? 0) }
            let personal = projects.lazy.filter(\.isPrivate)
                .reduce(0) { $0 + (rounded[$1.id]?[day] ?? 0) }
            billableDayTotal[day] = billable
            personalDayTotal[day] = personal
            trackedDayTotal[day] = billable + personal
        }

        let billableTotal = billableDayTotal.values.reduce(0, +)
        let personalTotal = personalDayTotal.values.reduce(0, +)
        let dayExported = closedBillableEntries.mapValues {
            $0.allSatisfy { $0.exportedAt != nil }
        }
        let projectTotals = visibleProjects
            .map { ProjectTotal(project: $0, hours: rowTotal[$0.id] ?? 0) }
            .filter { $0.hours > 0 }
            .sorted {
                if $0.project.isPrivate != $1.project.isPrivate {
                    return !$0.project.isPrivate
                }
                return $0.hours > $1.hours
            }

        self.days = days
        self.visibleProjects = visibleProjects
        self.exact = exact
        self.rounded = rounded
        self.rowTotal = rowTotal
        self.billableDayTotal = billableDayTotal
        self.personalDayTotal = personalDayTotal
        self.trackedDayTotal = trackedDayTotal
        self.billableTotal = billableTotal
        self.personalTotal = personalTotal
        self.trackedTotal = billableTotal + personalTotal
        self.maxCell = maxCell
        self.dayExported = dayExported
        self.projectTotals = projectTotals
    }
}
