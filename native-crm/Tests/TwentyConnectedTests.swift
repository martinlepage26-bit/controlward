import Foundation

/// Opt-in native HTTP acceptance against an official, disposable Twenty test instance.
/// No Keychain, owner workspace, production endpoint, or notification delivery is used.
@MainActor enum TwentyConnectedTests {
    static func run() async throws {
        let endpoint = "http://127.0.0.1:8882"
        let environment = ProcessInfo.processInfo.environment
        guard environment["CONTROLWARD_TEST_TWENTY"] == endpoint,
              let keyFile = environment["CONTROLWARD_TEST_TWENTY_KEY_FILE"] else {
            throw SmokeTestFailure.failed("Use bin/test-connected-twenty with the disposable seeded fixture")
        }
        let key = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-connected-twenty-\(UUID())")
        try SecureFiles.ensurePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = URLSessionTransport()
        let secrets = InMemorySecretStore([.twenty: key])
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: secrets, transport: transport, reviewMode: false)
        store.twentyPacing = .zero
        store.setEndpoint(endpoint, for: .twenty)
        var checked = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw SmokeTestFailure.failed(name) }
            checked += 1; print("PASS connected Twenty: \(name)")
        }
        func record(_ link: TwentyLink) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: endpoint + "/rest/" + link.object.rawValue + "/" + link.twentyID)!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let response = try await transport.send(request)
            guard response.status == 200,
                  let envelope = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let data = envelope["data"] as? [String: Any],
                  let value = data.values.compactMap({ $0 as? [String: Any] }).first,
                  value["id"] as? String == link.twentyID else {
                throw SmokeTestFailure.failed("Real Twenty record could not be verified (HTTP \(response.status))")
            }
            return value
        }
        let wrong = try TwentyClient(endpoint: endpoint, apiKey: "wrong-disposable-test-key", transport: transport, interval: .zero)
        var rejected = false
        do { try await wrong.verify() } catch IntegrationError.http(let status, _, _) { rejected = status == 401 }
        try check(rejected, "real backend rejects a wrong key")
        let verified = await store.verifyConnector(.twenty)
        try check(verified, "native authenticated verify reaches the real service")

        var lead = Lead.blank()
        lead.name = "Camille Synthetic \(UUID())"
        lead.company = "ControlWard disposable \(UUID())"
        lead.email = "camille-disposable@example.test"
        lead.phone = "+15145550199"
        lead.service = "Disposable native connector check"
        lead.quoteAmount = 1234.5
        lead.status = .quoteSent
        guard store.add(lead), let conversion = store.conversionPlan(for: lead), store.convertLead(confirmed: conversion) != nil else {
            throw SmokeTestFailure.failed("Synthetic lead conversion could not be prepared")
        }
        let unconfirmed = await store.pushToTwenty()
        try check(unconfirmed.status == "failed", "native push requires an explicit preview")
        let plan = store.previewTwentyPush()
        try check(plan.creates == 4 && plan.count(.create, .opportunities) == 1, "one converted deal previews one remote opportunity")
        var company = store.companies[0]
        company.domain = "native-disposable.example.test"
        store.update(company)
        let stale = await store.pushToTwenty()
        try check(stale.status == "failed", "changed preview refuses the push")
        _ = store.previewTwentyPush()
        let pushed = await store.pushToTwenty()
        try check(pushed.status == "synced" && store.workspace.twentyLinks.count == 4, "confirmed native push creates four real objects and retains their identities\(pushed.error.map { ": " + $0 } ?? "")")
        func link(_ prefix: String, _ id: UUID) throws -> TwentyLink {
            guard let result = store.workspace.twentyLinks[TwentyMapper.key(prefix, id)] else {
                throw SmokeTestFailure.failed("Saved Twenty identity missing for \(prefix)")
            }
            return result
        }
        let companyLink = try link("company", store.companies[0].id)
        let personLink = try link("contact", store.contacts[0].id)
        let opportunityLink = try link("opportunity", store.opportunities[0].id)
        let taskLink = try link("task", store.tasks[0].id)
        let person = try await record(personLink)
        let opportunity = try await record(opportunityLink)
        let task = try await record(taskLink)
        try check(person["companyId"] as? String == companyLink.twentyID && (person["emails"] as? [String: Any])?["primaryEmail"] as? String == lead.email, "real person retains email and company relationship")
        let amount = opportunity["amount"] as? [String: Any]
        let micros = (amount?["amountMicros"] as? NSNumber)?.int64Value ?? Int64(amount?["amountMicros"] as? String ?? "")
        try check(opportunity["companyId"] as? String == companyLink.twentyID && opportunity["pointOfContactId"] as? String == personLink.twentyID && micros == 1_234_500_000 && amount?["currencyCode"] as? String == "CAD", "real opportunity retains relationships and the exact entered value")
        try check(task["title"] as? String == store.tasks[0].title, "real task retains its title")
        let links = store.workspace.twentyLinks
        let again = store.previewTwentyPush()
        let replay = await store.pushToTwenty()
        try check(again.creates == 0 && again.updates == 0 && again.unchangedTotal == 4 && replay.status == "synced" && store.workspace.twentyLinks == links, "repeat push keeps all four remote identities unchanged")
        company.name += " updated"
        store.update(company)
        _ = store.previewTwentyPush()
        let updated = await store.pushToTwenty()
        let remoteCompany = try await record(companyLink)
        try check(updated.status == "synced" && updated.detail == "0 created, 1 updated." && remoteCompany["name"] as? String == company.name, "edit updates the existing real company in place")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: secrets, transport: transport, reviewMode: false)
        let reloadPlan = reloaded.previewTwentyPush()
        try check(reloaded.workspace.twentyLinks == store.workspace.twentyLinks && reloadPlan.creates == 0 && reloadPlan.updates == 0, "reload retains remote identities and needs no new writes")
        print("Connected Twenty tests: \(checked)/\(checked) passed")
    }
}
