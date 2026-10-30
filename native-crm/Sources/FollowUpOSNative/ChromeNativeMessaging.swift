import AppKit
import CryptoKit
import Foundation

/// Chrome Native Messaging host. Chrome enforces `allowed_origins` in the installed host manifest;
/// this process adds a local pairing token, strict bounded messages, and per-operation confirmation.
final class ChromeNativeMessagingHost: @unchecked Sendable {
    private static let protocolVersion = 1
    private static let maxMessageBytes = 256 * 1024
    private static let maxStaged = 8
    private static let stageLifetime: TimeInterval = 5 * 60

    private struct Pairing: Codable {
        var extensionID: String
        var tokenSHA256: String
        var pairedAt: Date
    }

    private struct Capture: Equatable {
        var segmentID: String
        var businessName: String
        var websiteURL: String
        var municipality: String?
        var sourceURL: String
    }

    private struct StagedCapture {
        var record: ProspectRecord
        var duplicateID: String?
        var createdAt: Date
    }

    private var stages: [String: StagedCapture] = [:]
    private let now: () -> Date = { Date() }

    func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await runLoop()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func runLoop() async {
        while let frame = Self.readFrame() {
            let response = await handle(frame)
            Self.writeFrame(response)
        }
    }

    private func handle(_ frame: Data) async -> Data {
        do {
            guard frame.count <= Self.maxMessageBytes else { throw BridgeFailure("message-too-large", "Request exceeded the 256 KiB limit.") }
            guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                throw BridgeFailure("invalid-json", "Request must be one JSON object.")
            }
            let allowed = Set(["version", "requestID", "op", "extensionID", "token", "capture", "previewID", "decision", "confirm"])
            guard Set(object.keys).isSubset(of: allowed) else { throw BridgeFailure("unknown-field", "Request contains an unsupported field.") }
            guard Self.integer(object["version"]) == Self.protocolVersion else { throw BridgeFailure("version", "Unsupported bridge protocol version.") }
            let requestID = try Self.string(object["requestID"], field: "requestID", limit: 80)
            let op = try Self.string(object["op"], field: "op", limit: 40)
            let extensionID = try Self.string(object["extensionID"], field: "extensionID", limit: 32)
            guard Self.isExtensionID(extensionID) else { throw BridgeFailure("extension-id", "The extension ID is invalid.") }

            let payload: [String: Any]
            switch op {
            case "status":
                try Self.requireKeys(object, exactly: ["version", "requestID", "op", "extensionID"])
                let pairing = try readPairing()
                if let pairing, pairing.extensionID != extensionID { throw BridgeFailure("paired-to-other-extension", "ControlWard is paired to a different extension ID. Unpair it before pairing another copy.") }
                guard let configDirectory = ICPConfig.defaultDirectory(bundle: AppResources.bundle) else {
                    throw BridgeFailure("config-missing", "The bundled ControlWard lead rules are unavailable.")
                }
                let config = try ICPConfig.load(directory: configDirectory)
                let segments = config.segments.map { ["id": $0.id, "label": $0.label, "priority": $0.priority] as [String: Any] }
                payload = ["paired": pairing != nil, "hostVersion": "1.0.0", "rules": "ControlWard native lead pipeline", "segments": segments]
            case "pair":
                try Self.requireKeys(object, exactly: ["version", "requestID", "op", "extensionID"])
                let path = pairingURL()
                if FileManager.default.fileExists(atPath: path.path) {
                    let pairing = try readPairing()
                    guard pairing?.extensionID == extensionID else { throw BridgeFailure("paired-to-other-extension", "A different extension is already paired.") }
                    throw BridgeFailure("already-paired", "This extension is already paired. Use Unpair first to create a new pairing.")
                }
                let token = Self.randomToken()
                let pairing = Pairing(extensionID: extensionID, tokenSHA256: Self.sha256(token), pairedAt: now())
                try SecureFiles.writePrivate(JSONEncoder.iso.encode(pairing), to: path)
                payload = ["paired": true, "pairingToken": token, "hostVersion": "1.0.0"]
            case "unpair":
                try Self.requireKeys(object, exactly: ["version", "requestID", "op", "extensionID", "token"])
                try authenticate(object, extensionID: extensionID, tokenValue: object["token"])
                try FileManager.default.removeItem(at: pairingURL())
                stages.removeAll()
                payload = ["paired": false]
            case "evaluate":
                try Self.requireKeys(object, exactly: ["version", "requestID", "op", "extensionID", "token", "capture"])
                try authenticate(object, extensionID: extensionID, tokenValue: object["token"])
                let capture = try parseCapture(object["capture"])
                payload = try await evaluate(capture)
            case "save":
                try Self.requireKeys(object, exactly: ["version", "requestID", "op", "extensionID", "token", "previewID", "decision", "confirm"])
                try authenticate(object, extensionID: extensionID, tokenValue: object["token"])
                guard Self.isJSONTrue(object["confirm"]) else { throw BridgeFailure("confirmation-required", "Confirm the save in the extension before sending it.") }
                let previewID = try Self.string(object["previewID"], field: "previewID", limit: 80)
                let decision = try Self.string(object["decision"], field: "decision", limit: 20)
                payload = try await save(previewID: previewID, decision: decision)
            default:
                throw BridgeFailure("unsupported-operation", "This bridge operation is not supported.")
            }
            return Self.response(requestID: requestID, payload: payload)
        } catch let failure as BridgeFailure {
            return Self.errorResponse(for: frame, code: failure.code, message: failure.message)
        } catch {
            return Self.errorResponse(for: frame, code: "bridge-error", message: "ControlWard could not complete this step. Check its local lead configuration and try again.")
        }
    }

    private func evaluate(_ capture: Capture) async throws -> [String: Any] {
        guard let directory = ICPConfig.defaultDirectory(bundle: AppResources.bundle) else {
            throw BridgeFailure("config-missing", "The bundled ControlWard lead rules are unavailable.")
        }
        let environment = try LeadPipelineEnvironment.load(configDirectory: directory)
        guard let segment = environment.config.segment(capture.segmentID) else {
            throw BridgeFailure("unknown-segment", "Choose a segment listed by ControlWard.")
        }
        guard let source = URL(string: capture.sourceURL), Self.isHTTPURL(source) else {
            throw BridgeFailure("source-url", "The capture source must be an HTTP or HTTPS page.")
        }
        guard let website = ProspectSearchRun.siteURL(capture.websiteURL), Self.isHTTPURL(website),
              GuardedLeadTransport.ownSiteHostRefusal(website) == nil,
              let host = website.host?.lowercased() else {
            throw BridgeFailure("website-url", "Choose a public business website on a standard HTTP or HTTPS host.")
        }
        let domain = HostMatch.registrable(host)
        guard environment.config.deniedHost(host) == nil, !environment.config.isNeverFetch(host: host) else {
            throw BridgeFailure("website-blocked", "ControlWard policy blocks fetching this website.")
        }

        let audit = environment.audit
        let clock = SystemLeadClock()
        let guarded = GuardedLeadTransport(config: environment.config, inner: URLSessionLeadTransport(), audit: audit, clock: clock)
        var search = ProspectSearchRun(config: environment.config, transport: guarded, audit: audit, clock: clock,
                                       suppression: SuppressionList(storageURL: environment.suppressionURL))
        var rbq: RBQIndex?
        var rbqFailure: String?
        do {
            rbq = try environment.cachedRBQIndex()
        } catch {
            rbqFailure = (error as? LeadPipelineRefusal)?.code ?? "error:rbq-cache"
            audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "rbq-load", target: RBQOpenData.sourceID,
                                    source: "rbq_open_data", result: rbqFailure!, receipt: "chrome-extension"))
        }
        search.rbq = rbq
        search.rbqFailure = rbqFailure
        let candidate = LeadCandidate(osmID: Self.captureIdentity(name: capture.businessName, url: website),
                                      name: capture.businessName, website: website.absoluteString, tags: [],
                                      city: nil, latitude: 0, longitude: 0,
                                      discoveredVia: "explicit-chrome-capture")
        audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "chrome-capture", register: CWAuditLine.register(for: source),
                                target: segment.id, source: "chrome-extension", result: "requested", receipt: "user-triggered"))
        let pages = await search.fetchSite(website, domain: domain, segment: segment)
        guard !pages.isEmpty else { throw BridgeFailure("site-unavailable", "ControlWard could not fetch a permitted page from this site. Check the URL, robots rules, and network, then retry.") }
        guard !ProspectIdentity.siteSaysClosed(pages) else { throw BridgeFailure("closed-business", "ControlWard’s existing page checks identified this business as closed.") }
        var record = ProspectSearchRun.prospect(from: candidate, pages: pages, domain: domain,
                                                segment: segment, config: environment.config,
                                                runID: "chrome-\(UUID().uuidString.lowercased())")
        record.id = "cw:chrome:\(candidate.osmID.dropFirst("chrome:".count))"
        record.provenance = .externalSearch
        record.fetcher = "chrome-extension"
        // The typed municipality is only a UI hint. It is deliberately excluded from qualification and RBQ matching.
        record.town = nil
        if let failure = rbqFailure {
            record.rbqCheck = "error:\(failure)"
        } else if let source = RBQOpenData.source(environment.config), let rbq {
            rbq.enrich(&record, municipality: nil, source: source)
        } else {
            record.rbqCheck = "unavailable"
        }
        let verdict = LeadDefinition.evaluate(record, config: environment.config, now: clock.now)
        record.status = verdict.status
        record.reasons = verdict.reasons
        record.risk = LeadDefinition.riskLine(record)
        guard verdict.status != .drop else { throw BridgeFailure("not-a-lead", "ControlWard’s current rules rejected this capture: \(verdict.reasons.joined(separator: "; ")).") }

        let store = ProspectLeadsStore(fileURL: environment.storeURL)
        let existing = try store.snapshot()
        let duplicate = ProspectIngest.duplicate(of: record, in: existing)
        let previewID = UUID().uuidString.lowercased()
        stages = stages.filter { now().timeIntervalSince($0.value.createdAt) <= Self.stageLifetime }
        guard stages.count < Self.maxStaged else { throw BridgeFailure("too-many-previews", "Close or save an earlier preview before evaluating another capture.") }
        stages[previewID] = StagedCapture(record: record, duplicateID: duplicate?.id, createdAt: now())
        let fields = Self.evidenceFields(record)
        let reasons = verdict.reasons
        let duplicatePayload: [String: Any] = duplicate.map { [
            "id": $0.id,
            "name": $0.organisation,
            "domain": $0.businessDomain ?? "",
            "email": $0.email ?? "",
            "phone": $0.phone ?? "",
            "status": $0.status.rawValue
        ] } ?? [:]
        return ["previewID": previewID, "status": record.status.rawValue, "reasons": reasons,
                "segment": segment.label, "fields": fields, "duplicate": duplicate != nil,
                "existing": duplicatePayload, "canSave": true,
                "captureTime": record.fetchedAt.map(CWAuditLine.timestamp) ?? CWAuditLine.timestamp(clock.now),
                "qualificationNote": "ControlWard verdict only; a held or incomplete record is not marketing approval. The municipality input is an unverified hint and is not used in location or RBQ rules. No outreach is created or sent."]
    }

    private func save(previewID: String, decision: String) async throws -> [String: Any] {
        stages = stages.filter { now().timeIntervalSince($0.value.createdAt) <= Self.stageLifetime }
        guard let staged = stages[previewID] else { throw BridgeFailure("preview-expired", "This preview expired or the native connection was reset. Evaluate the capture again.") }
        guard decision == "create" || decision == "update" || decision == "skip" else { throw BridgeFailure("decision", "Choose create, update, or skip.") }
        if decision == "skip" {
            stages.removeValue(forKey: previewID)
            return ["saved": false, "skipped": true, "message": "No ControlWard record was changed."]
        }
        let directory = ICPConfig.defaultDirectory(bundle: AppResources.bundle)!
        let environment = try LeadPipelineEnvironment.load(configDirectory: directory)
        let rechecked = LeadDefinition.evaluate(staged.record, config: environment.config, now: now())
        guard rechecked.status == staged.record.status, rechecked.reasons == staged.record.reasons else {
            stages.removeValue(forKey: previewID)
            throw BridgeFailure("preview-stale", "The qualification result changed since review. Evaluate it again before saving.")
        }
        guard rechecked.status != ProspectStatus.drop else { throw BridgeFailure("not-a-lead", "ControlWard’s current rules do not permit saving this record.") }
        let store = ProspectLeadsStore(fileURL: environment.storeURL)
        let approval = ProspectIngest.DuplicateApproval(action: decision, expectedID: staged.duplicateID)
        let result = await ProspectIngest.ingest([staged.record], into: store, config: environment.config, now: now(),
                                                 audit: environment.audit, duplicateApproval: approval)
        if let failure = result.storageError {
            if failure.hasPrefix("refused:") { throw BridgeFailure(String(failure.dropFirst("refused:".count)), "The register changed after preview. Re-evaluate and review the current match before saving.") }
            throw BridgeFailure("storage-failed", "ControlWard could not safely write the lead register. The original data was preserved; retry after resolving the local storage issue.")
        }
        guard result.rejected.isEmpty, result.added.count + result.merged.count == 1 else {
            throw BridgeFailure("save-rejected", "ControlWard did not accept the record. Nothing was reported as saved.")
        }
        stages.removeValue(forKey: previewID)
        let recordID = result.added.first ?? result.merged.first ?? staged.record.id
        return ["saved": true, "recordID": recordID, "updated": !result.merged.isEmpty,
                "status": staged.record.status.rawValue,
                "message": "Saved locally to ControlWard Leads. No Worker key or outreach action was used."]
    }

    private func parseCapture(_ value: Any?) throws -> Capture {
        guard let object = value as? [String: Any] else { throw BridgeFailure("capture-shape", "Capture must be an object.") }
        try Self.requireKeys(object, exactly: ["segmentID", "businessName", "websiteURL", "municipality", "sourceURL"])
        let segmentID = try Self.string(object["segmentID"], field: "segmentID", limit: 80)
        let businessName = try Self.string(object["businessName"], field: "businessName", limit: 180)
        let websiteURL = try Self.string(object["websiteURL"], field: "websiteURL", limit: 2048)
        let sourceURL = try Self.string(object["sourceURL"], field: "sourceURL", limit: 2048)
        let municipality = try Self.optionalString(object["municipality"], field: "municipality", limit: 120)
        guard !businessName.isEmpty else { throw BridgeFailure("business-name", "Enter a business name.") }
        guard !segmentID.isEmpty else { throw BridgeFailure("segment", "Choose a ControlWard segment.") }
        guard let source = URL(string: sourceURL), Self.isHTTPURL(source), source.user == nil, source.password == nil else {
            throw BridgeFailure("source-url", "Capture source is not a valid HTTP or HTTPS URL.")
        }
        guard let website = URL(string: websiteURL), Self.isHTTPURL(website), website.user == nil, website.password == nil else {
            throw BridgeFailure("website-url", "Business website is not a valid HTTP or HTTPS URL.")
        }
        return Capture(segmentID: segmentID, businessName: businessName, websiteURL: Self.withoutTracking(source: website).absoluteString,
                       municipality: municipality, sourceURL: Self.withoutTracking(source: source).absoluteString)
    }

    private func authenticate(_ object: [String: Any], extensionID: String, tokenValue: Any? = nil) throws {
        guard let token = tokenValue as? String, token.count >= 40, token.count <= 100 else { throw BridgeFailure("pairing-required", "Pair this extension with ControlWard first.") }
        let pairing = try readPairing()
        guard let pairing, pairing.extensionID == extensionID, pairing.tokenSHA256 == Self.sha256(token) else {
            throw BridgeFailure("pairing-invalid", "The local pairing is invalid. Unpair and pair again.")
        }
        _ = object
    }

    private func readPairing() throws -> Pairing? {
        let path = pairingURL()
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do { return try JSONDecoder.iso.decode(Pairing.self, from: Data(contentsOf: path)) }
        catch { throw BridgeFailure("pairing-corrupt", "The local pairing file is unreadable. Remove it using the documented reset step, then pair again.") }
    }

    private func pairingURL() -> URL { LeadPipelineEnvironment.defaultRoot().appendingPathComponent("chrome-pairing.json") }

    private static func captureIdentity(name: String, url: URL) -> String {
        let canonical = "\(url.host?.lowercased() ?? "")|\(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA")))"
        let digest = sha256(canonical).prefix(40)
        return "chrome:\(digest)"
    }

    private static func evidenceFields(_ record: ProspectRecord) -> [[String: String]] {
        func field(_ name: String, _ value: String?, _ url: String?) -> [String: String]? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let evidence = record.snapshots.first(where: { $0.url == url }) ?? record.snapshots.first
            let excerpt = evidence.map { text in
                let line = text.text.components(separatedBy: .newlines).first(where: { $0.localizedCaseInsensitiveContains(value) })
                return String((line ?? text.text).prefix(280))
            } ?? ""
            return ["name": name, "value": value, "sourceURL": url ?? record.sourceURL ?? "", "excerpt": excerpt]
        }
        var fields: [[String: String]] = []
        fields += [field("business", record.organisation, record.sourceURL)].compactMap { $0 }
        fields += [field("website", record.businessDomain.map { "https://\($0)/" }, record.sourceURL)].compactMap { $0 }
        fields += [field("email", record.email, record.route?.sourceURL)].compactMap { $0 }
        fields += [field("phone", record.phone, record.route?.sourceURL)].compactMap { $0 }
        fields += [field("address", record.address, record.addressSourceURL)].compactMap { $0 }
        fields += [field("municipality", record.town, record.sourceURL)].compactMap { $0 }
        if let trigger = record.trigger { fields += [field("trigger", trigger.summary, trigger.url)].compactMap { $0 } }
        return fields
    }

    private static func requireKeys(_ object: [String: Any], exactly expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw BridgeFailure("message-schema", "Request fields do not match this operation’s schema.") }
    }

    private static func string(_ value: Any?, field: String, limit: Int) throws -> String {
        guard let value = value as? String, value.utf8.count <= limit else { throw BridgeFailure("invalid-field", "Field \(field) must be text of at most \(limit) bytes.") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalString(_ value: Any?, field: String, limit: Int) throws -> String? {
        guard !(value is NSNull) else { return nil }
        let text = try string(value, field: field, limit: limit)
        return text.isEmpty ? nil : text
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func isJSONTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }

    private static func isExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.unicodeScalars.allSatisfy { ("a"..."p").contains(Character($0)) }
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    private static func withoutTracking(source url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.query = nil
        parts.fragment = nil
        return parts.url ?? url
    }

    private static func randomToken() -> String {
        let left = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let right = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return left + right
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func response(requestID: String, payload: [String: Any]) -> Data {
        var response = payload
        response["version"] = protocolVersion
        response["requestID"] = requestID
        response["ok"] = true
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func errorResponse(for frame: Data, code: String, message: String) -> Data {
        let requestID: String
        if let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any], let value = object["requestID"] as? String {
            requestID = String(value.prefix(80))
        } else { requestID = "" }
        let response: [String: Any] = ["version": protocolVersion, "requestID": requestID, "ok": false,
                                       "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func readExact(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let part: Data?
            do { part = try FileHandle.standardInput.read(upToCount: count - data.count) }
            catch { return nil }
            guard let part, !part.isEmpty else { return nil }
            data.append(part)
        }
        return data
    }

    private static func readFrame() -> Data? {
        guard let header = readExact(4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= maxMessageBytes else { return nil }
        return readExact(Int(length))
    }

    private static func writeFrame(_ payload: Data) {
        guard payload.count <= maxMessageBytes else { return }
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        try? FileHandle.standardOutput.write(contentsOf: frame)
    }
}

private struct BridgeFailure: Error {
    var code: String
    var message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
