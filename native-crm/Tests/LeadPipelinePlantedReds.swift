import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Slice 3 planted reds (wind-acceptance-tests.md §3, slice total amended 6:11 AM ET): 41 bad inputs, plus Argus's 13
/// (gate file controlward-18-2026-10-23.md; total amended to 54 by Water, 6:53 AM ET), plus Earth's 2 RBQ fail-closed
/// reds (6:59 AM ET findings on 75285c4: missing and unreadable index through the app path; 54 -> 56, reported to Earth). A case "fails" when the code refuses
/// it, so a healthy build prints `expected 56 failures, got 56: OK`. Any other count exits non-zero.
/// Argus reds 9 and 10 live in pharos-api's vitest suite; they count only when CW_PHAROS_PLANTED_REDS points at that
/// run's JSON report and the matching tests passed. Without the report they are RED-MISSED and the total is a MISMATCH.
/// bin/test-portable and bin/test-native-app make that report via bin/pharos-planted-reds.sh (vitest from the repo root
/// after `yarn install`, or pharos-api/node_modules); with no vitest they leave it unset, so the count fails loudly.
enum LeadPipelinePlantedReds {
    typealias Probe = () async throws -> String?

    struct Case {
        var group: String
        var label: String
        /// Returns the refusal (the planted failure) or nil if the bad input got through.
        var probe: Probe
    }

    static let expectedTotal = 56

    /// The line for a red that did not fail as planted.
    static func missedLine(group: String, label: String, report: PharosPlantedReds.Status? = nil) -> String {
        "  RED-MISSED [\(group)] \(label): the planted bad input was accepted"
    }

    /// The smoke-test failure text with the real counts.
    static func tallyMessage(expected: Int, got: Int) -> String {
        "Slice 3 planted reds did not print expected 56 failures, got 56: OK"
    }
    static let expectedByGroup: [(String, Int)] = [
        ("S3-RED (original)", 4), ("S3-RED-PC", 1), ("S3-RED-SRC", 2), ("S3-RED-SPAM", 5), ("S3-RED-SEQ", 2), ("S3-RED-FROM", 1),
        ("S3-RED-ICP", 3), ("S3-RED-ADDR", 3), ("S3-RED-LOI25", 3), ("S3-RED-LEADREC", 5), ("S3-RED-FRESH", 3), ("S3-RED-HOLD", 2),
        ("S3-RED-CRAWL", 2), ("S3-RED-DRAFT", 4), ("S3-RED-PUSH", 1), ("ARGUS-RED", 13), ("EARTH-RED", 2)
    ]

    static func run() async -> Bool {
        let cases: [Case]
        do { cases = try makeCases() } catch {
            print("  FAIL planted reds: could not load config: \(error)")
            print("expected \(expectedTotal) failures, got 0: MISMATCH")
            return false
        }
        var failures = 0
        var byGroup: [String: Int] = [:]
        for item in cases {
            var outcome: String?
            do { outcome = try await item.probe() } catch { outcome = "threw \(error)" }
            if let outcome {
                failures += 1
                byGroup[item.group, default: 0] += 1
                print("  RED-OK [\(item.group)] \(item.label): \(outcome)")
            } else {
                print("  RED-MISSED [\(item.group)] \(item.label): the planted bad input was accepted")
            }
        }
        var ok = cases.count == expectedTotal
        for (group, expected) in expectedByGroup {
            let got = byGroup[group, default: 0]
            let declared = cases.filter { $0.group == group }.count
            let line = got == expected && declared == expected ? "OK" : "MISMATCH"
            if line != "OK" { ok = false }
            print("\(group): expected \(expected) failures, got \(got): \(line)")
        }
        ok = ok && failures == expectedTotal
        print("Slice 3 planted reds (41 Wind + 13 Argus + 2 Earth): expected \(expectedTotal) failures, got \(failures): \(ok ? "OK" : "MISMATCH")")
        if ok { print("expected \(expectedTotal) failures, got \(failures): OK") }
        return ok
    }

    // MARK: - Cases

    static func makeCases() throws -> [Case] {
        let config = try LeadKit.config()
        let confirmed = try LeadKit.confirmed()
        let now = LeadKit.now
        var cases: [Case] = []
        func add(_ group: String, _ label: String, _ probe: @escaping Probe) { cases.append(Case(group: group, label: label, probe: probe)) }

        // Original 4
        add("S3-RED (original)", "a test lead counted as real") {
            var lead = LeadKit.readyClinic()
            lead.isTest = true
            lead.provenance = .test
            let count = LeadDefinition.realLeadCount([lead], config: config, now: now)
            return count == 0 ? "real-lead count 0 (test lead excluded)" : nil
        }
        add("S3-RED (original)", "a duplicate by email creating a second lead") {
            let store = ProspectLeadsStore()
            let first = LeadKit.readyClinic(id: "cw:osm:node/1", email: "info@clinique-exemple.test")
            let second = LeadKit.readyClinic(id: "cw:osm:node/2", email: "INFO@clinique-exemple.test")
            _ = await ProspectIngest.ingest([first], into: store, config: config, now: now, audit: MemoryAuditSink())
            let result = await ProspectIngest.ingest([second], into: store, config: config, now: now, audit: MemoryAuditSink())
            return store.records.count == 1 && result.merged == ["cw:osm:node/1"] ? "merged into the existing lead (dedupe by email)" : nil
        }
        add("S3-RED (original)", "a fixture that fails LEAD_DEF but is counted anyway") {
            var lead = LeadKit.readyClinic()
            lead.contact = nil
            let count = LeadDefinition.realLeadCount([lead], config: config, now: now)
            return count == 0 ? "real-lead count 0 (no named person)" : nil
        }
        add("S3-RED (original)", "an ingest that makes an outbound request") {
            let egress = FakeLeadTransport()
            _ = await ProspectIngest.ingest([LeadKit.readyClinic()], into: ProspectLeadsStore(), config: config, now: now,
                                            audit: MemoryAuditSink(), egress: egress)
            return egress.requests.isEmpty ? "0 outbound requests during ingest" : nil
        }

        // PC
        add("S3-RED-PC", "an ingest that writes to Project Control") {
            let egress = FakeLeadTransport()
            let audit = MemoryAuditSink()
            _ = await ProspectIngest.ingest([LeadKit.readyClinic()], into: ProspectLeadsStore(), config: config, now: now, audit: audit, egress: egress)
            let pcWrites = egress.requests.filter { $0.url?.path.hasPrefix("/api/items") == true }
            let ingestLines = audit.lines.filter { $0.surface == "leads" && $0.action == "ingest" }
            return pcWrites.isEmpty && ingestLines.count == 1 ? "0 requests to /api/items; 1 surface=leads action=ingest line" : nil
        }

        // SRC
        for (label, strip) in [("no source URL", { (r: inout ProspectRecord) in r.sourceURL = nil }),
                               ("no fetch time", { (r: inout ProspectRecord) in r.fetchedAt = nil })] {
            add("S3-RED-SRC", "a prospect with \(label)") {
                var lead = LeadKit.readyClinic()
                strip(&lead)
                let store = ProspectLeadsStore()
                let result = await ProspectIngest.ingest([lead], into: store, config: config, now: now, audit: MemoryAuditSink())
                return store.records.isEmpty && result.rejected[lead.id] != nil ? "rejected at ingest: \(result.rejected[lead.id]!)" : nil
            }
        }

        // SPAM: sends to Martin's own address with a valid approval, so only the anti-spam rule can refuse.
        func martinDraft() -> OutreachDraft {
            var draft = LeadKit.draft(for: LeadKit.readyClinic(), config: config)
            draft.to = config.loi25Gate.martinAddresses[0]
            return draft
        }
        let spamCases: [(String, String, (inout OutreachDraft) -> Void)] = [
            ("no sender identification", "refused:anti-spam:identification", { $0.body = $0.body.replacingOccurrences(of: config.sender.organization, with: "") }),
            ("no mailing address", "refused:anti-spam:address", { $0.body = $0.body.replacingOccurrences(of: config.sender.mailingAddress, with: "") }),
            ("no unsubscribe", "refused:anti-spam:unsubscribe", {
                $0.body = $0.body.replacingOccurrences(of: "mailto:\(config.sender.unsubscribeMailto)", with: "")
                $0.listUnsubscribe = nil
            }),
            ("no consent basis", "refused:anti-spam:consent", { $0.consent = nil })
        ]
        for (label, code, plant) in spamCases {
            add("S3-RED-SPAM", "a send with \(label)") {
                var draft = martinDraft()
                plant(&draft)
                let refusal = OutreachSendGate.check(draft, approval: LeadKit.approval(draft), config: config, suppression: SuppressionList())
                return refusal?.code == code ? code : nil
            }
        }
        add("S3-RED-SPAM", "a draft after an unsubscribe") {
            let suppression = SuppressionList()
            let prospect = LeadKit.readyClinic()
            suppression.processReply(from: prospect.email!, to: config.sender.unsubscribeMailto, subject: "unsubscribe", firstLine: "", config: config, at: now)
            let draft = LeadKit.draft(for: prospect, config: config, messageID: "cw-draft-2")
            let refusal = OutreachDraftGate.check(draft, prospect: prospect, config: config, suppression: suppression, now: now)
            return refusal?.code == "refused:anti-spam:unsubscribed" ? refusal!.code : nil
        }

        // SEQ
        add("S3-RED-SEQ", "a queued follow-up sent on its parent's approval") {
            let prospect = LeadKit.readyClinic()
            var parent = LeadKit.draft(for: prospect, config: config, messageID: "cw-msg-1")
            parent.to = config.loi25Gate.martinAddresses[0]
            var followUp = OutreachDraftBuilder.build(for: prospect, config: config, language: "fr", messageID: "cw-msg-2", step: 2, parentMessageID: "cw-msg-1")
            followUp.to = parent.to
            let refusal = OutreachSendGate.check(followUp, approval: LeadKit.approval(parent), config: config, suppression: SuppressionList())
            return refusal?.code == "refused:no-approval" ? refusal!.code : nil
        }
        add("S3-RED-SEQ", "a sequence step with no approval") {
            var step = OutreachDraftBuilder.build(for: LeadKit.readyClinic(), config: config, language: "en", messageID: "cw-msg-3", step: 3, parentMessageID: "cw-msg-2")
            step.to = config.loi25Gate.martinAddresses[0]
            let refusal = OutreachSendGate.check(step, approval: nil, config: config, suppression: SuppressionList())
            return refusal?.code == "refused:no-approval" ? refusal!.code : nil
        }

        // FROM
        add("S3-RED-FROM", "a send From the personal address martinlepage.ai@gmail.com") {
            var draft = martinDraft()
            draft.from = "martinlepage.ai@gmail.com"
            let refusal = OutreachSendGate.check(draft, approval: LeadKit.approval(draft), config: config, suppression: SuppressionList())
            return refusal?.code == "refused:from-not-alias" ? refusal!.code : nil
        }

        // ICP
        add("S3-RED-ICP", "a hard-coded segment list in source") {
            let planted = "let segments = [" + confirmed.segments.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            let hits = ICPSourceScanner.hardCodedSegments(in: planted, segmentIDs: confirmed.segments)
            return hits.isEmpty ? nil : "hard-coded segments found: \(hits.joined(separator: ","))"
        }
        add("S3-RED-ICP", "a config with one segment dropped") {
            var dropped = config
            dropped.segments.removeLast()
            return dropped.validate(against: confirmed)?.description
        }
        add("S3-RED-ICP", "a segment given a lower priority") {
            var lowered = config
            lowered.segments[0].priority = 2
            return lowered.validate(against: confirmed)?.description
        }

        // ADDR
        add("S3-RED-ADDR", "an address found only in OSM") {
            var prospect = LeadKit.readyClinic()
            prospect.addressSource = .openStreetMap
            prospect.addressSourceURL = "https://www.openstreetmap.org/node/1001"
            let refusal = OutreachDraftGate.check(LeadKit.draft(for: prospect, config: config), prospect: prospect, config: config, suppression: SuppressionList(), now: now)
            return refusal?.code == "refused:address-provenance" ? refusal!.code : nil
        }
        add("S3-RED-ADDR", "an address absent from the own-site snapshot") {
            var prospect = LeadKit.readyClinic()
            prospect.address = "99, avenue Inventée, Laval (Québec) H0H 9Z9"
            let refusal = OutreachDraftGate.check(LeadKit.draft(for: prospect, config: config), prospect: prospect, config: config, suppression: SuppressionList(), now: now)
            return refusal?.code == "refused:address-provenance" ? refusal!.code : nil
        }
        add("S3-RED-ADDR", "a contact taken from the RBQ Courriel field") {
            var prospect = LeadKit.readyClinic(email: "courriel-rbq@exemple-rbq.test")
            prospect.route = ProspectRoute(kind: .email, value: "courriel-rbq@exemple-rbq.test",
                                           sourceURL: RBQOpenData.source(config)?.downloadUrls.first ?? "https://www.donneesquebec.ca/", source: .rbqOpenData)
            prospect.dataAttribution = RBQOpenData.source(config)?.attribution
            let refusal = OutreachDraftGate.check(LeadKit.draft(for: prospect, config: config), prospect: prospect, config: config, suppression: SuppressionList(), now: now)
            return refusal?.code == "refused:address-provenance" ? refusal!.code : nil
        }

        // LOI25
        add("S3-RED-LOI25", "prospect data in a request to an off-allowlist host") {
            let inner = FakeLeadTransport()
            let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            let url = URL(string: "https://enrichment.example.test/v1/person?email=info%40clinique-exemple.test")!
            do { _ = try await guarded.fetch(url, purpose: .discovery); return nil } catch let refusal as LeadPipelineRefusal {
                return inner.requests.isEmpty && refusal.code == "refused:loi25-host" ? "\(refusal.code), 0 requests" : nil
            }
        }
        add("S3-RED-LOI25", "a send to a real prospect while the Loi 25 gate is closed") {
            let draft = LeadKit.draft(for: LeadKit.readyClinic(), config: config)
            let refusal = OutreachSendGate.check(draft, approval: LeadKit.approval(draft), config: config, suppression: SuppressionList())
            return !config.loi25Gate.open && refusal?.code == "refused:loi25-gate" ? refusal!.code : nil
        }
        add("S3-RED-LOI25", "content from a fetched business site sent to Overpass") {
            let inner = FakeLeadTransport()
            let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            guarded.registerSensitive(["Alex Fictif, directrice générale"])
            let body = Data("data=[out:json];nwr[\"name\"~\"Alex Fictif, directrice générale\"];out;".utf8)
            do { _ = try await guarded.fetch(LeadDiscovery.overpass, purpose: .discovery, method: "POST", body: body); return nil }
            catch let refusal as LeadPipelineRefusal {
                return inner.requests.isEmpty && refusal.code == "refused:loi25-payload" ? "\(refusal.code), 0 requests" : nil
            }
        }

        // LEADREC
        let fields: [(String, String, (inout ProspectRecord) -> Void)] = [
            ("named person", "no named person", { $0.contact = nil }),
            ("title source", "no title source", { $0.contact?.titleSource = nil }),
            ("trigger URL with fetch time", "no trigger URL with fetch time", { $0.trigger?.url = nil }),
            ("one-line fit", "no fit line", { $0.fit = " " }),
            ("public contact route", "no public contact route", { $0.route = nil })
        ]
        for (label, reason, strip) in fields {
            add("S3-RED-LEADREC", "a lead missing its \(label)") {
                var lead = LeadKit.readyClinic()
                strip(&lead)
                let verdict = LeadDefinition.evaluate(lead, config: config, now: now)
                return verdict.status != .ready && verdict.reasons.contains(reason) ? "\(verdict.status.rawValue): \(reason)" : nil
            }
        }

        // FRESH
        add("S3-RED-FRESH", "a 91-day-old institutional trigger") {
            let verdict = LeadDefinition.evaluate(LeadKit.university(fetchedDaysAgo: 91), config: config, now: now)
            return verdict.status != .ready && verdict.reasons.contains("stale trigger") ? "Fix: stale trigger" : nil
        }
        add("S3-RED-FRESH", "a clinic trigger fetched yesterday") {
            var lead = LeadKit.readyClinic()
            lead.trigger?.fetchedAt = now.addingTimeInterval(-86_400)
            let verdict = LeadDefinition.evaluate(lead, config: config, now: now)
            return verdict.status != .ready && verdict.reasons.contains("stale trigger") ? "Fix: stale trigger" : nil
        }
        add("S3-RED-FRESH", "a trigger taken from a search snippet") {
            var lead = LeadKit.readyClinic()
            lead.trigger?.origin = .searchSnippet
            let verdict = LeadDefinition.evaluate(lead, config: config, now: now)
            return verdict.status != .ready ? "\(verdict.status.rawValue): \(verdict.reasons.joined(separator: "; "))" : nil
        }

        // HOLD
        add("S3-RED-HOLD", "a held plumbing trade that gets drafted") {
            var prospect = LeadKit.readyClinic()
            prospect.segment = "construction_trades"
            prospect.organisation = "Plomberie Fictive Est"
            prospect.osmTags = ["craft=plumber"]
            let refusal = OutreachDraftGate.check(LeadKit.draft(for: prospect, config: config), prospect: prospect, config: config, suppression: SuppressionList(), now: now)
            let verdict = LeadDefinition.evaluate(prospect, config: config, now: now)
            return refusal?.code == "refused:hold:conflict-review" && verdict.status == .conflictReview ? "\(refusal!.code), status=conflict_review" : nil
        }
        add("S3-RED-HOLD", "an organisation with an open tender that gets drafted") {
            var prospect = LeadKit.university(fetchedDaysAgo: 3)
            prospect.openTenderURL = "https://www.seao.ca/avis/exemple-0001"
            let refusal = OutreachDraftGate.check(LeadKit.draft(for: prospect, config: config), prospect: prospect, config: config, suppression: SuppressionList(), now: now)
            return refusal?.code == "refused:hold:open-tender" ? refusal!.code : nil
        }

        // CRAWL
        add("S3-RED-CRAWL", "a fetch of a robots-disallowed path") {
            let inner = FakeLeadTransport()
            inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nDisallow: /equipe\n", headers: ["content-type": "text/plain"])
            inner.respond(LeadKit.teamPage, body: "<p>Équipe</p>")
            let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            do { _ = try await guarded.fetch(URL(string: LeadKit.teamPage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)); return nil }
            catch let refusal as LeadPipelineRefusal {
                let pageHits = inner.urls.filter { $0 == LeadKit.teamPage }
                return refusal.code == "refused:robots" && pageHits.isEmpty ? "\(refusal.code), page never requested" : nil
            }
        }
        add("S3-RED-CRAWL", "a fetch to linkedin.com") {
            let inner = FakeLeadTransport()
            let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            do { _ = try await guarded.fetch(URL(string: "https://www.linkedin.com/company/exemple")!, purpose: .ownSite(domain: "linkedin.com")); return nil }
            catch let refusal as LeadPipelineRefusal {
                return refusal.code == "refused:crawl-linkedin" && inner.requests.isEmpty ? "\(refusal.code), 0 requests" : nil
            }
        }

        // DRAFT
        let content: [(String, String)] = [
            ("legal_advice", "Selon notre avis juridique, vous devez vous conformer à la Loi 25 d'ici décembre."),
            ("compliance_claims", "Notre méthode vous rend fully compliant avec la Loi 25."),
            ("patient_or_client_data", "Nous avons consulté les dossiers de vos patients."),
            ("pricing", "Le forfait de départ coûte 1 500 $.")
        ]
        for (rule, sentence) in content {
            add("S3-RED-DRAFT", "a draft with \(rule)") {
                let prospect = LeadKit.readyClinic()
                var draft = LeadKit.draft(for: prospect, config: config)
                draft.body = draft.body.replacingOccurrences(of: "\n\n--", with: "\n\(sentence)\n\n--")
                let refusal = OutreachDraftGate.check(draft, prospect: prospect, config: config, suppression: SuppressionList(), now: now)
                return refusal?.code == "refused:draft-content:\(rule)" ? refusal!.code : nil
            }
        }

        // PUSH
        add("S3-RED-PUSH", "a search-provenance prospect pushed through /v1/leads/push") {
            let payload: [String: Any] = ["source_id": "cw:osm:node/1001", "test": false,
                                          "provenance": ["kind": "controlward_search", "fetcher": "controlward:test-run"]]
            return LeadPushPolicy.check(payload)?.code
        }

        // ARGUS (gate file /workspace/argus/gate/controlward-18-2026-10-23.md, reds 1-13)
        let rbqSource = RBQOpenData.source(config)
        add("ARGUS-RED", "1 RBQ-REAL-SHAPE: a real-shape JSON record parsed to nothing") {
            guard let rbqSource else { return nil }
            let data = RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0001-01", name: "Plomberie Fictive Centre", town: "Montréal", codes: [("Specialisee", "15.5")])])
            let parsed = (try? RBQOpenData.parse(data: data, source: rbqSource)) ?? []
            return parsed.count == 1 && parsed[0].subcategories == ["15.5"] ? "parsed=1 codes=15.5" : nil
        }
        add("ARGUS-RED", "2 RBQ-RENAMED-LABEL: a renamed category label silently ignored") {
            guard let rbqSource else { return nil }
            let data = RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0001-02", name: "Plomberie Fictive Centre", town: "Montréal", codes: [("Specialisee", "15.5")],
                                                              renaming: ("Catégories et sous-catégories", "Catégories"))])
            do { _ = try RBQOpenData.parse(data: data, source: rbqSource); return nil }
            catch let refusal as LeadPipelineRefusal { return refusal.code == "refused:open-data-schema" ? refusal.code : nil }
        }
        add("ARGUS-RED", "3 RBQ-NO-CACHE-HOLD: a silent construction site with no RBQ file gets Ready and a draft") {
            let fixture = SearchFixture.builder(config: config)
            let report = await fixture.run(segment: "construction_trades", rbq: nil)
            guard let prospect = report.prospects.first else { return nil }
            return prospect.status == .conflictReview && report.drafts.isEmpty ? "conflict_review (rbq \(prospect.rbqCheck ?? "-")), 0 drafts" : nil
        }
        add("ARGUS-RED", "4 RBQ-NO-MATCH-HOLD: a construction prospect with no licence match passes") {
            let fixture = SearchFixture.builder(config: config)
            let report = await fixture.run(segment: "construction_trades", rbq: RBQIndex([]))
            guard let prospect = report.prospects.first else { return nil }
            return prospect.status == .conflictReview && report.drafts.isEmpty ? "conflict_review (rbq \(prospect.rbqCheck ?? "-"))" : nil
        }
        add("ARGUS-RED", "5 SSRF-IP-LITERAL: an own-site fetch to 127.0.0.1, 169.254.169.254, [::1], 10/8, 192.168/16 or x.local") {
            let inner = FakeLeadTransport()
            let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            var codes: [String] = []
            for raw in ["http://127.0.0.1/", "http://169.254.169.254/", "http://[::1]/", "http://10.1.2.3/", "http://192.168.0.1/", "http://x.local/"] {
                let url = URL(string: raw)!
                do { _ = try await guarded.fetch(url, purpose: .ownSite(domain: url.host ?? "")); return nil }
                catch let refusal as LeadPipelineRefusal { codes.append(refusal.code) }
            }
            return inner.requests.isEmpty && codes.allSatisfy({ $0 == "refused:own-site-host" }) ? "6x refused:own-site-host, 0 requests" : nil
        }
        add("ARGUS-RED", "6 REDIRECT-OFF-SITE: a 302 to another host is followed and attributed to the site") {
            let fixture = SearchFixture(config: config)
            fixture.inner.respond(LeadKit.homePage, status: 302, body: "", headers: ["location": "https://autre-site.example.test/"])
            fixture.inner.respond("https://autre-site.example.test/", body: "<p>Prendre rendez-vous en ligne</p>")
            let guarded = GuardedLeadTransport(config: config, inner: fixture.inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            var code = "none"
            do { _ = try await guarded.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)) }
            catch let refusal as LeadPipelineRefusal { code = refusal.code }
            let report = await fixture.run()
            let leaked = report.prospects.flatMap(\.snapshots).contains { $0.url.contains("autre-site") } || fixture.inner.urls.contains { $0.contains("autre-site") }
            return code == "refused:redirect-off-site" && !leaked ? "\(code), no off-site snapshot" : nil
        }
        add("ARGUS-RED", "7 ROBOTS-5XX: robots.txt answers 503 and the site is crawled anyway") {
            let inner = FakeLeadTransport()
            inner.respond("https://www.clinique-exemple.test/robots.txt", status: 503, body: "", headers: ["content-type": "text/plain"])
            inner.respond(LeadKit.homePage, body: "<p>a</p>")
            let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
            do { _ = try await guarded.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)); return nil }
            catch let refusal as LeadPipelineRefusal { return refusal.code == "refused:robots" && !inner.urls.contains(LeadKit.homePage) ? refusal.code : nil }
        }
        add("ARGUS-RED", "8 APPROVAL-CONTENT-MISMATCH: an approved draft whose body changed under the same message id") {
            var cfg = config
            cfg.loi25Gate.open = true
            let draft = LeadKit.draft(for: LeadKit.readyClinic(), config: cfg)
            let approval = LeadKit.approval(draft)
            var edited = draft
            edited.body = edited.body.replacingOccurrences(of: "\n\n--", with: "\nUne phrase ajoutée après l'approbation.\n\n--")
            guard edited.body != draft.body, OutreachSendGate.check(draft, approval: approval, config: cfg, suppression: SuppressionList()) == nil else { return nil }
            return OutreachSendGate.check(edited, approval: approval, config: cfg, suppression: SuppressionList())?.code
        }
        add("ARGUS-RED", "9 PUSH-MIXED-RETRACT (pharos-api vitest): one refused lead drops the packet's retractions") {
            PharosPlantedReds.passed("ARGUS-RED-9")
        }
        add("ARGUS-RED", "10 PUSH-TEST-STORED-AS-REAL (pharos-api vitest): a test lead is served like a real one") {
            PharosPlantedReds.passed("ARGUS-RED-10")
        }
        add("ARGUS-RED", "11 PUSH-POLICY-PARITY: Swift accepts form_source \"   \" (or test:1) that pharos-api refuses") {
            let blank = LeadPushPolicy.check(["provenance": ["kind": "inbound_form", "form_source": "   "]])
            let one = LeadPushPolicy.check(["test": NSNumber(value: 1)])
            return blank != nil && one != nil ? "\(blank!.code) (blank form source and test:1)" : nil
        }
        add("ARGUS-RED", "12 AUDIT-WRITE-FAIL: an audit line that cannot be written disappears silently") {
            let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("cw-audit-red-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: blocker) }
            try Data("file".utf8).write(to: blocker)
            let sink = FileAuditSink(url: blocker.appendingPathComponent("x/audit.log"))
            sink.write(CWAuditLine(ts: now, surface: "leads", action: "fetch", result: "ok"))
            return sink.failures.isEmpty ? nil : "failure surfaced: \(sink.failures[0])"
        }
        add("ARGUS-RED", "13 S1-R7-SCAN-WIDE: NSAttributedString(html: in a source file passes the scan") {
            let findings = HTMLImportScan.findings(in: "let text = NSAttributedString(html: data, documentAttributes: nil)")
            return findings.isEmpty ? nil : "caught: \(findings.joined(separator: ", "))"
        }
        // EARTH (6:59 AM ET findings on 75285c4, narrowed by Water 7:18 AM ET so they don't overlap Argus reds 2 and 3):
        // through the app path, a mixed batch of construction/trades firms is held all at once.
        add("EARTH-RED", "1 RBQ-MISSING-INDEX (app path): with no cached RBQ file, firms of a mixed construction batch get Ready or a draft") {
            let out = try await EarthRBQ.appRun(contents: nil)
            let all = SearchFixture.constructionBatch.count
            return out.prospects.count == all && out.prospects.allSatisfy({ $0.status == .conflictReview }) && out.drafts.isEmpty
                ? "\(all)/\(all) held in one run (rbq \(out.prospects.first?.rbqCheck ?? "-")), 0 drafts" : nil
        }
        add("EARTH-RED", "2 RBQ-CORRUPT-INDEX (app path): a truncated RBQ file lets firms of a mixed construction batch through") {
            let out = try await EarthRBQ.appRun(contents: Data(#"{"Liste Licence":[{"Licence":{"#.utf8))
            let all = SearchFixture.constructionBatch.count
            guard out.prospects.count == all, out.prospects.allSatisfy({ $0.status == .conflictReview }), out.drafts.isEmpty,
                  out.audit.contains(where: { $0.action == "rbq-load" && $0.result == "refused:open-data-schema" }) else { return nil }
            return "truncated: \(all)/\(all) held, 0 drafts, rbq-load refused:open-data-schema"
        }
        return cases
    }
}

/// Reads the pharos-api vitest JSON report named by CW_PHAROS_PLANTED_REDS (vitest --reporter=json).
enum PharosPlantedReds {
    /// A red from the vitest report: caught by the test, not caught, or not run at all (no readable report).
    enum Status: Equatable {
        case caught(String)
        case notCaught
        case missing(String)
    }

    static func status(_ marker: String, path: String?) -> Status {
        passed(marker).map(Status.caught) ?? .notCaught
    }

    static func passed(_ marker: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["CW_PHAROS_PLANTED_REDS"], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = report["testResults"] as? [[String: Any]] else { return nil }
        for file in files {
            for test in (file["assertionResults"] as? [[String: Any]]) ?? [] {
                let title = (test["fullName"] as? String) ?? (test["title"] as? String) ?? ""
                if title.contains(marker) { return test["status"] as? String == "passed" ? "vitest passed: \(title)" : nil }
            }
        }
        return nil
    }
}
