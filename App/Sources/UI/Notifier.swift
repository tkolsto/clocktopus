import Foundation
import UserNotifications
import ClocktopusCore

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Set by the app at startup; receives accepted notification actions.
    var onAction: ((Action) -> Void)?

    enum Action {
        case clockIn(projectId: String, backfillFrom: Date?)
        case switchProject(projectId: String, at: Date)
        case idleGap(keep: Bool, from: Date, to: Date)
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let clockIn = UNNotificationCategory(
            identifier: "CLOCK_IN",
            actions: [
                UNNotificationAction(identifier: "clockInBackfill", title: "Clock in (backfill)"),
                UNNotificationAction(identifier: "clockInNow", title: "From now"),
            ],
            intentIdentifiers: [])
        let switchCat = UNNotificationCategory(
            identifier: "SWITCH",
            actions: [UNNotificationAction(identifier: "switchProject", title: "Switch")],
            intentIdentifiers: [])
        let idleGap = UNNotificationCategory(
            identifier: "IDLE_GAP",
            actions: [
                UNNotificationAction(identifier: "keepGap", title: "Keep it"),
                UNNotificationAction(identifier: "discardGap", title: "Discard gap"),
            ],
            intentIdentifiers: [])
        center.setNotificationCategories([clockIn, switchCat, idleGap])
    }

    func nudgeClockIn(project: Project?, since: Date) {
        guard let project else { return }
        post(title: "Clock in to \(project.name)?",
             body: "Activity detected since \(Self.time(since))",
             category: "CLOCK_IN",
             userInfo: ["projectId": project.id, "since": since.timeIntervalSince1970])
    }

    func nudgeSwitch(project: Project?, detectedAt: Date) {
        guard let project else { return }
        post(title: "Switch to \(project.name)?",
             body: "Looks like you changed project around \(Self.time(detectedAt))",
             category: "SWITCH",
             userInfo: ["projectId": project.id, "at": detectedAt.timeIntervalSince1970])
    }

    /// Informational only — the timer already stopped; no actions to take.
    func autoClockedOut(project: Project?, at: Date) {
        guard let project else { return }
        post(title: "Stopped the \(project.name) timer",
             body: "You went idle for a long time — clocked out at \(Self.time(at)). Adjust in Review if wrong.",
             category: "",
             userInfo: [:])
    }

    func askIdleGap(from: Date, to: Date) {
        let minutes = Int(to.timeIntervalSince(from) / 60)
        post(title: "Welcome back",
             body: "Keep the \(minutes) min away (\(Self.time(from))–\(Self.time(to)))?",
             category: "IDLE_GAP",
             userInfo: ["from": from.timeIntervalSince1970, "to": to.timeIntervalSince1970])
    }

    private func post(title: String, body: String, category: String, userInfo: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        Task { @MainActor in
            defer { completion() }
            func date(_ key: String) -> Date? {
                (info[key] as? Double).map(Date.init(timeIntervalSince1970:))
            }
            // NOTE: clockInNow and a plain default tap (opening the app from the
            // banner rather than choosing an action button) are equivalent —
            // both clock in from now. They're kept as separate cases rather than
            // a combined pattern-with-where because Swift won't let a comma-
            // separated case list carry a shared where-clause here.
            switch actionId {
            case "clockInBackfill":
                guard let id = info["projectId"] as? String else { return }
                onAction?(.clockIn(projectId: id, backfillFrom: date("since")))
            case "clockInNow":
                guard let id = info["projectId"] as? String else { return }
                onAction?(.clockIn(projectId: id, backfillFrom: nil))
            case "switchProject":
                guard let id = info["projectId"] as? String, let at = date("at") else { return }
                onAction?(.switchProject(projectId: id, at: at))
            case "keepGap", "discardGap":
                guard let from = date("from"), let to = date("to") else { return }
                onAction?(.idleGap(keep: actionId == "keepGap", from: from, to: to))
            case UNNotificationDefaultActionIdentifier:
                let category = response.notification.request.content.categoryIdentifier
                guard let id = info["projectId"] as? String else { return }
                if category == "SWITCH", let at = date("at") {
                    onAction?(.switchProject(projectId: id, at: at))
                } else if category == "CLOCK_IN" {
                    onAction?(.clockIn(projectId: id, backfillFrom: nil))
                }
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completion:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
