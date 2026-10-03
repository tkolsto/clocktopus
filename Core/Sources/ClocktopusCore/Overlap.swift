import Foundation

/// The no-overlap invariant for the timeline: when an entry is saved over a
/// time range, whatever else sits in that range gives way. Logged entries
/// shrink, split or vanish; ghost blocks do the same (a dismissed ghost is a
/// suggestion the user has already answered by logging that time). Pure
/// functions returning the writes to perform — shared by the editor sheet,
/// drag-resize and "Log it", which used to disagree about this.
public enum Overlap {
    public enum EntryAction: Equatable { case save(TimeEntry), delete(UUID) }
    public enum BlockAction: Equatable { case save(ProvisionalBlock), dismiss(UUID) }

    /// Running entries (no end) are never touched here: the keeper owns them
    /// and callers refuse or handle that collision themselves.
    public static func clipEntries(_ entries: [TimeEntry], excluding id: UUID? = nil,
                                   around range: DateInterval) -> [EntryAction] {
        var actions: [EntryAction] = []
        for var other in entries where other.id != id {
            guard let otherEnd = other.end, other.start < range.end, otherEnd > range.start else { continue }
            if other.start >= range.start, otherEnd <= range.end {
                actions.append(.delete(other.id))
            } else if other.start < range.start, otherEnd > range.end {
                var tail = other
                tail.id = UUID(); tail.start = range.end
                other.end = range.start
                actions.append(.save(other)); actions.append(.save(tail))
            } else if other.start < range.start {
                other.end = range.start; actions.append(.save(other))
            } else {
                other.start = range.end; actions.append(.save(other))
            }
        }
        return actions
    }

    public static func clipBlocks(_ blocks: [ProvisionalBlock], around range: DateInterval) -> [BlockAction] {
        var actions: [BlockAction] = []
        for var other in blocks {
            guard other.start < range.end, other.end > range.start else { continue }
            if other.start >= range.start, other.end <= range.end {
                actions.append(.dismiss(other.id))
            } else if other.start < range.start, other.end > range.end {
                var tail = other
                tail.id = UUID(); tail.start = range.end
                other.end = range.start
                actions.append(.save(other)); actions.append(.save(tail))
            } else if other.start < range.start {
                other.end = range.start; actions.append(.save(other))
            } else {
                other.start = range.end; actions.append(.save(other))
            }
        }
        return actions
    }
}
