import Foundation
@preconcurrency import UserNotifications

enum ReminderAuthorization { case notDetermined, authorized, denied, unavailable }

@MainActor protocol ReminderSchedulingCenter {
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingIDs() async -> [String]
    func remove(_ ids: [String])
    func add(_ reminder: LeadWorkflow.Reminder) async throws
}

@MainActor struct SystemReminderCenter: ReminderSchedulingCenter {
    private var center: UNUserNotificationCenter { .current() }
    func authorization() async -> ReminderAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .authorized
        case .denied: .denied
        default: .unavailable
        }
    }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingIDs() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func remove(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    func add(_ reminder: LeadWorkflow.Reminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = "Open ControlWard to review the record and decide the next action."
        content.sound = .default
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
        components.timeZone = Calendar.current.timeZone
        try await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
}

struct ReminderResult {
    var scheduled = 0
    var message: String
}

/// Serialize edits so a slow reschedule cannot recreate a reminder after a later close/delete/restore.
@MainActor final class ReminderCoordinator {
    private let center: any ReminderSchedulingCenter
    private var previous: Task<ReminderResult, Never>?
    init(center: any ReminderSchedulingCenter) { self.center = center }

    func reconcile(_ desired: [LeadWorkflow.Reminder], requestPermission: Bool) async -> ReminderResult {
        let predecessor = previous
        let job = Task { @MainActor [center] in
            _ = await predecessor?.value
            let pending = await center.pendingIDs().filter {
                $0.hasPrefix("contextward-task-") || $0.hasPrefix("contextward-followup-")
            }
            // Cancellation must work even after permission is revoked. Only our own IDs are touched.
            center.remove(pending)
            guard !desired.isEmpty else { return ReminderResult(message: "No upcoming reminders. Obsolete reminders were cancelled.") }
            var authorization = await center.authorization()
            if authorization == .notDetermined && requestPermission {
                do {
                    let granted = try await center.requestAuthorization()
                    authorization = await center.authorization()
                    if granted { authorization = .authorized }
                    if !granted && authorization == .notDetermined {
                        return ReminderResult(message: "macOS did not grant notification access. Check System Settings → Notifications for this app, then choose Schedule reminders again.")
                    }
                } catch {
                    let error = error as NSError
                    return ReminderResult(message: "macOS could not request notification access (\(error.domain), code \(error.code)). Check System Settings → Notifications, then retry.")
                }
            }
            guard authorization == .authorized else {
                let message: String
                switch authorization {
                case .notDetermined: message = "Reminders need notification permission. Choose Schedule reminders to request it."
                case .denied: message = "Notifications are off for this app. Enable Allow Notifications in System Settings → Notifications, then choose Schedule reminders again."
                default: message = "Notification access is unavailable. Check System Settings → Notifications for this app."
                }
                return ReminderResult(message: message)
            }
            var count = 0
            var failed = 0
            for reminder in desired where reminder.fireAt > .now {
                do { try await center.add(reminder); count += 1 }
                catch { failed += 1 }
            }
            return ReminderResult(scheduled: count, message: failed > 0
                ? "Scheduled \(count) reminders; \(failed) could not be scheduled. Choose Schedule reminders to retry."
                : "Scheduled \(count) local reminder\(count == 1 ? "" : "s"). Dates follow each task or lead.")
        }
        previous = job
        return await job.value
    }
}
