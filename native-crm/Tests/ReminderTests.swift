import Foundation

@MainActor enum ReminderTests {
    static func run() async -> Bool {
        // Keep AppStore and notification fake cases on MainActor on Swift 6.1 too.
        // The portable runner is nonisolated and cannot receive these closures.
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("automatic reconciliation does not request permission; manual action does", permissionIsExplicit),
            ("denied access cancels obsolete IDs and preserves unrelated notifications", deniedCancels),
            ("permission API errors remain distinct from an owner denial", authorizationError),
            ("partial scheduling failure reports the actual successful count", partialFailure),
            ("a close queued during a slow reschedule leaves no reminder", serializedEdits),
            ("AppStore conversion, date clearing, restore and deletion reconcile notifications", storeLifecycle),
        ]
        var passed = 0
        for (name, test) in cases {
            do { try await test(); passed += 1; print("PASS Reminder: \(name)") }
            catch { print("FAIL Reminder: \(name): \(error)") }
        }
        print("Reminder delivery control tests: \(passed)/\(cases.count) passed")
        return passed == cases.count
    }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        try PortableCheck.expect(value(), message)
    }
    static func sample(_ suffix: String = "one") -> LeadWorkflow.Reminder {
        .init(id: "contextward-task-\(suffix)", title: "Synthetic reminder", fireAt: .now.addingTimeInterval(3600))
    }

    final class FakeCenter: ReminderSchedulingCenter {
        var status: ReminderAuthorization = .authorized
        var requestCalls = 0
        var requestError: Error?
        var failingIDs: Set<String> = []
        var pending: [String: LeadWorkflow.Reminder] = [:]
        var suspendNextAdd = false
        var suspended: CheckedContinuation<Void, Never>?
        func authorization() async -> ReminderAuthorization { status }
        func requestAuthorization() async throws -> Bool {
            requestCalls += 1
            if let requestError { throw requestError }
            status = .authorized
            return true
        }
        func pendingIDs() async -> [String] { Array(pending.keys) }
        func remove(_ ids: [String]) { for id in ids { pending.removeValue(forKey: id) } }
        func add(_ reminder: LeadWorkflow.Reminder) async throws {
            if suspendNextAdd {
                suspendNextAdd = false
                await withCheckedContinuation { suspended = $0 }
            }
            if failingIDs.contains(reminder.id) { throw NSError(domain: "SyntheticNotificationError", code: 7) }
            pending[reminder.id] = reminder
        }
    }

    static func permissionIsExplicit() async throws {
        let center = FakeCenter(); center.status = .notDetermined
        let coordinator = ReminderCoordinator(center: center)
        let automatic = await coordinator.reconcile([sample()], requestPermission: false)
        try expect(automatic.scheduled == 0 && center.requestCalls == 0, "background operation prompted")
        let manual = await coordinator.reconcile([sample()], requestPermission: true)
        try expect(manual.scheduled == 1 && center.requestCalls == 1, "manual action did not request permission")
    }
    static func deniedCancels() async throws {
        let center = FakeCenter(); center.status = .denied
        center.pending = [sample().id: sample(), "unrelated": sample()]
        let result = await ReminderCoordinator(center: center).reconcile([sample("new")], requestPermission: true)
        try expect(center.pending.keys.sorted() == ["unrelated"], "old reminder survived or unrelated notification removed")
        try expect(result.scheduled == 0 && result.message.contains("System Settings") && center.requestCalls == 0, "denied permission lacks recovery path")
    }
    static func authorizationError() async throws {
        let center = FakeCenter(); center.status = .notDetermined
        center.requestError = NSError(domain: "SyntheticNotificationError", code: 9)
        let result = await ReminderCoordinator(center: center).reconcile([sample()], requestPermission: true)
        try expect(result.scheduled == 0 && result.message.contains("code 9"), "permission error was swallowed")
    }
    static func partialFailure() async throws {
        let center = FakeCenter(); center.failingIDs = [sample("bad").id]
        let result = await ReminderCoordinator(center: center).reconcile([sample(), sample("bad")], requestPermission: true)
        try expect(result.scheduled == 1 && result.message.contains("1 could not"), "partial failure was reported as success")
    }
    static func serializedEdits() async throws {
        let center = FakeCenter(); center.suspendNextAdd = true
        let coordinator = ReminderCoordinator(center: center)
        let first = Task { await coordinator.reconcile([sample()], requestPermission: false) }
        for _ in 0..<1000 { if center.suspended != nil { break }; await Task.yield() }
        guard let suspended = center.suspended else { throw PortableCheckFailure(description: "test add did not suspend") }
        let close = Task { await coordinator.reconcile([], requestPermission: false) }
        await Task.yield()
        suspended.resume()
        _ = await first.value; _ = await close.value
        try expect(center.pending.isEmpty, "a stale reschedule recreated a closed reminder")
    }
    static func storeLifecycle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-reminder-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = FakeCenter()
        let store = AppStore(storageURL: dir.appendingPathComponent("workspace.json"), reminderCenter: center)
        var lead = Lead.blank()
        lead.name = "Synthetic buyer"; lead.company = "Synthetic studio"; lead.email = "buyer@example.test"
        lead.nextFollowUp = CalendarCRM.dayString(.now.addingTimeInterval(3 * 86400))
        store.add(lead)
        await store.scheduleTaskReminders()
        try expect(center.pending.count == 1, "unconverted lead missing reminder")
        guard let plan = store.conversionPlan(for: lead), let converted = store.convertLead(confirmed: plan),
              let taskID = converted.taskID else { throw PortableCheckFailure(description: "no converted task") }
        await store.scheduleTaskReminders()
        try expect(Array(center.pending.keys) == ["contextward-task-\(taskID.uuidString)"], "conversion left duplicate legacy reminder")
        let backupURL = dir.appendingPathComponent("backup.json")
        try store.exportControlWardBackup(to: backupURL)
        var updated = store.leads.first { $0.id == lead.id }!
        updated.nextFollowUp = nil
        store.update(updated)
        await store.scheduleTaskReminders()
        try expect(center.pending.isEmpty && store.tasks.first { $0.id == taskID }?.dueDate == nil, "clearing date left reminder")
        try store.restoreControlWardBackup(Data(contentsOf: backupURL), confirmed: true)
        await store.scheduleTaskReminders()
        try expect(center.pending.count == 1, "restore did not rebuild reminders")
        store.delete(store.leads.first { $0.id == lead.id }!)
        await store.scheduleTaskReminders()
        try expect(center.pending.isEmpty, "deleted lead retained follow-up reminder")
        var due = Lead.blank()
        due.name = "Synthetic due lead"; due.nextFollowUp = CalendarCRM.dayString()
        store.add(due)
        if let rule = store.automationRules.first(where: { $0.trigger == .dueFollowUp }) { store.setAutomation(rule, enabled: true) }
        _ = store.runAutomations()
        guard let automated = store.leads.first(where: { $0.id == due.id }), let followUpID = automated.followUpTaskID else {
            throw PortableCheckFailure(description: "automation did not register the follow-up task as the next action")
        }
        let reminderPlan = LeadWorkflow.reminders(in: store.workspace, now: .distantPast)
        try expect(reminderPlan.contains { $0.id == "contextward-task-\(followUpID.uuidString)" }, "automated task has no reminder")
        try expect(!reminderPlan.contains { $0.id == "contextward-followup-\(due.id.uuidString)" }, "automated task duplicated the lead reminder")
        try store.completeTask(followUpID, completed: true)
        let taskCount = store.tasks.count
        _ = store.runAutomations()
        try expect(store.tasks.count == taskCount && store.tasks.first { $0.id == followUpID }?.status == .done, "automation revived a completed next action")
    }
}
