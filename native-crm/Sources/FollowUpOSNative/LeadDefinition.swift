import Foundation

/// LEAD_DEF (S3-R1, S3-R12, S3-R13): one predicate that decides Ready, Fix, Drop or conflict review.
/// Every clause is a separate function so each can be tested on its own.
enum LeadDefinition {
    struct Verdict: Equatable, Sendable {
        var status: ProspectStatus
        var reasons: [String]
        var isLead: Bool { status == .ready }
    }

    static func evaluate(_ prospect: ProspectRecord, config: ICPConfig, now: Date) -> Verdict {
        guard let segment = config.segment(prospect.segment) else {
            return Verdict(status: .drop, reasons: ["no matching segment"])
        }
        // Each hold is its own reason. Lavoie is the conflict area. The licence check is rbq-licence-unverified.
        var holdReasons: [String] = []
        if let area = conflictArea(for: prospect, config: config) {
            holdReasons.append("conflict area: \(area.id)")
        }
        if rbqLicenceUnverified(prospect, config: config) {
            let check = prospect.rbqCheck ?? "not run"
            holdReasons.append("\(config.rbqLicenceHold?.id ?? "rbq-licence-unverified") (RBQ check: \(check))")
        }
        if !holdReasons.isEmpty {
            return Verdict(status: .conflictReview, reasons: holdReasons)
        }
        var reasons: [String] = []
        reasons += sourceEvidence(prospect)
        if let reason = namedPerson(prospect, segment: segment, config: config) { reasons.append(reason) }
        reasons += recordFields(prospect)
        reasons += triggerFreshness(prospect.trigger, segment: segment, config: config, now: now)
        // LIVE-R5 (Earth 14:05): Ready requires a recorded consent basis (S3-R6); without one the record stays Fix.
        if prospect.consent == nil { reasons.append("no consent basis recorded") }
        if prospect.openTenderURL != nil { reasons.append("open tender") }
        return Verdict(status: reasons.isEmpty ? .ready : .fix, reasons: reasons)
    }

    /// S3-R5: a source URL and a fetch time on every record.
    static func sourceEvidence(_ prospect: ProspectRecord) -> [String] {
        var reasons: [String] = []
        if (prospect.sourceURL ?? "").isEmpty || URL(string: prospect.sourceURL ?? "")?.host == nil { reasons.append("no source URL") }
        if prospect.fetchedAt == nil { reasons.append("no fetch time") }
        return reasons
    }

    /// The named-person rule, kept isolated (Water, 6:05 AM ET): a person from a source the segment allows,
    /// and that source must be enabled in config. There is no role-addressed path.
    static func namedPerson(_ prospect: ProspectRecord, segment: ICPConfig.Segment, config: ICPConfig) -> String? {
        guard let contact = prospect.contact,
              contact.name.split(separator: " ").count >= 2 else { return "no named person" }
        guard segment.allowedContactSources.contains(contact.source.rawValue) else { return "no named person" }
        if contact.source != .ownSite {
            let disabled = config.allowlist.disabledSources.first { $0.id == contact.source.rawValue }
            if disabled?.enabled != true { return "no named person" }
        }
        return nil
    }

    /// S3-R12: the remaining fields of a complete lead record.
    static func recordFields(_ prospect: ProspectRecord) -> [String] {
        var reasons: [String] = []
        if prospect.contact?.titleSource == nil { reasons.append("no title source") }
        if prospect.trigger?.url == nil || prospect.trigger?.fetchedAt == nil { reasons.append("no trigger URL with fetch time") }
        if (prospect.fit ?? "").trimmingCharacters(in: .whitespaces).isEmpty { reasons.append("no fit line") }
        if prospect.route == nil || prospect.route?.value.isEmpty == true { reasons.append("no public contact route") }
        return reasons
    }

    /// S3-R13: institutional triggers within the configured age; clinic and trades triggers fetched today.
    /// Search snippets and inferred triggers never count.
    static func triggerFreshness(_ trigger: ProspectTrigger?, segment: ICPConfig.Segment, config: ICPConfig, now: Date) -> [String] {
        guard let trigger, let fetchedAt = trigger.fetchedAt else { return [] }
        if trigger.origin == .searchSnippet || trigger.origin == .inferred { return ["trigger is a \(trigger.origin.rawValue)"] }
        if !segment.triggers.contains(trigger.kind) { return ["trigger kind not allowed for segment"] }
        if trigger.state == .gone { return ["trigger gone"] }
        guard let rule = config.triggerRules[segment.triggerRule] else { return ["unknown trigger rule"] }
        if rule.maxFetchAgeDays == 0 {
            if !sameLocalDay(fetchedAt, now) { return ["stale trigger"] }
        } else if now.timeIntervalSince(fetchedAt) > Double(rule.maxFetchAgeDays) * 86_400 {
            return ["stale trigger"]
        }
        if trigger.kind == "job_posting", let limit = rule.jobPostingMaxAgeDays {
            guard let published = trigger.publishedAt else { return ["job posting without a date"] }
            if now.timeIntervalSince(published) > Double(limit) * 86_400 { return ["stale trigger"] }
        }
        return []
    }

    /// The day as Martin sees it (Montréal).
    static func sameLocalDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        return calendar.isDate(a, inSameDayAs: b)
    }

    /// Martin Lepage, 27 Oct 2026, 4:30 PM ET: a construction firm anywhere is held when the RBQ lookup is missing,
    /// corrupt, an error, or no licence match. A verified match (`rbqCheck == "matched"`) passes. The reason id
    /// comes from `rbq_licence_hold` and is not a conflict-area id.
    static func rbqLicenceUnverified(_ prospect: ProspectRecord, config: ICPConfig) -> Bool {
        guard let hold = config.rbqLicenceHold, prospect.rbqCheck != "matched", let segment = prospect.segment else { return false }
        return hold.segments.contains(segment)
    }

    /// S3-R14 / S3-R17d: plumbing and excavation in the configured municipalities are held for Martin.
    /// Martin Lepage, 27 Oct 2026, 3:55 PM ET: nothing outside those municipalities conflicts with SOS.
    /// 3:56 PM ET: the firm must also be plumbing or excavation (selectors, keywords, or the area's RBQ codes).
    /// 4:30 PM ET: the municipalities are Québec region 02. A town that cannot be read stays fail-closed when
    /// the trade signals or the codes match. RBQ licences hold on exact sub-category codes from config
    /// (one JSON record per licence), never on words.
    static func conflictArea(for prospect: ProspectRecord, config: ICPConfig) -> ICPConfig.ConflictArea? {
        // Water 9:02 AM ET: map tags, keywords and licence codes all hold only inside the area's municipalities, or when the
        // firm's town can't be read (fail closed). Outside the area none of them holds.
        let town = firmTown(prospect)
        return config.conflictAreas.first { area in
            guard rbqAreaMatch(town, area: area) != .outside else { return false }
            return tradeSignalsMatch(prospect, area: area)
                || !rbqHeldCodes(prospect.rbqCategories, area: area, municipality: town).isEmpty
        }
    }

    /// The area's selectors or keywords. RBQ codes are a separate signal (`rbqHeldCodes`).
    static func tradeSignalsMatch(_ prospect: ProspectRecord, area: ICPConfig.ConflictArea) -> Bool {
        let haystack = ([prospect.organisation] + prospect.osmTags + prospect.snapshots.prefix(1).map(\.text)).joined(separator: " ").lowercased()
        return area.osmSelectors.contains { prospect.osmTags.contains($0) }
            || area.keywords.contains { haystack.contains($0.lowercased()) }
    }

    /// The firm's town for the conflict area: the licence's Municipalité, else the map listing's town; nil when neither reads.
    static func firmTown(_ prospect: ProspectRecord) -> String? {
        [prospect.rbqMunicipality, prospect.town].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Where a licence sits relative to the area's `municipalities`.
    enum RBQAreaMatch: Equatable, Sendable {
        /// Whole-value match on one configured municipality (the configured spelling).
        case inside(String)
        case outside
        /// No readable location: held (fail closed).
        case unknown
    }

    /// Normalised whole-value match, then the rest of Québec, then containment. An exact key on `municipalities` is
    /// inside (the configured spelling). A G7/G8 postal code anywhere in the address is unknown. An exact key on the
    /// MAMH province list, or a comma-separated locality that is another Québec municipality or not a Québec
    /// municipality at all, is outside. A town that only contains a listed name, and is none of those, is unknown.
    /// Blank is unknown. An area without `municipalities` applies everywhere (the region alone).
    static func rbqAreaMatch(_ municipality: String?, area: ICPConfig.ConflictArea) -> RBQAreaMatch {
        guard let places = area.municipalities else { return .inside(area.region) }
        let key = municipality.map(placeKey) ?? ""
        guard !key.isEmpty else { return .unknown }
        if let exact = places.first(where: { placeKey($0) == key }) { return .inside(exact) }
        let unresolved = area.unresolvedPlaceNames ?? []
        if unresolved.contains(where: { placeKey($0) == key }) { return .unknown }
        if let text = municipality, containsHeldPostal(text, prefixes: area.postalFsaPrefixes ?? []) { return .unknown }
        let regionKeys = Set(places.map(placeKey))
        let provinceKeys = Set((area.provinceMunicipalities ?? []).map(placeKey))
        if provinceKeys.contains(key), !regionKeys.contains(key) { return .outside }
        if let text = municipality, let locality = commaLocality(text) {
            let loc = placeKey(locality)
            if let exact = places.first(where: { placeKey($0) == loc }) { return .inside(exact) }
            if !loc.isEmpty { return .outside }
        }
        if outsideByOfficialSuffix(key, provinceKeys: provinceKeys, regionKeys: regionKeys) { return .outside }
        let padded = " \(key) "
        func containsListed(_ names: [String]) -> Bool {
            names.contains { listed in
                let needle = placeKey(listed)
                return !needle.isEmpty && padded.contains(" \(needle) ")
            }
        }
        if containsListed(places) || containsListed(unresolved) { return .unknown }
        return .outside
    }

    /// True when the address contains a Canadian postal code or FSA whose FSA starts with a configured prefix.
    private static func containsHeldPostal(_ text: String, prefixes: [String]) -> Bool {
        let foldedPrefixes = prefixes.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }.filter { !$0.isEmpty }
        guard !foldedPrefixes.isEmpty else { return false }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"\b([a-z]\d[a-z])(?:\s*\d[a-z]\d)?\b"#) else { return false }
        let range = NSRange(folded.startIndex..., in: folded)
        for match in regex.matches(in: folded, range: range) {
            guard let hit = Range(match.range(at: 1), in: folded) else { continue }
            let fsa = String(folded[hit])
            if foldedPrefixes.contains(where: { fsa.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// The last comma-separated part, after a trailing QC / Québec, when the address has a street or another place beside it.
    private static func commaLocality(_ text: String) -> String? {
        var parts = text.split(separator: ",", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        while let last = parts.last {
            let key = placeKey(last)
            if key == "qc" || key == "quebec" { parts.removeLast(); continue }
            break
        }
        guard parts.count >= 2, let locality = parts.last else { return nil }
        return locality
    }

    /// A longer official name outside region 02 whose key ends with this town (a leading "la " may be dropped).
    /// La Baie-James is the repertoire row Eeyou Istchee Baie-James, not the borough La Baie.
    private static func outsideByOfficialSuffix(_ key: String, provinceKeys: Set<String>, regionKeys: Set<String>) -> Bool {
        var candidates = [key]
        if key.hasPrefix("la ") { candidates.append(String(key.dropFirst(3))) }
        var hits = Set<String>()
        for candidate in candidates where candidate.split(separator: " ").count >= 2 {
            for official in provinceKeys where !regionKeys.contains(official) && official.hasSuffix(" " + candidate) {
                hits.insert(official)
            }
        }
        return hits.count == 1
    }

    /// Case, accents, collapsed whitespace, hyphens and spaces alike, punctuation stripped, bracketed parts removed,
    /// a trailing ", QC" or ", Québec" removed, a leading "Ville de" / "Ville d'" or "Municipalité de" / "Municipalité d'" removed,
    /// and a whole token "St" or "Ste" expanded to "Saint" or "Sainte".
    static func placeKey(_ text: String) -> String {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        raw = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        var folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var stripping = true
        while stripping {
            stripping = false
            let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [", qc", ", quebec"] where trimmed.hasSuffix(suffix) {
                folded = String(trimmed.dropLast(suffix.count))
                stripping = true
            }
        }
        var tokens: [String] = []
        var token = ""
        func flush() {
            if !token.isEmpty { tokens.append(token); token = "" }
        }
        for scalar in folded.unicodeScalars {
            if breaksPlaceToken(scalar) { flush() } else { token.unicodeScalars.append(scalar) }
        }
        flush()
        for index in tokens.indices {
            if tokens[index] == "st" { tokens[index] = "saint" }
            else if tokens[index] == "ste" { tokens[index] = "sainte" }
        }
        while tokens.count >= 2, (tokens[0] == "ville" || tokens[0] == "municipalite"), tokens[1] == "de" || tokens[1] == "d" {
            tokens.removeFirst(2)
        }
        return tokens.joined(separator: " ")
    }

    private static func breaksPlaceToken(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        if "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}".unicodeScalars.contains(scalar) { return true }
        if scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar) { return false }
        return true
    }

    /// The codes that hold this licence where it is: none outside the area; inside it, or with no readable location, the codes.
    static func rbqHeldCodes(_ licenceCodes: [String], area: ICPConfig.ConflictArea, municipality: String?) -> [String] {
        rbqAreaMatch(municipality, area: area) == .outside ? [] : rbqHeldCodes(licenceCodes, area: area)
    }

    /// The listed RBQ codes that hold a licence with these sub-categories, wherever it is (the area rule is applied by the
    /// overload with `municipality:`, which the app and bin/prove-rbq-hold both use).
    static func rbqHeldCodes(_ licenceCodes: [String], area: ICPConfig.ConflictArea) -> [String] {
        let codes = Set(licenceCodes.map(RBQOpenData.normalizeCode))
        return (area.rbqSubcategoryCodes ?? []).map(RBQOpenData.normalizeCode).filter { code in
            guard codes.contains(code) else { return false }
            // Water 7:20 / 7:26 AM ET (Air's map 10c): a code with a condition does not hold a licence that carries the whole
            // configured bundle or any code with a configured prefix. The codes and prefixes come from icp.json only.
            for condition in area.rbqCodeConditions ?? [] where RBQOpenData.normalizeCode(condition.code) == code {
                let bundle = condition.notHeldIfAllOf.map(RBQOpenData.normalizeCode)
                if !bundle.isEmpty && bundle.allSatisfy(codes.contains) { return false }
                let prefixes = condition.notHeldIfAnyCodeStartsWith.map(RBQOpenData.normalizeCode).filter { !$0.isEmpty }
                if codes.contains(where: { held in prefixes.contains { held.hasPrefix($0) } }) { return false }
            }
            return true
        }
    }

    /// S3-R3: the real-lead count excludes test leads and anything that fails LEAD_DEF.
    static func realLeadCount(_ prospects: [ProspectRecord], config: ICPConfig, now: Date) -> Int {
        prospects.filter { !$0.isTest && $0.provenance != .test && evaluate($0, config: config, now: now).isLead }.count
    }

    /// The risk line shown with each lead (unit-tested, not a planted red).
    static func riskLine(_ prospect: ProspectRecord) -> String {
        if prospect.openTenderURL != nil { return "Open tender: outreach blocked until it closes." }
        switch prospect.trigger?.state {
        case .gone?: return "Trigger gone: the page no longer shows it."
        case .changed?: return "Trigger changed since the last check: re-read before writing."
        default: break
        }
        if prospect.contact?.titleSource == .searchOnly { return "Title seen only in search: confirm on the page before writing." }
        if prospect.consent == nil { return "No consent basis recorded: no draft." }
        // Earth 12:19: only a trigger with a fetch time is a dated trigger; without one there is nothing to write about.
        if prospect.trigger?.url == nil || prospect.trigger?.fetchedAt == nil { return "No trigger on the own site with a fetch time: no draft." }
        return "Low: own-site evidence, dated trigger."
    }
}

/// S3-R10: an address counts only if it appears word for word in a stored page from the business's own domain.
enum AddressProvenance {
    static func check(_ prospect: ProspectRecord) -> LeadPipelineRefusal? {
        let refusal = LeadPipelineRefusal(code: "refused:address-provenance")
        guard let address = prospect.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty,
              prospect.addressSource == .ownSite,
              let domain = prospect.businessDomain,
              let sourceURL = prospect.addressSourceURL, let sourceHost = URL(string: sourceURL)?.host,
              HostMatch.belongs(sourceHost, to: domain) else { return refusal }
        // The contact route must also come from the business's own site: never an RBQ Courriel or phone.
        if let route = prospect.route {
            guard route.source == .ownSite, let routeHost = URL(string: route.sourceURL)?.host,
                  HostMatch.belongs(routeHost, to: domain) else { return refusal }
        }
        let found = prospect.snapshots.contains { snapshot in
            snapshot.url == sourceURL && HostMatch.belongs(snapshot.host, to: domain) && snapshot.text.contains(address)
        }
        return found ? nil : refusal
    }

    /// The consent basis must come from the business's own domain too (S3-R10).
    static func consentFromOwnDomain(_ prospect: ProspectRecord) -> Bool {
        guard let consent = prospect.consent else { return false }
        guard case .conspicuousPublication(let url) = consent else { return true }
        guard let domain = prospect.businessDomain, let host = URL(string: url)?.host else { return false }
        return HostMatch.belongs(host, to: domain) && prospect.snapshots.contains { $0.url == url }
    }
}

/// LIVE-R6 (Earth 14:05): every evidence URL on a record is on that record's own site domain. Hosts of the enabled
/// open-data registries and watch feeds in the allowlist are exempt (a public registry tied to the same organisation).
/// A violation is a hard fail: ingest and the search run refuse the record, and proof check 6 fails.
enum EvidenceDomain {
    static func urls(_ record: ProspectRecord) -> [String] {
        var out = [record.sourceURL, record.addressSourceURL, record.contact?.sourceURL, record.route?.sourceURL, record.trigger?.url].compactMap { $0 }
        out += record.snapshots.map(\.url)
        if case .conspicuousPublication(let url)? = record.consent { out.append(url) }
        if let research = record.research {
            out += research.observedFacts.evidence.keys.sorted().flatMap { research.observedFacts.evidence[$0]?.map(\.url) ?? [] }
            out += research.assessment.supportingEvidence.map(\.url)
        }
        return out.filter { !$0.isEmpty }
    }

    /// The off-domain evidence URLs on a record. A record without an own domain has no evidence that can be checked,
    /// so every URL it carries counts as off-domain.
    static func offDomain(_ record: ProspectRecord, config: ICPConfig) -> [String] {
        let exempt = Set((config.allowlist.openDataSources.filter(\.enabled).map(\.host) + config.allowlist.watchHosts).map { $0.lowercased() })
        return urls(record).filter { url in
            guard let host = URL(string: url)?.host?.lowercased() else { return true }
            if exempt.contains(host) { return false }
            guard let domain = record.businessDomain, !domain.isEmpty else { return true }
            return !HostMatch.belongs(host, to: domain)
        }
    }
}

