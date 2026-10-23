import Foundation

/// Checks Earth's live-proof bar against a run's own CW-AUDIT log and outputs. Used by bin/prove-lead-pipeline
/// on the Mac and unit-tested on synthetic logs.
enum LeadProofVerifier {
    struct Check: Equatable, Sendable {
        var number: Int
        var name: String
        var passed: Bool
        var detail: String
    }

    static func verify(storeCountAtLaunch: Int, auditLines: [String], prospects: [ProspectRecord], drafts: [OutreachDraft],
                       config: ICPConfig, listingDomains: Set<String> = []) -> [Check] {
        let lines = auditLines.compactMap(CWAuditLine.parse).filter { $0["surface"] == "leads" }
        var checks: [Check] = []

        checks.append(Check(number: 1, name: "Leads list and store empty at launch", passed: storeCountAtLaunch == 0,
                            detail: "records at launch: \(storeCountAtLaunch)"))

        let searches = lines.filter { $0["action"] == "search" && $0["source"] == "controlward" && $0["result"] == "ok" }
        let fetches = lines.filter { $0["action"] == "fetch" && $0["source"] == "own-site" && $0["result"] == "ok" }
        let scores = lines.filter { $0["action"] == "score" }
        var unmatched: [String] = []
        for prospect in prospects {
            guard let url = prospect.sourceURL, let fetched = prospect.fetchedAt else { unmatched.append(prospect.id); continue }
            // Check 2 (14:03): both sides go through the one canonicaliser, so a log written before it still re-verifies.
            let register = URLCanonical.register(url)
            let ts = CWAuditLine.timestamp(fetched)
            let fetchMatch = fetches.contains { URLCanonical.register($0["register"]) == register && $0["ts"] == ts }
            let scoreMatch = scores.contains { $0["target"] == prospect.id && URLCanonical.register($0["register"]) == register
                && $0["receipt"]?.hasSuffix("@\(ts)") == true }
            let ownFetcher = prospect.provenance == .controlWardSearch && prospect.fetcher.hasPrefix("controlward")
            if !(fetchMatch && scoreMatch && ownFetcher) { unmatched.append(prospect.id) }
        }
        checks.append(Check(number: 2, name: "Audit has search, own-domain fetch and score with matching source URL and fetch time",
                            passed: !searches.isEmpty && !fetches.isEmpty && !prospects.isEmpty && unmatched.isEmpty,
                            detail: "search=\(searches.count) fetch=\(fetches.count) score=\(scores.count) prospects=\(prospects.count) unmatched=\(unmatched.count)"))

        let drafted = prospects.filter { prospect in drafts.contains { $0.prospectID == prospect.id } }
        let addressFailures = drafted.filter { AddressProvenance.check($0) != nil }.map(\.id)
        // LIVE-R5 (Earth 14:05): report the real Ready count and, for every Ready prospect without a draft, the rule that
        // refused it (from its own draft audit line), so the check never claims there was no Ready prospect when there was.
        let ready = prospects.filter { $0.status == .ready }
        let refusedReady = ready.filter { prospect in !drafts.contains { $0.prospectID == prospect.id } }.map { prospect -> String in
            let code = lines.last { $0["action"] == "draft" && $0["target"] == prospect.id && $0["result"]?.hasPrefix("refused:") == true }?["result"]
            return "\(prospect.id) \(code ?? "no-draft-line")"
        }
        var detail3 = "ready=\(ready.count) drafted=\(drafted.count) failing=\(addressFailures.count)"
        if !refusedReady.isEmpty { detail3 += " refused=[\(refusedReady.joined(separator: ", "))]" }
        if !addressFailures.isEmpty { detail3 += " address-failing=[\(addressFailures.joined(separator: ", "))]" }
        checks.append(Check(number: 3, name: "Address appears verbatim in the own-site snapshot",
                            passed: !drafted.isEmpty && addressFailures.isEmpty, detail: detail3))

        let sender = config.sender
        let badDrafts = drafts.filter { draft in
            !(draft.body.contains(sender.name) && draft.body.contains(sender.organization) && draft.body.contains(sender.mailingAddress)
              && draft.body.contains("mailto:\(sender.unsubscribeMailto)") && draft.listUnsubscribe != nil && draft.consent != nil
              && MailAddress.bare(draft.from) == MailAddress.bare(sender.from))
        }
        checks.append(Check(number: 4, name: "Draft carries sender ID, rue de Rouen address, unsubscribe and consent basis",
                            passed: !drafts.isEmpty && badDrafts.isEmpty, detail: "drafts=\(drafts.count) failing=\(badDrafts.count)"))

        let sends = lines.filter { $0["action"] == "send" }
        let domains = Set(prospects.compactMap(\.businessDomain))
        let offList = lines.compactMap { line -> String? in
            guard ["fetch", "send"].contains(line["action"] ?? ""), let register = line["register"], register != "-",
                  let host = URL(string: register)?.host?.lowercased() else { return nil }
            let allowed = config.allowlist.discoveryHosts + config.allowlist.watchHosts + config.allowlist.gmailHosts
                + config.allowlist.openDataSources.filter(\.enabled).map(\.host)
            if allowed.contains(host) || domains.contains(where: { HostMatch.belongs(host, to: $0) }) { return nil }
            // Earth 10:10: the host a listing names as its own website is allowed for own-site requests, even when the
            // listing never became a prospect (e.g. its site redirected away or could not be read). Any other host fails.
            if line["source"] == "own-site", listingDomains.contains(where: { HostMatch.belongs(host, to: $0) }) { return nil }
            return line["result"]?.hasPrefix("refused:") == true ? nil : host
        }
        checks.append(Check(number: 5, name: "Zero send requests and no off-allowlist host",
                            passed: sends.isEmpty && offList.isEmpty, detail: "send lines=\(sends.count) off-allowlist hosts=\(Set(offList).sorted())"))
        return checks
    }
}

/// Water 12:19 / Earth-Air 12:21: one live sample split across the configured sectors.
enum LeadProofSample {
    /// Even shares in config order; the first sectors take the remainder (60 over 7 = 9,9,9,9,8,8,8).
    static func split(_ total: Int, across ids: [String]) -> [(id: String, limit: Int)] {
        guard !ids.isEmpty, total > 0 else { return [] }
        let base = total / ids.count, extra = total % ids.count
        return ids.enumerated().map { (id: $0.element, limit: base + ($0.offset < extra ? 1 : 0)) }
    }
}
