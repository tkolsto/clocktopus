import Foundation

/// Decides the fate of a still-open ("running") time entry found at app launch.
///
/// The app closes at most one dangling entry on startup. If the app was only
/// briefly away (a normal relaunch, a quick crash-and-reopen), the timer should
/// simply continue across the restart. If it was gone longer than a grace
/// window, continuing would silently bill the whole downtime as worked time —
/// so instead the entry is closed at the last time the app recorded activity
/// (its honest end) and a recovery notice is surfaced.
public enum SessionRecovery {
    public enum Decision: Equatable {
        /// Leave the entry open and keep the timer running.
        case keepRunning
        /// Close the dangling entry at this (last-seen) time.
        case close(at: Date)
    }

    /// - Parameters:
    ///   - runningStart: the open entry's start time.
    ///   - lastSeen: when the app last recorded activity (last observation), or
    ///     nil if there are no observations yet.
    ///   - now: the current time.
    ///   - graceSeconds: how long the app may have been down and still continue
    ///     the timer (typically the block-staleness window).
    public static func decide(runningStart: Date,
                              lastSeen: Date?,
                              now: Date,
                              graceSeconds: Double) -> Decision {
        // Downtime is measured from the last moment the app was known alive.
        let reference = lastSeen ?? runningStart
        if now.timeIntervalSince(reference) <= graceSeconds {
            return .keepRunning
        }
        // Past the window: close at the honest end. With no observations there's
        // nothing to trim to, so fall back to now.
        return .close(at: lastSeen ?? now)
    }
}
