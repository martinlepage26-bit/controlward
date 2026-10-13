import Foundation

/// Connector tests: Keychain, key hygiene, PHAROS push, Twenty adapter. All HTTP is
/// served by in-process fakes whose shapes follow the live services
/// (pharos-contextward-api routes; Twenty v2.37 REST `/rest/<plural>` envelopes).
@MainActor
enum IntegrationTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Keychain: save, read, replace, delete round trip", keychainRoundTrip),
            ("Keys: never in workspace.json, exchange export, or activity", keysNeverPersisted),
            ("Status: needs setup -> not verified -> error -> active -> reset on key change", statusTransitions),
            ("PHAROS: Idempotency-Key reused for unchanged data, new for changed data", pharosIdempotencyKey),
            ("PHAROS: push sends Bearer key and exchange.v1 body, records receipt", pharosPushShape),
            ("PHAROS: HTTP and network errors surface on job and status", pharosErrorSurfacing),
            ("Twenty: push requires a preview first", twentyRequiresPreview),
            ("Twenty: changed workspace invalidates preview with zero writes", twentyRejectsStalePreview),
            ("Twenty: dry run counts creates without any request", twentyDryRun),
            ("Twenty: create then update by id map, no duplicates, no deletes", twentyUpsert),
            ("Twenty: relations resolve to Twenty ids", twentyRelations),
            ("Twenty: failure surfaces, keeps progress, retry does not duplicate", twentyErrorAndResume),
            ("Twenty: 429 is retried, 404 on update recreates and relinks", twentyRetryAndRelink),
            ("Twenty: verify is an authenticated GET; 401 is an error", twentyVerify),
            ("Kairos: answered status updates with the same message timestamp and persists", kairosAnsweredWithoutNewMessage),
            ("Kairos: repeat and stale imports preserve local lead state", kairosPreservesLocalState),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Integration tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    // MARK: - Helpers

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    private static func makeStore(secrets: SecretStore = InMemorySecretStore(), transport: HTTPTransport) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: secrets, transport: transport)
        store.twentyPacing = .zero
        store.twentyMaxBackoffSeconds = 0
        return store
    }

    nonisolated private static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private static let pharosURL = "https://pharos-contextward-api.example.test"
    private static let twentyURL = "http://localhost:2020"

    private actor FakeKairos: HTTPTransport {
        private var status = "open"
        private var timestamp = "2026-10-13T12:00:00Z"
        private var message = "Can you help with my project?"

        func set(status: String, timestamp: String = "2026-10-13T12:00:00Z", message: String = "Can you help with my project?") {
            self.status = status
            self.timestamp = timestamp
            self.message = message
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            guard request.httpMethod == "GET", request.url?.path == "/v1/inbox" else {
                throw SmokeTestFailure.failed("unexpected Kairos request")
            }
            return json(200, ["conversations": [[
                "id": "conversation-1", "author_handle": "@prospect", "intent": "lead",
                "priority": 50, "status": status, "last_message_at": timestamp,
                "platform": "youtube", "latest_message": message,
            ]]])
        }
    }

    static func kairosAnsweredWithoutNewMessage() async throws {
        let fake = FakeKairos()
        let store = try makeStore(secrets: InMemorySecretStore([.kairos: "kairos-test-key"]), transport: fake)
        defer { try? FileManager.default.removeItem(at: store.storageURL.deletingLastPathComponent()) }
        let first = await store.importKairosLeads()
        try expect(first.detail == "1 new, 0 updated, 0 unchanged, 0 skipped.", "initial Kairos import failed")
        let original = store.leads[0]
        try expect(original.status == .new, "open conversation was not imported as new")

        // Answering changes conversation status independently of the inbound timestamp.
        await fake.set(status: "answered", message: "Do not overwrite the same-timestamp message")
        let answered = await store.importKairosLeads()
        try expect(answered.detail == "0 new, 1 updated, 0 unchanged, 0 skipped.", "status-only change was not counted as updated")
        try expect(store.leads.count == 1 && store.leads[0].id == original.id, "status update duplicated the lead")
        try expect(store.leads[0].status == .contacted, "answered lead stayed new")
        try expect(store.leads[0].sourceUpdatedAt == original.sourceUpdatedAt && store.leads[0].lastMessage == original.lastMessage, "status update replaced message state")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: store.secrets, transport: fake)
        try expect(reloaded.leads[0] == store.leads[0], "answered status did not persist")
        let repeated = await reloaded.importKairosLeads()
        try expect(repeated.detail == "0 new, 0 updated, 1 unchanged, 0 skipped.", "repeated answered import was not idempotent")
    }

    static func kairosPreservesLocalState() async throws {
        let fake = FakeKairos()
        let store = try makeStore(secrets: InMemorySecretStore([.kairos: "kairos-test-key"]), transport: fake)
        defer { try? FileManager.default.removeItem(at: store.storageURL.deletingLastPathComponent()) }
        _ = await store.importKairosLeads()
        let original = store.leads[0]
        await fake.set(status: "answered", timestamp: "2026-10-12T12:00:00Z", message: "Stale message")
        let stale = await store.importKairosLeads()
        try expect(stale.detail == "0 new, 0 updated, 1 unchanged, 0 skipped." && store.leads[0] == original, "stale conversation changed a lead")

        for status in LeadStatus.allCases where status != .new {
            var lead = original
            lead.status = status
            lead.notes = "Local qualification notes"
            store.update(lead)
            await fake.set(status: "answered")
            let repeated = await store.importKairosLeads()
            try expect(repeated.detail == "0 new, 0 updated, 1 unchanged, 0 skipped." && store.leads[0] == lead, "answered import regressed local \(status) state")

            await fake.set(status: "answered", timestamp: "2026-10-14T12:00:00Z", message: "A newer message")
            let newer = await store.importKairosLeads()
            try expect(newer.detail == "0 new, 1 updated, 0 unchanged, 0 skipped.", "newer message did not update")
            try expect(store.leads[0].lastMessage == "A newer message" && store.leads[0].sourceUpdatedAt == "2026-10-14T12:00:00Z", "newer message state missing")
            try expect(store.leads[0].status == status && store.leads[0].notes == lead.notes, "newer message regressed local state")
        }
    }

    /// Mirrors pharos-api/src/index.ts, including D1 idempotency.
    final class FakePharos: HTTPTransport, @unchecked Sendable {
        let key: String
        private let lock = NSLock()
        private var stored: [String: String] = [:]
        private(set) var requests: [URLRequest] = []
        var failure: HTTPResponse?
        var networkError: Error?
        init(key: String) { self.key = key }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            try lock.withLock {
                requests.append(request)
                if let networkError { throw networkError }
                let path = request.url?.path ?? ""
                if path == "/v1/health" { return json(200, ["ok": true, "service": "pharos-contextward-api", "storage": "d1"]) }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" else { return json(401, ["error": "unauthorized"]) }
                if path == "/v1/auth/check" { return json(200, ["ok": true, "authenticated": true]) }
                guard path == "/v1/exchange/push", request.httpMethod == "POST" else { return json(404, ["error": "not_found"]) }
                if let failure { return failure }
                guard let idem = request.value(forHTTPHeaderField: "Idempotency-Key") else { return json(400, ["error": "missing_idempotency_key"]) }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                guard body?["schemaVersion"] as? String == "contextward.exchange.v1" else { return json(422, ["error": "invalid_exchange_schema"]) }
                if let receipt = stored[idem] { return json(200, ["accepted": true, "persisted": true, "duplicate": true, "receipt": receipt]) }
                let receipt = "receipt_\(UUID().uuidString)"
                stored[idem] = receipt
                return json(202, ["accepted": true, "persisted": true, "receipt": receipt])
            }
        }
        var storedCount: Int { lock.withLock { stored.count } }
        var pushes: [URLRequest] { lock.withLock { requests.filter { $0.url?.path == "/v1/exchange/push" } } }
    }

    /// Mirrors Twenty's REST core controller: POST /rest/<plural> -> 201 {data:{create<Singular>:{...}}},
    /// PATCH /rest/<plural>/<uuid> -> 200 {data:{update<Singular>:{...}}}, GET list -> {data:{<plural>:[...]}}.
    final class FakeTwenty: HTTPTransport, @unchecked Sendable {
        let key: String
        private let lock = NSLock()
        private(set) var records: [String: [String: [String: Any]]] = [:]
        private(set) var methods: [String] = []
        var failOnce: [String: HTTPResponse] = [:] // "POST people" -> response
        init(key: String) { self.key = key }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                let method = request.httpMethod ?? "GET"
                methods.append(method)
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" else {
                    return json(401, ["statusCode": 401, "error": "UNAUTHENTICATED", "messages": ["Token invalid."]])
                }
                let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
                guard parts.first == "rest", parts.count >= 2 else { return json(404, ["error": "NOT_FOUND"]) }
                let object = parts[1]
                if let failure = failOnce.removeValue(forKey: "\(method) \(object)") { return failure }
                let singular = ["companies": "Company", "people": "Person", "opportunities": "Opportunity", "tasks": "Task"][object] ?? "Record"
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                switch (method, parts.count) {
                case ("GET", 2):
                    return json(200, ["data": [object: Array((records[object] ?? [:]).values.prefix(1))], "totalCount": records[object]?.count ?? 0, "pageInfo": ["hasNextPage": false]])
                case ("POST", 2):
                    let id = UUID().uuidString.lowercased()
                    var record = body; record["id"] = id
                    records[object, default: [:]][id] = record
                    return json(201, ["data": ["create\(singular)": record]])
                case ("PATCH", 3):
                    let id = parts[2]
                    guard var record = records[object]?[id] else { return json(404, ["statusCode": 404, "error": "NOT_FOUND"]) }
                    for (field, value) in body { record[field] = value }
                    records[object]?[id] = record
                    return json(200, ["data": ["update\(singular)": record]])
                default:
                    return json(400, ["error": "BAD_REQUEST"])
                }
            }
        }
        func count(_ object: String) -> Int { lock.withLock { records[object]?.count ?? 0 } }
        func all(_ object: String) -> [[String: Any]] { lock.withLock { Array((records[object] ?? [:]).values) } }
        func drop(_ object: String) { lock.withLock { records[object] = [:] } }
        func fail(_ key: String, with response: HTTPResponse) { lock.withLock { failOnce[key] = response } }
        var methodLog: [String] { lock.withLock { methods } }
    }

    private static func seedCRM(_ store: AppStore) {
        var company = Company(); company.name = "Acme Builders"; company.domain = "acme.example"
        store.add(company)
        var lead = Lead.blank(); lead.name = "Jane Client"; lead.company = "Acme Builders"; lead.service = "Kitchen"; lead.quoteAmount = 1_250.5; lead.status = .quoteSent
        store.add(lead)
        var contact = Contact(); contact.firstName = "Jane"; contact.lastName = "Client"; contact.email = "jane@example.test"; contact.companyID = company.id; contact.leadID = lead.id
        store.add(contact)
        var task = CRMTask(); task.title = "Call back"; task.details = "Confirm scope"; task.dueDate = "2026-10-01"; task.status = .inProgress
        store.add(task)
    }

    private static func configuredTwenty() throws -> (AppStore, FakeTwenty) {
        let fake = FakeTwenty(key: "twenty-test-key")
        let store = try makeStore(secrets: InMemorySecretStore([.twenty: "twenty-test-key"]), transport: fake)
        store.setEndpoint(twentyURL, for: .twenty)
        return (store, fake)
    }

    // MARK: - Keychain and key hygiene

    static func keychainRoundTrip() async throws {
        let keychain = KeychainSecretStore(servicePrefix: "com.pharos.contextward.selftest.\(UUID().uuidString)")
        defer { try? keychain.delete(.twenty) }
        try expect(!keychain.exists(.twenty), "fresh test service already has an item")
        try expect(try keychain.read(.twenty) == nil, "missing item did not read as nil")
        try keychain.write("first-secret-value", for: .twenty)
        try expect(keychain.exists(.twenty), "item not found after write")
        try expect(try keychain.read(.twenty) == "first-secret-value", "read back a different value")
        try keychain.write("second-secret-value", for: .twenty)
        try expect(try keychain.read(.twenty) == "second-secret-value", "replace did not update the item")
        try keychain.delete(.twenty)
        try expect(try keychain.read(.twenty) == nil && !keychain.exists(.twenty), "delete left the item behind")
        var threw = false
        do { try keychain.write("", for: .twenty) } catch { threw = true }
        try expect(threw, "empty key was accepted")
        try expect(keychain.service(for: .pharos) .hasSuffix(".pharos"), "service naming changed")
        try expect(KeychainSecretStore().service(for: .pharos) == "com.pharos.contextward.pharos" && KeychainSecretStore().service(for: .twenty) == "com.pharos.contextward.twenty", "production service names changed")
    }

    static func keysNeverPersisted() async throws {
        let pharosKey = "pk_live_\(UUID().uuidString)"
        let twentyKey = "tw_live_\(UUID().uuidString)"
        let fake = FakePharos(key: pharosKey)
        let secrets = InMemorySecretStore()
        let store = try makeStore(secrets: secrets, transport: fake)
        seedCRM(store)
        store.setEndpoint(pharosURL, for: .pharos)
        store.setAPIKey(pharosKey, for: .pharos)
        store.setAPIKey(twentyKey, for: .twenty)
        try expect(store.hasKey(.pharos) && store.hasKey(.twenty), "keys were not reported as saved")
        _ = await store.verifyConnector(.pharos)
        _ = await store.syncToPharos()
        let exportURL = store.storageURL.deletingLastPathComponent().appendingPathComponent("export.json")
        try store.exportExchange(to: exportURL)
        let workspaceText = try String(contentsOf: store.storageURL, encoding: .utf8)
        let exportText = try String(contentsOf: exportURL, encoding: .utf8)
        let pushedText = String(data: fake.pushes.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        for key in [pharosKey, twentyKey] {
            try expect(!workspaceText.contains(key), "API key reached workspace.json")
            try expect(!exportText.contains(key), "API key reached the exchange export")
            try expect(!pushedText.contains(key), "API key reached the pushed exchange body")
            try expect(!store.activity.contains { $0.message.contains(key) }, "API key reached activity")
        }
        try expect(!fake.pushes.isEmpty, "push did not happen, so the body check proved nothing")
    }

    static func statusTransitions() async throws {
        let fake = FakePharos(key: "right-key")
        let store = try makeStore(transport: fake)
        guard case .needsSetup = store.connectorStatus(.pharos) else { throw SmokeTestFailure.failed("empty connector is not Needs setup") }
        store.setEndpoint(pharosURL, for: .pharos)
        guard case .needsSetup(let reason) = store.connectorStatus(.pharos), reason.contains("key") else { throw SmokeTestFailure.failed("URL without key is not Needs setup (key)") }
        store.setAPIKey("wrong-key", for: .pharos)
        try expect(store.connectorStatus(.pharos) == .notVerified, "saved URL and key were reported as something other than Not verified")
        try expect(store.connectorStatus(.pharos).label != "Active", "status became Active without a check")
        try expect(await store.verifyConnector(.pharos) == false, "wrong key verified")
        guard case .error(let failure) = store.connectorStatus(.pharos), failure.contains("401") else { throw SmokeTestFailure.failed("rejected key is not Error with HTTP 401 reason") }
        store.setAPIKey("right-key", for: .pharos)
        try expect(store.connectorStatus(.pharos) == .notVerified, "replacing the key did not reset the status")
        try expect(await store.verifyConnector(.pharos), "right key did not verify")
        guard case .active = store.connectorStatus(.pharos) else { throw SmokeTestFailure.failed("verified connector is not Active") }
        let reloaded = AppStore(storageURL: store.storageURL, secrets: store.secrets, transport: fake)
        guard case .active = reloaded.connectorStatus(.pharos) else { throw SmokeTestFailure.failed("Active status did not persist") }
        store.setEndpoint("https://other.example.test", for: .pharos)
        try expect(store.connectorStatus(.pharos) == .notVerified, "changing the URL did not reset the status")
        store.removeAPIKey(for: .pharos)
        guard case .needsSetup = store.connectorStatus(.pharos) else { throw SmokeTestFailure.failed("removing the key did not return to Needs setup") }
    }

    // MARK: - PHAROS

    private static func configuredPharos() throws -> (AppStore, FakePharos) {
        let fake = FakePharos(key: "pharos-key")
        let store = try makeStore(secrets: InMemorySecretStore([.pharos: "pharos-key"]), transport: fake)
        store.setEndpoint(pharosURL, for: .pharos)
        return (store, fake)
    }

    static func pharosIdempotencyKey() async throws {
        let (store, fake) = try configuredPharos()
        seedCRM(store)
        let first = await store.syncToPharos()
        let second = await store.syncToPharos()
        try expect(first.status == "synced" && second.status == "synced", "push failed: \(first.error ?? "") \(second.error ?? "")")
        let keys = fake.pushes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        try expect(keys.count == 2 && keys[0] == keys[1], "unchanged data did not reuse the Idempotency-Key")
        try expect(fake.storedCount == 1, "backend stored the same snapshot twice")
        try expect(second.detail?.contains("Already stored") == true, "duplicate receipt was not reported")
        var lead = Lead.blank(); lead.name = "New Person"; store.add(lead)
        _ = await store.syncToPharos()
        let third = fake.pushes.last?.value(forHTTPHeaderField: "Idempotency-Key")
        try expect(third != nil && third != keys[0], "changed data reused the old Idempotency-Key")
        try expect(fake.storedCount == 2, "changed snapshot was not stored")
    }

    static func pharosPushShape() async throws {
        let (store, fake) = try configuredPharos()
        let job = await store.syncToPharos()
        guard let push = fake.pushes.first else { throw SmokeTestFailure.failed("no push request was sent") }
        try expect(push.url?.absoluteString == "\(pharosURL)/v1/exchange/push", "wrong push URL \(push.url?.absoluteString ?? "")")
        try expect(push.value(forHTTPHeaderField: "Authorization") == "Bearer pharos-key", "Bearer key missing")
        let body = try JSONDecoder().decode(WorkspaceExchange.self, from: push.httpBody ?? Data())
        try expect(body.schemaVersion == "contextward.exchange.v1", "wrong body schema")
        try expect(job.status == "synced" && job.idempotencyKey?.hasPrefix("ctx_") == true, "job not recorded as synced with key")
        try expect(store.syncJobs.first?.id == job.id && store.syncJobs.first?.status == "synced", "job not stored in the workspace")
        try expect(store.activity.first?.kind == "sync", "no sync activity recorded")
        guard case .active = store.connectorStatus(.pharos) else { throw SmokeTestFailure.failed("successful push did not make PHAROS Active") }
        // A saved full route URL resolves to the same base.
        store.setEndpoint("\(pharosURL)/v1/exchange/push", for: .pharos)
        _ = await store.syncToPharos()
        try expect(fake.pushes.last?.url?.absoluteString == "\(pharosURL)/v1/exchange/push", "route-suffixed endpoint was not normalized")
    }

    static func pharosErrorSurfacing() async throws {
        let (store, fake) = try configuredPharos()
        fake.failure = json(503, ["error": "storage_failure", "idempotencyKey": "x"])
        let failed = await store.syncToPharos()
        try expect(failed.status == "failed", "503 was not recorded as failed")
        try expect(failed.error?.contains("HTTP 503") == true && failed.error?.contains("storage_failure") == true, "503 reason missing: \(failed.error ?? "nil")")
        guard case .error(let reason) = store.connectorStatus(.pharos), reason.contains("503") else { throw SmokeTestFailure.failed("status is not Error with the reason") }
        fake.failure = nil
        fake.networkError = URLError(.notConnectedToInternet)
        let offline = await store.syncToPharos()
        try expect(offline.status == "failed" && offline.error?.hasPrefix("Network error") == true, "network error not surfaced: \(offline.error ?? "nil")")
        fake.networkError = nil
        let noKey = try makeStore(transport: fake)
        noKey.setEndpoint(pharosURL, for: .pharos)
        let missing = await noKey.syncToPharos()
        try expect(missing.status == "failed" && missing.error?.contains("No API key") == true, "missing key not surfaced")
    }

    // MARK: - Twenty

    static func twentyRequiresPreview() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        let job = await store.pushToTwenty()
        try expect(job.status == "failed" && fake.methodLog.isEmpty, "push ran without a preview")
    }

    static func twentyRejectsStalePreview() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        _ = store.previewTwentyPush()
        var task = CRMTask(); task.title = "Added after preview"; store.add(task)
        let before = fake.methodLog.count
        let job = await store.pushToTwenty()
        try expect(job.status == "failed" && job.error?.contains("changed after preview") == true, "stale preview was not rejected")
        try expect(fake.methodLog.count == before, "stale preview made a network request")
        try expect(store.twentyPreview == nil, "stale preview was not cleared")
    }

    static func twentyDryRun() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        let plan = store.previewTwentyPush()
        try expect(fake.methodLog.isEmpty, "dry run made a network request")
        try expect(plan.count(.create, .companies) == 1 && plan.count(.create, .people) == 1 && plan.count(.create, .opportunities) == 1 && plan.count(.create, .tasks) == 1, "dry run counts are wrong: \(plan.summary)")
        try expect(plan.updates == 0 && plan.unchangedTotal == 0, "dry run reported updates on a first push")
    }

    static func twentyUpsert() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        store.previewTwentyPush()
        let first = await store.pushToTwenty()
        try expect(first.status == "synced", "first push failed: \(first.error ?? "")")
        try expect(first.detail == "4 created, 0 updated.", "unexpected first push result: \(first.detail ?? "")")
        try expect(store.workspace.twentyLinks.count == 4, "id map not stored")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: store.secrets, transport: fake)
        try expect(reloaded.workspace.twentyLinks == store.workspace.twentyLinks, "id map did not persist to disk")

        let again = store.previewTwentyPush()
        try expect(again.creates == 0 && again.updates == 0 && again.unchangedTotal == 4, "unchanged data was not recognized: \(again.summary)")
        _ = await store.pushToTwenty()
        try expect(fake.count("companies") == 1 && fake.count("people") == 1 && fake.count("opportunities") == 1 && fake.count("tasks") == 1, "second push duplicated records")

        var company = store.companies[0]; company.domain = "acme-builders.example"; store.update(company)
        let changed = store.previewTwentyPush()
        try expect(changed.count(.update, .companies) == 1 && changed.updates == 1 && changed.creates == 0, "edit was not planned as one update: \(changed.summary)")
        let third = await store.pushToTwenty()
        try expect(third.detail == "0 created, 1 updated.", "unexpected update result: \(third.detail ?? "")")
        try expect(fake.count("companies") == 1 && (fake.all("companies").first?["domainName"] as? [String: Any])?["primaryLinkUrl"] as? String == "https://acme-builders.example", "update did not apply in place")
        try expect(!fake.methodLog.contains("DELETE"), "adapter issued a DELETE")
    }

    static func twentyRelations() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        store.previewTwentyPush()
        _ = await store.pushToTwenty()
        let companyID = fake.all("companies").first?["id"] as? String
        let person = fake.all("people").first
        let opportunity = fake.all("opportunities").first
        let task = fake.all("tasks").first
        try expect(companyID != nil && person?["companyId"] as? String == companyID, "person not linked to the Twenty company")
        try expect(opportunity?["companyId"] as? String == companyID, "opportunity not linked to the Twenty company")
        try expect(opportunity?["pointOfContactId"] as? String == person?["id"] as? String, "opportunity not linked to the Twenty person")
        try expect((opportunity?["amount"] as? [String: Any])?["amountMicros"] as? Int == 1_250_500_000, "amount not converted to micros")
        try expect(opportunity?["stage"] as? String == "PROPOSAL", "lead status not mapped to stage")
        try expect((person?["emails"] as? [String: Any])?["primaryEmail"] as? String == "jane@example.test", "email not mapped")
        try expect(task?["status"] as? String == "IN_PROGRESS" && task?["dueAt"] as? String == "2026-10-01T12:00:00.000Z", "task fields not mapped")
        try expect(!fake.all("companies").contains { ($0["id"] as? String)?.hasPrefix("pending") == true } && !(opportunity?.values.contains { "\($0)".contains("pending:") } ?? true), "placeholder id leaked into Twenty")
    }

    static func twentyErrorAndResume() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        fake.fail("POST people", with: json(400, ["statusCode": 400, "error": "BadRequestException", "messages": ["jane@example.test is invalid"]]))
        store.previewTwentyPush()
        let failed = await store.pushToTwenty()
        try expect(failed.status == "failed" && failed.error?.contains("HTTP 400") == true, "400 not surfaced: \(failed.error ?? "nil")")
        try expect(failed.error?.contains("jane@example.test") == false, "error text leaked record PII")
        guard case .error = store.connectorStatus(.twenty) else { throw SmokeTestFailure.failed("status is not Error after a failed push") }
        try expect(fake.count("companies") == 1 && store.workspace.twentyLinks.count == 1, "progress before the failure was not kept")
        store.previewTwentyPush()
        let retried = await store.pushToTwenty()
        try expect(retried.status == "synced", "retry failed: \(retried.error ?? "")")
        try expect(fake.count("companies") == 1 && fake.count("people") == 1, "retry duplicated records")
    }

    static func twentyRetryAndRelink() async throws {
        let (store, fake) = try configuredTwenty()
        seedCRM(store)
        fake.fail("POST companies", with: json(429, ["error": "TOO_MANY_REQUESTS"], headers: ["retry-after": "0"]))
        store.previewTwentyPush()
        let job = await store.pushToTwenty()
        try expect(job.status == "synced" && fake.count("companies") == 1, "429 was not retried: \(job.error ?? "")")
        fake.drop("tasks")
        var task = store.tasks[0]; task.title = "Call back today"; store.update(task)
        store.previewTwentyPush()
        let relinked = await store.pushToTwenty()
        try expect(relinked.detail == "1 created, 0 updated.", "deleted Twenty record was not recreated: \(relinked.detail ?? relinked.error ?? "")")
        let newID = fake.all("tasks").first?["id"] as? String
        try expect(newID != nil && store.workspace.twentyLinks.values.contains { $0.twentyID == newID }, "id map not relinked")
    }

    static func twentyVerify() async throws {
        let (store, fake) = try configuredTwenty()
        try expect(await store.verifyConnector(.twenty), "valid key did not verify")
        try expect(fake.methodLog == ["GET"], "verify was not a single GET")
        guard case .active = store.connectorStatus(.twenty) else { throw SmokeTestFailure.failed("verified Twenty is not Active") }
        store.setAPIKey("bad-key", for: .twenty)
        try expect(await store.verifyConnector(.twenty) == false, "bad key verified")
        guard case .error(let reason) = store.connectorStatus(.twenty), reason.contains("401") else { throw SmokeTestFailure.failed("401 not surfaced as Error") }
    }
}
