import Foundation

/// Default connector tests use in-process HTTP fakes for key hygiene, PHAROS and Twenty.
/// Opt-in connected tests use real disposable backends. Fake shapes follow the services
/// (pharos-contextward-api routes; Twenty v2.37 REST `/rest/<plural>` envelopes).
@MainActor
enum IntegrationTests {
    private static func pushPharos(_ store: AppStore) async -> SyncJob {
        let fingerprint = store.previewPharosPush()
        return await store.syncToPharos(confirmedFingerprint: fingerprint)
    }
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Keys: never in workspace.json, exchange export, or activity", keysNeverPersisted),
            ("Status: needs setup -> not verified -> error -> active -> reset on key change", statusTransitions),
            ("PHAROS: Idempotency-Key reused for unchanged data, new for changed data", pharosIdempotencyKey),
            ("PHAROS: push requires a current preview and matching confirmation", pharosRequiresPreviewConfirmation),
            ("PHAROS: push sends Bearer key and exchange.v1 body, records receipt", pharosPushShape),
            ("PHAROS: HTTP and network errors surface on job and status", pharosErrorSurfacing),
            ("Twenty: push requires a preview first", twentyRequiresPreview),
            ("Twenty: changed workspace invalidates preview with zero writes", twentyRejectsStalePreview),
            ("Twenty: dry run counts creates without any request", twentyDryRun),
            ("Twenty: a converted lead previews and pushes one opportunity", twentyConvertedDeal),
            ("Twenty: conversion after a prior push reuses its remote deal", twentyConversionReusesRemoteDeal),
            ("Twenty: ambiguous legacy deal identities refuse all writes", twentyAmbiguousLegacyDeals),
            ("Twenty: unwritable storage refuses the push before any request", twentyStoragePreflight),
            ("Twenty: save failure after create resumes without duplicates", twentyStorageFailureAfterCreate),
            ("Twenty: lost create response resumes without duplicates", twentyLostCreateResponse),
            ("Twenty: create then update by id map, no duplicates, no deletes", twentyUpsert),
            ("Twenty: relations resolve to Twenty ids", twentyRelations),
            ("Twenty: failure surfaces, keeps progress, retry does not duplicate", twentyErrorAndResume),
            ("Twenty: 429 is retried, 404 on update recreates and relinks", twentyRetryAndRelink),
            ("Twenty: verify is an authenticated GET; 401 is an error", twentyVerify),
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
        var afterCreateOnce: (@Sendable () throws -> Void)?
        var loseCreateResponseOnce = false
        init(key: String) { self.key = key }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            try lock.withLock {
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
                    let id = body["id"] as? String ?? UUID().uuidString.lowercased()
                    guard records[object]?[id] == nil else { return json(400, ["error": "DUPLICATE_ID"]) }
                    var record = body; record["id"] = id
                    records[object, default: [:]][id] = record
                    if let afterCreate = afterCreateOnce { afterCreateOnce = nil; try afterCreate() }
                    if loseCreateResponseOnce { loseCreateResponseOnce = false; throw URLError(.networkConnectionLost) }
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
        _ = await pushPharos(store)
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

    /// Opt-in real URLSession -> disposable local Worker/D1 acceptance. The runner
    /// supplies this exact loopback endpoint and test-only keys; no owner store is opened.
    static func connectedPharos() async throws {
        let endpoint = "http://127.0.0.1:8881"
        guard ProcessInfo.processInfo.environment["CONTROLWARD_TEST_PHAROS"] == endpoint else {
            throw SmokeTestFailure.failed("Use bin/test-connected-pharos to start the disposable backend")
        }
        let key = "controlward-local-pharos-test"
        let transport = URLSessionTransport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-connected-pharos-\(UUID())")
        try SecureFiles.ensurePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretStore([.pharos: key])
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: secrets, transport: transport, reviewMode: false)
        store.setEndpoint(endpoint, for: .pharos)
        let client = try PharosClient(endpoint: endpoint, apiKey: key, transport: transport)
        var checked = 0
        func check(_ value: Bool, _ name: String) throws {
            try expect(value, name)
            checked += 1
            print("PASS connected PHAROS: \(name)")
        }
        func pushInbox(_ object: [String: Any]) async throws {
            var request = URLRequest(url: URL(string: endpoint + "/v1/leads/push")!)
            request.httpMethod = "POST"
            request.setValue("Bearer controlward-local-leadgen-test", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            let response = try await transport.send(request)
            try expect((200..<300).contains(response.status), "disposable fixture push refused (HTTP \(response.status))")
        }
        let wrong = try PharosClient(endpoint: endpoint, apiKey: "wrong-local-test-key", transport: transport)
        var rejected = false
        do { try await wrong.verify() } catch IntegrationError.http(let status, _, _) { rejected = status == 401 }
        try check(rejected, "real backend rejects a wrong key")
        let verified = await store.verifyConnector(.pharos)
        let active: Bool
        if case .active = store.connectorStatus(.pharos) { active = true } else { active = false }
        try check(verified && active, "authenticated health activates the native connector")
        let unconfirmed = await store.syncToPharos()
        try check(unconfirmed.status == "failed", "unconfirmed exchange is refused")
        let first = await pushPharos(store)
        let duplicate = await pushPharos(store)
        try check(first.status == "synced" && duplicate.status == "synced" && first.idempotencyKey == duplicate.idempotencyKey && duplicate.detail?.contains("Already stored") == true, "identical confirmed exchanges reuse the durable receipt")
        var changed = Lead.blank(); changed.name = "Synthetic exchange change"; store.add(changed)
        let next = await pushPharos(store)
        try check(next.status == "synced" && next.idempotencyKey != first.idempotencyKey, "changed exchange receives a new idempotency key")

        let source = "connected-native-209"
        let event: [String: Any] = ["schema_version": "leadgen.event.v1", "raw_identity": ["first_name": "Camille", "last_name": "Synthetic", "email": "camille-connected@example.test"], "fit_score": 80, "intent_score": 60]
        try await pushInbox(["schema_version": "leadgen.push.v1", "leads": [["source_id": source, "event": event, "test": true]]])
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocker)
        let blocked = AppStore(storageURL: blocker.appendingPathComponent("workspace.json"), secrets: secrets, transport: transport, reviewMode: false)
        blocked.setEndpoint(endpoint, for: .pharos)
        let failed = await blocked.pullLeads()
        let stillPending = try await client.pullLeads(since: 0)
        try check(failed.status == "failed" && stillPending.leads.count == 1, "failed native storage leaves the real inbox unacknowledged")
        let pulled = await store.pullLeads()
        let imported = store.leads.first { $0.sourceID == "leadgen:\(source)" }
        try check(pulled.status == "synced" && imported?.email == "camille-connected@example.test" && store.signals.contains { $0.leadID == imported?.id && $0.fitScore == 80 && $0.intentScore == 60 }, "native pull persists the linked lead and attributed scores")
        let pending = try await client.pullLeads(since: 0)
        try check(pending.leads.isEmpty, "durably saved native pull acknowledges the real inbox")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: secrets, transport: transport, reviewMode: false)
        let replay = await reloaded.pullLeads()
        try check(reloaded.workspace.leadInboxCursor == store.workspace.leadInboxCursor && reloaded.leads == store.leads && replay.status == "synced", "reload and repeated pull preserve identity and cursor")
        try await pushInbox(["schema_version": "leadgen.push.v1", "leads": [], "retract": [source]])
        let retracted = await reloaded.pullLeads()
        try check(retracted.status == "synced" && !reloaded.leads.contains { $0.sourceID == "leadgen:\(source)" } && !reloaded.signals.contains { $0.leadID == imported?.id }, "real tombstone removes the imported lead and signal")
        let remaining = try await client.pullLeads(since: 0)
        try check(remaining.leads.isEmpty, "native client acknowledges the applied tombstone")
        let saved = try String(contentsOf: reloaded.storageURL, encoding: .utf8)
        try check(!saved.contains(key) && !saved.contains("controlward-local-leadgen-test"), "workspace contains no test API keys")
        print("Connected PHAROS tests: \(checked)/\(checked) passed")
    }

    private static func configuredPharos() throws -> (AppStore, FakePharos) {
        let fake = FakePharos(key: "pharos-key")
        let store = try makeStore(secrets: InMemorySecretStore([.pharos: "pharos-key"]), transport: fake)
        store.setEndpoint(pharosURL, for: .pharos)
        return (store, fake)
    }

    static func pharosIdempotencyKey() async throws {
        let (store, fake) = try configuredPharos()
        seedCRM(store)
        let first = await pushPharos(store)
        let second = await pushPharos(store)
        try expect(first.status == "synced" && second.status == "synced", "push failed: \(first.error ?? "") \(second.error ?? "")")
        let keys = fake.pushes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        try expect(keys.count == 2 && keys[0] == keys[1], "unchanged data did not reuse the Idempotency-Key")
        try expect(fake.storedCount == 1, "backend stored the same snapshot twice")
        try expect(second.detail?.contains("Already stored") == true, "duplicate receipt was not reported")
        var lead = Lead.blank(); lead.name = "New Person"; store.add(lead)
        _ = await pushPharos(store)
        let third = fake.pushes.last?.value(forHTTPHeaderField: "Idempotency-Key")
        try expect(third != nil && third != keys[0], "changed data reused the old Idempotency-Key")
        try expect(fake.storedCount == 2, "changed snapshot was not stored")
    }

    static func pharosRequiresPreviewConfirmation() async throws {
        let (store, fake) = try configuredPharos()
        seedCRM(store)
        let rejected = await store.syncToPharos()
        try expect(rejected.status == "failed" && fake.pushes.isEmpty, "push ran without a preview and confirmation")
        let preview = store.previewPharosPush()
        var lead = Lead.blank(); lead.name = "Changed after preview"; store.add(lead)
        let stale = await store.syncToPharos(confirmedFingerprint: preview)
        try expect(stale.status == "failed" && fake.pushes.isEmpty, "stale preview reached the network")
        let fresh = store.previewPharosPush()
        let confirmed = await store.syncToPharos(confirmedFingerprint: fresh)
        try expect(confirmed.status == "synced" && fake.pushes.count == 1, "current confirmed preview did not push")
    }

    static func pharosPushShape() async throws {
        let (store, fake) = try configuredPharos()
        let job = await pushPharos(store)
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
        _ = await pushPharos(store)
        try expect(fake.pushes.last?.url?.absoluteString == "\(pharosURL)/v1/exchange/push", "route-suffixed endpoint was not normalized")
    }

    static func pharosErrorSurfacing() async throws {
        let (store, fake) = try configuredPharos()
        fake.failure = json(503, ["error": "storage_failure", "idempotencyKey": "x"])
        let failed = await pushPharos(store)
        try expect(failed.status == "failed", "503 was not recorded as failed")
        try expect(failed.error?.contains("HTTP 503") == true && failed.error?.contains("storage_failure") == true, "503 reason missing: \(failed.error ?? "nil")")
        guard case .error(let reason) = store.connectorStatus(.pharos), reason.contains("503") else { throw SmokeTestFailure.failed("status is not Error with the reason") }
        fake.failure = nil
        fake.networkError = URLError(.notConnectedToInternet)
        let offline = await pushPharos(store)
        try expect(offline.status == "failed" && offline.error?.hasPrefix("Network error") == true, "network error not surfaced: \(offline.error ?? "nil")")
        fake.networkError = nil
        let noKey = try makeStore(transport: fake)
        noKey.setEndpoint(pharosURL, for: .pharos)
        let missing = await pushPharos(noKey)
        try expect(missing.status == "failed" && missing.error?.contains("No API key") == true, "missing key not surfaced")
    }

    // MARK: - Twenty

    static func twentyConvertedDeal() async throws {
        let (store, fake) = try configuredTwenty()
        var lead = Lead.blank(); lead.name = "Camille Synthetic"; lead.company = "Synthetic Studio"
        lead.email = "converted@example.test"; lead.quoteAmount = 1250
        guard store.add(lead), let conversion = store.conversionPlan(for: lead), store.convertLead(confirmed: conversion) != nil else {
            throw SmokeTestFailure.failed("conversion fixture failed")
        }
        let preview = store.previewTwentyPush()
        try expect(preview.count(.create, .opportunities) == 1 && preview.creates == 4, "one converted deal produced duplicate remote opportunities: \(preview.summary)")
        let job = await store.pushToTwenty()
        try expect(job.status == "synced" && fake.count("opportunities") == 1, "converted deal duplicated in Twenty")
        try expect(store.workspace.twentyLinks[TwentyMapper.key("opportunity", store.opportunities[0].id)] != nil, "canonical opportunity identity was not saved")
    }

    static func twentyConversionReusesRemoteDeal() async throws {
        let (store, fake) = try configuredTwenty()
        var lead = Lead.blank(); lead.name = "Camille Synthetic"; lead.company = "Synthetic Studio"
        lead.email = "converted@example.test"; lead.quoteAmount = 1250
        store.add(lead)
        _ = store.previewTwentyPush(); _ = await store.pushToTwenty()
        let original = store.workspace.twentyLinks[TwentyMapper.key("lead", lead.id)]?.twentyID
        guard let conversion = store.conversionPlan(for: lead), store.convertLead(confirmed: conversion) != nil else {
            throw SmokeTestFailure.failed("conversion fixture failed")
        }
        let plan = store.previewTwentyPush()
        try expect(plan.count(.create, .opportunities) == 0 && plan.count(.update, .opportunities) == 1, "conversion planned another remote deal")
        let job = await store.pushToTwenty()
        let canonical = store.workspace.twentyLinks[TwentyMapper.key("opportunity", store.opportunities[0].id)]?.twentyID
        try expect(job.status == "synced" && fake.count("opportunities") == 1 && canonical == original, "conversion replaced the remote identity")
        let repeated = store.previewTwentyPush()
        try expect(repeated.creates == 0 && repeated.updates == 0 && repeated.unchangedTotal == 4, "canonical identity did not settle after conversion")
    }

    static func twentyAmbiguousLegacyDeals() async throws {
        let (store, fake) = try configuredTwenty()
        var workspace = store.workspace
        var lead = Lead.blank(); lead.name = "Synthetic prior deal"
        let first = Opportunity(name: "First synthetic deal", leadID: lead.id)
        let second = Opportunity(name: "Second synthetic deal", leadID: lead.id)
        workspace.leads = [lead]; workspace.opportunities = [first, second]
        workspace.twentyLinks[TwentyMapper.key("lead", lead.id)] = TwentyLink(twentyID: UUID().uuidString, object: .opportunities, payloadHash: "legacy")
        try SecureFiles.writePrivate(JSONEncoder().encode(workspace), to: store.storageURL)
        let reloaded = AppStore(storageURL: store.storageURL, secrets: store.secrets, transport: fake)
        let preview = reloaded.previewTwentyPush()
        let job = await reloaded.pushToTwenty()
        try expect(!preview.blockers.isEmpty && job.status == "failed" && fake.methodLog.isEmpty, "ambiguous deal identities reached the network")
    }

    static func twentyStoragePreflight() async throws {
        let (store, fake) = try configuredTwenty(); seedCRM(store)
        _ = store.previewTwentyPush()
        let directory = store.storageURL.deletingLastPathComponent()
        let retained = directory.appendingPathExtension("retained-\(UUID())")
        try FileManager.default.moveItem(at: directory, to: retained)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.moveItem(at: retained, to: directory)
        }
        try Data("synthetic storage blocker".utf8).write(to: directory)
        let job = await store.pushToTwenty()
        try expect(job.status == "failed" && fake.methodLog.isEmpty, "unwritable storage still wrote to Twenty or reported success")
    }

    static func twentyStorageFailureAfterCreate() async throws {
        let (store, fake) = try configuredTwenty(); seedCRM(store)
        let directory = store.storageURL.deletingLastPathComponent()
        let retained = directory.appendingPathExtension("retained-\(UUID())")
        fake.afterCreateOnce = {
            try FileManager.default.moveItem(at: directory, to: retained)
            try Data("synthetic storage blocker".utf8).write(to: directory)
        }
        defer {
            if FileManager.default.fileExists(atPath: retained.path) {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.moveItem(at: retained, to: directory)
            }
        }
        _ = store.previewTwentyPush()
        let failed = await store.pushToTwenty()
        try expect(failed.status == "failed" && fake.count("companies") == 1 && fake.count("people") == 0, "failed identity save continued publishing or reported success")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: retained, to: directory)
        let reloaded = AppStore(storageURL: store.storageURL, secrets: store.secrets, transport: fake)
        reloaded.twentyPacing = .zero
        _ = reloaded.previewTwentyPush()
        let resumed = await reloaded.pushToTwenty()
        try expect(resumed.status == "synced" && fake.count("companies") == 1 && fake.count("people") == 1 && fake.count("opportunities") == 1 && fake.count("tasks") == 1, "reload after an identity save failure duplicated remote work")
    }

    static func twentyLostCreateResponse() async throws {
        let (store, fake) = try configuredTwenty(); seedCRM(store)
        fake.loseCreateResponseOnce = true
        _ = store.previewTwentyPush()
        let failed = await store.pushToTwenty()
        try expect(failed.status == "failed" && fake.count("companies") == 1, "lost-response fixture did not store the first remote record")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: store.secrets, transport: fake)
        reloaded.twentyPacing = .zero
        _ = reloaded.previewTwentyPush()
        let resumed = await reloaded.pushToTwenty()
        try expect(resumed.status == "synced" && fake.count("companies") == 1 && fake.count("people") == 1, "lost create response duplicated the remote company")
    }

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
        try expect(store.twentyPreview == nil, "saving an edit left a stale preview enabled")
        let before = fake.methodLog.count
        let job = await store.pushToTwenty()
        try expect(job.status == "failed" && job.error?.lowercased().contains("preview") == true, "push without a fresh preview was not rejected")
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
        try expect(fake.count("companies") == 1 && store.workspace.twentyLinks.values.filter { $0.pendingCreate != true }.count == 1 && store.workspace.twentyLinks.values.filter { $0.pendingCreate == true }.count == 1, "completed company and pending person identities were not kept")
        store.previewTwentyPush()
        let retried = await store.pushToTwenty()
        try expect(retried.status == "synced", "retry failed: \(retried.error ?? "")")
        try expect(fake.count("companies") == 1 && fake.count("people") == 1, "retry duplicated records")
        try expect(store.workspace.twentyLinks.values.allSatisfy { $0.pendingCreate != true }, "successful retry left pending identities")
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
