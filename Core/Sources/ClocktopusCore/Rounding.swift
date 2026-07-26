import Foundation

public enum Rounding {
    /// Largest-remainder allocation: rounds each project's exact hours to
    /// multiples of `incrementHours` such that the rows sum to the day's
    /// exact total rounded to the nearest increment.
    public static func allocate(exactHours: [String: Double],
                                incrementHours: Double) -> [String: Double] {
        guard !exactHours.isEmpty, incrementHours > 0 else { return [:] }

        let totalUnits = Int((exactHours.values.reduce(0, +) / incrementHours).rounded())

        // Floor each row to whole units, remember fractional remainders.
        var floors: [String: Int] = [:]
        var remainders: [(key: String, frac: Double)] = []
        for (key, hours) in exactHours {
            let units = hours / incrementHours
            let floor = Int(units.rounded(.down))
            floors[key] = floor
            remainders.append((key, units - Double(floor)))
        }

        // Hand out the missing units to the largest remainders first.
        // Ties broken by key for determinism.
        var leftover = totalUnits - floors.values.reduce(0, +)
        for (key, _) in remainders.sorted(by: { ($0.frac, $1.key) > ($1.frac, $0.key) }) {
            guard leftover > 0 else { break }
            floors[key]! += 1
            leftover -= 1
        }

        return floors.mapValues { Double($0) * incrementHours }
    }
}
