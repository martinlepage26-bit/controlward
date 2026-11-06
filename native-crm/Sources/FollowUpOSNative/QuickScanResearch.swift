import Foundation

/// A public claim of actual AI use, rather than a keyword, privacy notice or online booking button.
/// Matching is local. Page text is data and never supplies instructions to an agent.
enum AIUseEvidence {
    static func find(in pages: [SiteExtractor.Page], organisation: String) -> [FactEvidence] {
        let tools = #"(?:AI|IA|ChatGPT|Copilot|Claude|Gemini|Midjourney|DALL[·-]?E|artificial intelligence|intelligence artificielle|generative AI|IA g[ée]n[ée]rative|AI[- ]powered|aliment[ée]e? par l.intelligence artificielle)"#
        let subject = #"(?:we|our team|our agency|our company|nous|notre [ée]quipe|notre agence|notre entreprise|"# + NSRegularExpression.escapedPattern(for: organisation) + ")"
        let action = #"(?:use|uses|utili[sz]e|utili[sz]es|utilisons|utilise|employons|employe|integrate|integrates|int[ée]grons|int[èe]gre|leverage|leverages|avons int[ée]gr[ée]|have (?:adopted|integrated|implemented)|avons adopt[ée]|d[ée]ployons|utilise r[ée]guli[èe]rement)"#
        let pattern = #"(?i)\b"# + subject + #"\s+(?:(?:also|now|already|actively|[ée]galement|d[ée]j[àa])\s+)?"# + action + #"\b[^.!?;\n]{0,100}?\b"# + tools + #"\b"#
        let negative = #"(?i)\b(?:not|never|no longer|without|don't|doesn't|cannot|can't|ne|pas|jamais|aucun|sans|pourrions|pourrait|would|could|might|may)\b|n[’'](?:utilis|int[èe]gr)|cess[ée]"#
        var seen = Set<String>()
        return pages.flatMap { page -> [FactEvidence] in
            // Headings, body paragraphs and list items retain sentence boundaries in SiteExtractor.
            page.claimText.components(separatedBy: .newlines).filter {
                !$0.contains("?") && $0.range(of: #"(?i)^\s*(?:if|when|whether|do|does|should|could|would|can|si|est-ce|pourquoi|comment)\b"#, options: .regularExpression) == nil
            }.flatMap { line in
                line.components(separatedBy: CharacterSet(charactersIn: ".!?;"))
            }.compactMap { raw -> FactEvidence? in
                let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count <= 600,
                      let claim = sentence.range(of: pattern, options: .regularExpression),
                      String(sentence[claim]).range(of: negative, options: .regularExpression) == nil,
                      // Quoted third-party testimony is not an own-business claim.
                      !sentence.contains("“"), !sentence.contains("«"), !sentence.contains("\""),
                      !["our client", "nos clients disent", "notre client", "said ", "says ", "selon "].contains(where: { sentence.lowercased().contains($0) }),
                      page.text.contains(sentence), seen.insert(page.url + "\n" + sentence).inserted else { return nil }
                return FactEvidence(url: page.url, excerpt: sentence)
            }
        }
    }
}

/// Evidence accompanies the field it supports. A published business route is not a verified personal inbox
/// or proof of deliverability. These checks never send a message or probe an SMTP server.
struct PublishedContactEvidence: Codable, Equatable, Sendable {
    var kind: ProspectRoute.Kind
    var value: String
    var evidence: FactEvidence

    func isSupported(in record: ProspectRecord) -> Bool {
        guard let domain = record.businessDomain, let host = URL(string: evidence.url)?.host,
              HostMatch.belongs(host, to: domain), ProspectResearcher.isEvidenced(evidence, in: record.snapshots) else { return false }
        if SiteExtractor.normalizePrintedEmail(evidence.excerpt).range(of: value, options: .caseInsensitive) != nil { return true }
        if kind == .email, evidence.excerpt.lowercased().hasPrefix("mailto:") {
            return MailAddress.bare(String(evidence.excerpt.dropFirst(7)).components(separatedBy: "?")[0]) == value
        }
        return false
    }
}

struct QuickScanResearchResult: Codable, Equatable, Sendable {
    var record: ProspectRecord
    var checkedAt: Date
    /// Optional so findings from earlier releases remain readable; revised research is rechecked.
    var researchVersion: Int?
    var aiUse: [FactEvidence] = []
    var contacts: [PublishedContactEvidence] = []
    var issues: [String] = []
    var complete = true

    var hasAIUseEvidence: Bool {
        !aiUse.isEmpty && aiUse.allSatisfy { ProspectResearcher.isEvidenced($0, in: record.snapshots) }
    }

    var email: String? {
        contacts.first {
            $0.kind == .email && $0.isSupported(in: record)
        }?.value
    }

    var lines: [String] {
        var out = ["Website research checked: \(ISODates.string(checkedAt))",
                   hasAIUseEvidence ? "AI use: own-business statement found." : "AI use: not established from the pages checked."]
        for item in aiUse { out.append("AI evidence: « \(item.excerpt) » — \(item.url)") }
        for item in contacts {
            out.append("Published \(item.kind.rawValue): \(item.value) — \(item.evidence.url)")
            out.append("Contact evidence: \(item.evidence.excerpt)")
        }
        if contacts.isEmpty { out.append("Contact: no supported public route found on the checked website.") }
        if let person = record.contact { out.append("Named person: \(person.name), \(person.title ?? "title unknown") — \(person.sourceURL ?? "")") }
        out.append("Published contact details have source evidence; mailbox deliverability and recipient identity are not confirmed.")
        out.append("Buying intent: unknown.")
        out += issues
        out += record.reasons.map { "Qualification: \($0)" }
        return out
    }

    /// Existing lead, suppression, provenance and conflict gates still apply. The offer price never becomes
    /// an opportunity value or a claim that this business requested a scan.
    func draft(config: ICPConfig, suppression: SuppressionList, now: Date) -> OutreachDraft? {
        draftAssessment(config: config, suppression: suppression, now: now).draft
    }

    func draftAssessment(config: ICPConfig, suppression: SuppressionList, now: Date) -> (draft: OutreachDraft?, reason: String?) {
        guard complete else { return (nil, "Website research is incomplete.") }
        guard hasAIUseEvidence, let citation = aiUse.first else { return (nil, "Actual AI use is not established from the checked pages.") }
        guard record.status == .ready else { return (nil, "Qualification: " + record.reasons.joined(separator: "; ")) }
        let greeting = record.contact?.name.split(separator: " ").first.map(String.init) ?? ""
        var draft = OutreachDraftBuilder.build(for: record, config: config, language: "fr", messageID: "quickscan-\(record.id)-\(ISODates.string(checkedAt))")
        draft.approvedOffer = .quickScan99CAD
        draft.subject = "Un premier bilan de vos usages d’IA — 99 $ CA"
        draft.body = """
        Bonjour \(greeting),

        Sur votre site (\(citation.url)), j’ai lu : « \(citation.excerpt) »

        Je propose un Quick Scan à 99 $ CA, plus taxes, pour faire le point sur vos usages actuels de l’IA : les outils utilisés, les informations qui y passent et la façon dont les résultats sont vérifiés.

        Vous recevez un court bilan écrit avec les points à clarifier et les actions à prioriser. Après paiement, je vous contacte pour recueillir les éléments nécessaires.

        Si cela vous serait utile, répondez à ce message et je vous transmettrai le lien pour commencer.

        \(OutreachDraftBuilder.footer(config: config, language: "fr"))
        """
        if let refusal = OutreachDraftGate.check(draft, prospect: record, config: config, suppression: suppression, now: now) {
            return (nil, refusal.description)
        }
        return (draft, nil)
    }
}

/// Runs after map discovery, through the same public-site transport and policy as the existing lead pipeline.
/// The page budget, robots rules, host exclusions, pacing and cancellation remain enforced.
struct QuickScanResearcher: Sendable {
    static let version = 2
    let config: ICPConfig
    let transport: GuardedLeadTransport
    let clock: any LeadClock

    func research(_ candidate: LeadCandidate, segmentID: String = "ai_governance_need") async -> QuickScanResearchResult {
        let now = clock.now
        var blank = ProspectRecord(id: "cw:\(candidate.osmID)", organisation: candidate.name, segment: segmentID)
        blank.businessDomain = candidate.website.flatMap { ProspectSearchRun.siteURL($0)?.host }.map(HostMatch.registrable)
        var result = QuickScanResearchResult(record: blank, checkedAt: now)
        result.researchVersion = Self.version
        guard !candidate.closed, let website = candidate.website,
              let root = URL(string: website.contains("://") ? website : "https://" + website),
              let host = root.host, let segment = config.segment(segmentID) else {
            result.issues = ["No usable business website or configured segment; no contact details were guessed."]
            return result
        }
        let domain = HostMatch.registrable(host)
        let (pages, issues) = await crawl(root: root, domain: domain)
        result.issues = issues
        result.complete = !Task.isCancelled
        guard !pages.isEmpty else { result.complete = false; return result }
        var record = ProspectSearchRun.prospect(from: candidate, pages: pages, domain: domain, segment: segment, config: config, runID: UUID().uuidString.lowercased())
        // Website-only discovery has no verified category tags. A generic company segment must not
        // bypass the configured licence hold when the checked business page contains trade signals.
        if segment.osmSelectors.contains("office=company"), let hold = config.rbqLicenceHold {
            // Match business identity, not a portfolio client or an article elsewhere in the page.
            let text = ([candidate.name] + pages.prefix(1).compactMap { $0.text.components(separatedBy: .newlines).first }).joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CA"))
            if let held = config.segments.first(where: { candidateSegment in
                hold.segments.contains(candidateSegment.id) && candidateSegment.keywords.contains { keyword in
                    let normalized = keyword.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CA"))
                    return text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: normalized) + "\\b", options: .regularExpression) != nil
                }
            }) {
                record.segment = held.id
                result.issues.append("Trade signals on the checked website require the configured licence review.")
            }
        }
        result.aiUse = AIUseEvidence.find(in: pages, organisation: candidate.name)
        if let evidence = result.aiUse.first, let page = pages.first(where: { $0.url == evidence.url }) {
            // Quick Scan qualification uses an actual AI-use statement, never the old broad keyword signals.
            record.trigger = ProspectTrigger(kind: "ai_governance_signal", url: evidence.url, fetchedAt: page.fetchedAt,
                                             origin: .pageFetch, summary: evidence.excerpt)
            record.sourceURL = evidence.url
            record.fetchedAt = page.fetchedAt
            record.fit = "Potential Quick Scan fit: own-business AI-use statement. Buying intent unknown."
            record.research?.assessment.supportingEvidence = result.aiUse
            record.research?.assessment.potentialOffer = "AI Governance Quick Scan — 99 CAD plus taxes"
            record.research?.assessment.requiresManualReview = false
        } else {
            record.trigger = nil
            record.fit = nil
            record.research?.assessment.potentialOffer = nil
            record.research?.assessment.supportingEvidence = []
            record.research?.assessment.requiresManualReview = true
        }
        // Any no-solicitation statement on a checked page prevents inferred publication-based outreach.
        if pages.contains(where: \.refusesSolicitation) { record.consent = nil }
        result.contacts = Self.contacts(in: pages, domain: domain)
        // A regular-expression match alone is insufficient: keep only a route with a stored literal source.
        if let route = result.contacts.first(where: { $0.kind == .email }) {
            record.email = route.value
            record.route = ProspectRoute(kind: .email, value: route.value, sourceURL: route.evidence.url)
            record.consent = pages.contains(where: \.refusesSolicitation) ? nil : .conspicuousPublication(route.evidence.url)
        } else {
            record.email = nil
            record.route = nil
            record.consent = nil
        }
        if ProspectIdentity.siteSaysClosed(pages) {
            result.issues.append("The website states that this business is closed.")
            record.status = .drop
            record.reasons = ["closed business"]
        } else if !EvidenceDomain.offDomain(record, config: config).isEmpty {
            record.status = .drop
            record.reasons = ["cross-domain evidence refused"]
        } else {
            let verdict = LeadDefinition.evaluate(record, config: config, now: clock.now)
            record.status = verdict.status
            record.reasons = verdict.reasons
        }
        if !result.complete { result.issues.append("Research cancelled; partial observations retained, no Quick Scan draft prepared.") }
        result.record = record
        return result
    }

    static func contacts(in pages: [SiteExtractor.Page], domain: String) -> [PublishedContactEvidence] {
        var out: [PublishedContactEvidence] = []
        var seen = Set<String>()
        // Prefer business-domain email, then another address explicitly published on the business site.
        let emails = pages.flatMap { page in page.emails.map { (page, $0) } }.sorted {
            let left = MailAddress.domain($0.1).map { HostMatch.belongs($0, to: domain) } == true
            let right = MailAddress.domain($1.1).map { HostMatch.belongs($0, to: domain) } == true
            return left && !right
        }
        for (page, email) in emails {
            guard MailAddress.domain(email) != nil, !email.contains(".."),
                  email.range(of: #"^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil,
                  !["noreply", "no-reply", "donotreply"].contains(email.components(separatedBy: "@")[0]),
                  seen.insert("email:" + email).inserted else { continue }
            let line = page.text.components(separatedBy: .newlines).first { SiteExtractor.normalizePrintedEmail($0).range(of: email, options: .caseInsensitive) != nil }
                ?? page.links.first { $0.lowercased().hasPrefix("mailto:") && MailAddress.bare(String($0.dropFirst(7)).components(separatedBy: "?")[0]) == email }
            let businessDomain = MailAddress.domain(email).map { HostMatch.belongs($0, to: domain) } == true
            let explicitlyAddressed = line?.range(of: #"(?i)(?:contact(?:ez)?[- ]?(?:us|nous)?|[ée]crivez[- ]nous|courriel|email|e-mail)\s*[:–-]"#, options: .regularExpression) != nil
            if let line, businessDomain || explicitlyAddressed {
                out.append(PublishedContactEvidence(kind: .email, value: email, evidence: FactEvidence(url: page.url, excerpt: line)))
            }
        }
        for page in pages {
            for phone in page.phones where seen.insert("phone:" + phone).inserted {
                let line = page.text.components(separatedBy: .newlines).first { $0.contains(phone) }
                    ?? page.links.first { $0 == "tel:" + phone }
                if let line { out.append(PublishedContactEvidence(kind: .phone, value: phone, evidence: FactEvidence(url: page.url, excerpt: line))) }
            }
        }
        return out
    }

    private func crawl(root: URL, domain: String) async -> ([SiteExtractor.Page], [String]) {
        var pages: [SiteExtractor.Page] = []
        var issues: [String] = []
        var queue = [root]
        var seen = Set<String>()
        let budget = max(1, min(config.etiquette.maxPagesPerSite, 6))
        while !queue.isEmpty && seen.count < budget {
            guard !Task.isCancelled else { break }
            let url = queue.removeFirst()
            guard seen.insert(url.absoluteString).inserted else { continue }
            do {
                let response = try await transport.fetch(url, purpose: .ownSite(domain: domain))
                guard (200..<300).contains(response.status),
                      (response.headers["content-type"] ?? "text/html").lowercased().contains("html") else {
                    issues.append("Unreadable page: \(url.absoluteString) (HTTP \(response.status)).")
                    continue
                }
                let page = SiteExtractor.read(html: String(decoding: response.body, as: UTF8.self), url: response.url ?? url, fetchedAt: response.fetchedAt)
                pages.append(page)
                transport.registerSensitive(page.emails + page.phones + page.people.map(\.name))
                for link in page.links {
                    guard var parts = URLComponents(string: link), let host = parts.host,
                          HostMatch.belongs(host, to: domain), ["https", "http"].contains(parts.scheme ?? ""),
                          GuardedLeadTransport.ownSiteHostRefusal(URL(string: link)!) == nil,
                          Self.priority(path: parts.path) != nil else { continue }
                    parts.query = nil; parts.fragment = nil
                    if let next = parts.url, !seen.contains(next.absoluteString), !queue.contains(next) { queue.append(next) }
                }
                queue.sort {
                    let left = Self.priority(path: $0.path) ?? 99
                    let right = Self.priority(path: $1.path) ?? 99
                    return (left, $0.path.count, $0.absoluteString) < (right, $1.path.count, $1.absoluteString)
                }
                if queue.isEmpty && pages.count == 1 {
                    queue = ["/contact", "/equipe", "/a-propos"].compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
                }
            } catch {
                let code = (error as? LeadPipelineRefusal)?.code ?? (Task.isCancelled ? "cancelled" : "network error")
                issues.append("Page not checked: \(url.absoluteString) (\(code)).")
                if code == "refused:bot-challenge" { break }
            }
        }
        return (pages, issues)
    }

    static func priority(path: String) -> Int? {
        let path = path.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        if ["contact", "joindre"].contains(where: path.contains) { return 0 }
        if ["intelligence-artificielle", "artificial-intelligence", "generative", "/ai", "/ia", "chatgpt"].contains(where: path.contains) { return 1 }
        if ["equipe", "team", "leadership", "direction", "people", "about", "a-propos", "agency", "agence", "qui-sommes"].contains(where: path.contains) { return 2 }
        if ["approche", "approach", "method", "expertise", "services"].contains(where: path.contains) { return 3 }
        return nil
    }
}
