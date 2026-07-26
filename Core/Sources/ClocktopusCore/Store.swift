import Foundation
import GRDB

public final class Store {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    public static func inMemory() throws -> Store {
        try Store(path: ":memory:")
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "timeEntry") { t in
                t.column("id", .text).primaryKey()
                t.column("projectId", .text).notNull()
                t.column("start", .double).notNull()   // unix epoch seconds (UTC)
                t.column("end", .double)
                t.column("source", .text).notNull()
                t.column("note", .text)
                t.column("exportedAt", .double)
            }
            try db.create(table: "provisionalBlock") { t in
                t.column("id", .text).primaryKey()
                t.column("guessedProjectId", .text)
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("confidence", .double).notNull()
                t.column("evidence", .text).notNull()
                t.column("status", .text).notNull()
            }
            try db.create(table: "observation") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("timestamp", .double).notNull().indexed()
                t.column("payload", .text).notNull()   // JSON-encoded Observation
            }
            try db.create(table: "configCache") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2-block-signals") { db in
            // Comma-separated SignalKind raw values, e.g. "terminal,browser".
            try db.alter(table: "provisionalBlock") { t in
                t.add(column: "signals", .text).notNull().defaults(to: "")
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - TimeEntry

    public func save(_ entry: TimeEntry) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO timeEntry (id, projectId, start, "end", source, note, exportedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  projectId = excluded.projectId, start = excluded.start,
                  "end" = excluded."end", source = excluded.source,
                  note = excluded.note, exportedAt = excluded.exportedAt
                """, arguments: [
                    entry.id.uuidString, entry.projectId,
                    entry.start.timeIntervalSince1970,
                    entry.end?.timeIntervalSince1970,
                    entry.source.rawValue, entry.note,
                    entry.exportedAt?.timeIntervalSince1970,
                ])
        }
    }

    public func delete(entryId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM timeEntry WHERE id = ?",
                           arguments: [entryId.uuidString])
        }
    }

    public func runningEntry() throws -> TimeEntry? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM timeEntry WHERE \"end\" IS NULL")
                .map(Self.entry(from:))
        }
    }

    public func entries(in range: DateInterval) throws -> [TimeEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM timeEntry
                WHERE start < ? AND COALESCE("end", ?) > ?
                ORDER BY start
                """, arguments: [range.end.timeIntervalSince1970,
                                 Double.greatestFiniteMagnitude,
                                 range.start.timeIntervalSince1970])
                .map(Self.entry(from:))
        }
    }

    public func closeDanglingEntry(at fallbackEnd: Date) throws -> TimeEntry? {
        guard var dangling = try runningEntry() else { return nil }
        dangling.end = max(fallbackEnd, dangling.start)
        try save(dangling)
        return dangling
    }

    private static func entry(from row: Row) -> TimeEntry {
        TimeEntry(
            id: UUID(uuidString: row["id"])!,
            projectId: row["projectId"],
            start: Date(timeIntervalSince1970: row["start"]),
            end: (row["end"] as Double?).map(Date.init(timeIntervalSince1970:)),
            source: EntrySource(rawValue: row["source"]) ?? .manual,
            note: row["note"],
            exportedAt: (row["exportedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }

    // MARK: - ProvisionalBlock

    public func save(_ block: ProvisionalBlock) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO provisionalBlock (id, guessedProjectId, start, "end",
                                              confidence, evidence, status, signals)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  guessedProjectId = excluded.guessedProjectId,
                  start = excluded.start, "end" = excluded."end",
                  confidence = excluded.confidence, evidence = excluded.evidence,
                  status = excluded.status, signals = excluded.signals
                """, arguments: [
                    block.id.uuidString, block.guessedProjectId,
                    block.start.timeIntervalSince1970, block.end.timeIntervalSince1970,
                    block.confidence, block.evidence, block.status.rawValue,
                    block.signals.map(\.rawValue).sorted().joined(separator: ","),
                ])
        }
    }

    public func pendingBlocks(asOf now: Date) throws -> [ProvisionalBlock] {
        let cutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        return try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE provisionalBlock SET status = 'expired'
                WHERE status = 'pending' AND "end" < ?
                """, arguments: [cutoff])
            return try Row.fetchAll(db, sql: """
                SELECT * FROM provisionalBlock WHERE status = 'pending' ORDER BY start
                """).map { row in
                let signals = (row["signals"] as String? ?? "")
                    .split(separator: ",").compactMap { SignalKind(rawValue: String($0)) }
                return ProvisionalBlock(
                    id: UUID(uuidString: row["id"])!,
                    guessedProjectId: row["guessedProjectId"],
                    start: Date(timeIntervalSince1970: row["start"]),
                    end: Date(timeIntervalSince1970: row["end"]),
                    confidence: row["confidence"],
                    evidence: row["evidence"],
                    signals: Set(signals),
                    status: BlockStatus(rawValue: row["status"]) ?? .pending
                )
            }
        }
    }

    // MARK: - Observations

    public func append(_ obs: Observation) throws {
        let payload = String(data: try JSONEncoder().encode(obs), encoding: .utf8)!
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO observation (timestamp, payload) VALUES (?, ?)",
                           arguments: [obs.timestamp.timeIntervalSince1970, payload])
        }
    }

    public func pruneObservations(olderThan cutoff: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM observation WHERE timestamp < ?",
                           arguments: [cutoff.timeIntervalSince1970])
        }
    }

    public func observationCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observation") ?? 0
        }
    }

    /// Timestamp of the newest recorded observation — used as the honest end
    /// time when recovering a dangling entry after a crash/shutdown.
    public func lastObservationTimestamp() throws -> Date? {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(timestamp) FROM observation")
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    // MARK: - Config cache

    public func cacheTeamConfigTOML(_ toml: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO configCache (key, value) VALUES ('team', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [toml])
        }
    }

    public func lastKnownGoodTeamConfigTOML() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM configCache WHERE key = 'team'")
        }
    }
}
