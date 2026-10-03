import Foundation

/// Collapses runs of fragmented same-project ghost blocks into one block, so
/// a day of "Initech? Initech? Initech?" slivers becomes a single suggestion to confirm,
/// resize or dismiss. Pure functions; the app persists the result.
public enum BlockMerging {
    /// Groups blocks (any order) into runs of consecutive blocks that share a
    /// guessed project (nil groups with nil) and sit at most `maxGap` apart.
    /// A block with a different guess in between breaks the run, so merging
    /// never produces a block that overlaps another suggestion. Occupied
    /// intervals also break runs so merging cannot reclaim logged time.
    public static func runs(_ blocks: [ProvisionalBlock], maxGap: TimeInterval,
                            excluding occupied: [DateInterval] = []) -> [[ProvisionalBlock]] {
        let sorted = blocks.sorted { $0.start < $1.start }
        var result: [[ProvisionalBlock]] = []
        for block in sorted {
            if let last = result.last?.last,
               last.guessedProjectId == block.guessedProjectId,
               block.start.timeIntervalSince(last.end) <= maxGap,
               !occupied.contains(where: { interval in
                   let run = result[result.count - 1]
                   let end = max(run.map(\.end).max()!, block.end)
                   return interval.start < end && interval.end > run[0].start
               }) {
                result[result.count - 1].append(block)
            } else {
                result.append([block])
            }
        }
        return result
    }

    /// One fresh pending block spanning the whole run, with the union of its
    /// signals and the distinct evidence parts in first-seen order.
    public static func merged(_ run: [ProvisionalBlock]) -> ProvisionalBlock {
        precondition(!run.isEmpty)
        var parts: [String] = []
        for block in run {
            for part in block.evidence.components(separatedBy: " · ")
            where !part.isEmpty && !parts.contains(part) {
                parts.append(part)
            }
        }
        return ProvisionalBlock(
            guessedProjectId: run[0].guessedProjectId,
            start: run.map(\.start).min()!,
            end: run.map(\.end).max()!,
            confidence: run.map(\.confidence).max()!,
            evidence: parts.joined(separator: " · "),
            signals: run.reduce(into: Set<SignalKind>()) { $0.formUnion($1.signals) })
    }
}
