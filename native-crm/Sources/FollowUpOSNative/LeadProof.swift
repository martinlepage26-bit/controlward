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
                       config: ICPConfig) -> [Check] {
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
            let register = CWAuditLine.register(for: URL(string: url))
            let ts = CWAuditLine.timestamp(fetched)
            let fetchMatch = fetches.contains { $0["register"] == register && $0["ts"] == ts }
            let scoreMatch = scores.contains { $0["target"] == prospect.id && $0["register"] == register && $0["receipt"]?.hasSuffix("@\(ts)") == true }
            let ownFetcher = prospect.provenance == .controlWardSearch && prospect.fetcher.hasPrefix("controlward")
            if !(fetchMatch && scoreMatch && ownFetcher) { unmatched.append(prospect.id) }
        }
        checks.append(Check(number: 2, name: "Audit has search, own-domain fetch and score with matching source URL and fetch time",
                            passed: !searches.isEmpty && !fetches.isEmpty && !prospects.isEmpty && unmatched.isEmpty,
                            detail: "search=\(searches.count) fetch=\(fetches.count) score=\(scores.count) prospects=\(prospects.count) unmatched=\(unmatched.count)"))

        let drafted = prospects.filter { prospect in drafts.contains { $0.prospectID == prospect.id } }
        let addressFailures = drafted.filter { AddressProvenance.check($0) != nil }.map(\.id)
        checks.append(Check(number: 3, name: "Address appears verbatim in the own-site snapshot",
                            passed: !drafted.isEmpty && addressFailures.isEmpty,
                            detail: drafted.isEmpty ? "no draft to check (no Ready prospect in this run)" : "drafted=\(drafted.count) failing=\(addressFailures.count)"))

        let sender = config.sender
        let badDrafts = drafts.filter { draft in
            !(draft.body.contains(sender.name) && draft.body.contains(sender.organization) && draft.body.contains(sender.mailingAddress)
              && draft.body.contains("mailto:\(sender.unsubscribeMailto)") && draft.listUnsubscribe != nil && draft.consent != nil
              && MailAddress.bare(draft.from) == MailAddress.bare(sender.from))
        }
        checks.append(Check(number: 4, name: "Draft carries sender ID, configured mailing address, unsubscribe and consent basis",
                            passed: !drafts.isEmpty && badDrafts.isEmpty, detail: "drafts=\(drafts.count) failing=\(badDrafts.count)"))

        let sends = lines.filter { $0["action"] == "send" }
        let domains = Set(prospects.compactMap(\.businessDomain))
        let offList = lines.compactMap { line -> String? in
            guard ["fetch", "send"].contains(line["action"] ?? ""), let register = line["register"], register != "-",
                  let host = URL(string: register)?.host?.lowercased() else { return nil }
            let allowed = config.allowlist.discoveryHosts + config.allowlist.watchHosts + config.allowlist.gmailHosts
                + config.allowlist.openDataSources.filter(\.enabled).map(\.host)
            if allowed.contains(host) || domains.contains(where: { HostMatch.belongs(host, to: $0) }) { return nil }
            return line["result"]?.hasPrefix("refused:") == true ? nil : host
        }
        checks.append(Check(number: 5, name: "Zero send requests and no off-allowlist host",
                            passed: sends.isEmpty && offList.isEmpty, detail: "send lines=\(sends.count) off-allowlist hosts=\(Set(offList).sorted())"))
        return checks
    }
}
