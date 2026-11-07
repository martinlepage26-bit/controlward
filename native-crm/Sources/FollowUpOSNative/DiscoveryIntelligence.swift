import Foundation

struct DiscoveryBusiness: Identifiable, Sendable {
    var id: String
    var candidate: DiscoveryCandidate
    var aliases: [DiscoveryCandidate]
    var research: QuickScanResearchResult?

    var verifiedWebsite: Bool {
        guard let research, research.complete, let domain = research.record.businessDomain,
              research.record.id == "cw:" + candidate.sourceID,
              let websiteHost = DiscoveryIntelligence.host(candidate.website),
              !DiscoveryIntelligence.isSharedRoot(websiteHost), HostMatch.belongs(websiteHost, to: domain) else { return false }
        return research.record.snapshots.contains { HostMatch.belongs($0.host, to: domain) && !$0.text.isEmpty }
    }
    var supportedContacts: [PublishedContactEvidence] {
        guard verifiedWebsite, let research else { return [] }
        return research.contacts.filter { $0.isSupported(in: research.record) }
    }
}

struct DiscoveryAttention: Identifiable, Sendable {
    var business: DiscoveryBusiness
    var fit: DiscoveryFit
    var fitReason: String
    var enquiries: [Lead]
    var recentOpenEnquiries: [Lead]
    var latestRecentAt: Date?
    var interestReasons: [String]
    var id: String { business.id }
    var interestLabel: String {
        if !business.verifiedWebsite && !enquiries.isEmpty { return "Enquiry link retained; business website needs reverification" }
        if !recentOpenEnquiries.isEmpty { return "Recorded interest: \(recentOpenEnquiries.count) recent enquiries on open CRM leads" }
        if !enquiries.isEmpty { return "Historical or incomplete enquiry evidence; current interest unknown" }
        return "Interest unknown: no confirmed enquiry link"
    }
    var contactabilityLabel: String {
        let contacts = business.supportedContacts
        return contacts.isEmpty ? "Contactability unknown: no supported website route" : "Website-published route: " + contacts.map(\.value).joined(separator: ", ")
    }
}

enum DiscoveryIntelligence {
    /// These roots contain many unrelated businesses. A shared root cannot deduplicate their identities.
    private static let sharedRoots: Set<String> = ["facebook.com", "instagram.com", "linkedin.com", "x.com", "twitter.com", "google.com", "sites.google.com", "etsy.com", "wixsite.com", "wordpress.com", "blogspot.com", "github.io", "notion.site"]
    private static let sharedMail: Set<String> = ["gmail.com", "outlook.com", "hotmail.com", "yahoo.com", "icloud.com", "me.com", "proton.me", "protonmail.com"]
    static func isSharedRoot(_ host: String) -> Bool { sharedRoots.contains(host) }

    static func host(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw.contains("://") ? raw : "https://" + raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), host.contains(".") else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    static func businessKey(_ candidate: DiscoveryCandidate, research: QuickScanResearchResult? = nil) -> String {
        let evidence = DiscoveryBusiness(id: "", candidate: candidate, aliases: [], research: research)
        guard evidence.verifiedWebsite, let host = host(candidate.website), !sharedRoots.contains(host),
              let name = research?.record.organisation, !name.isEmpty else { return "source:" + candidate.sourceID }
        let identity = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        guard !identity.isEmpty, identity.count <= 500 else { return "source:" + candidate.sourceID }
        return "host:" + host + "|organisation:" + identity
    }

    /// One website group, including repeated map and agent findings. Source aliases remain available.
    static func businesses(_ cache: WebsiteResearchCache) -> [DiscoveryBusiness] {
        Dictionary(grouping: cache.candidates, by: { businessKey($0, research: cache.results[$0.sourceID]) }).map { key, aliases in
            let sorted = aliases.sorted {
                let a = cache.results[$0.sourceID]?.checkedAt ?? .distantPast
                let b = cache.results[$1.sourceID]?.checkedAt ?? .distantPast
                return a == b ? $0.sourceID < $1.sourceID : a > b
            }
            return DiscoveryBusiness(id: key, candidate: sorted[0], aliases: sorted, research: cache.results[sorted[0].sourceID])
        }.sorted { $0.id < $1.id }
    }

    static func enquiries(_ leads: [Lead]) -> [Lead] {
        let sourced = leads.filter { $0.sourceID?.hasPrefix("kairos:") == true }
        return Dictionary(grouping: sourced, by: { $0.sourceID! }).values.compactMap { rows in
            rows.sorted { ($0.sourceUpdatedAt ?? "", $0.id.uuidString) > ($1.sourceUpdatedAt ?? "", $1.id.uuidString) }.first
        }.sorted { ($0.sourceUpdatedAt ?? "", $0.id.uuidString) > ($1.sourceUpdatedAt ?? "", $1.id.uuidString) }
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func attention(cache: WebsiteResearchCache, leads: [Lead], now: Date = .now) -> [DiscoveryAttention] {
        let incoming = enquiries(leads)
        let dates = Dictionary(uniqueKeysWithValues: incoming.map { ($0.sourceID!, date($0.sourceUpdatedAt)) })
        let linkedByBusiness = Dictionary(grouping: incoming.filter { cache.enquiryBusinessLinks?[$0.sourceID!]?.businessKey != nil }) {
            cache.enquiryBusinessLinks![$0.sourceID!]!.businessKey!
        }
        return businesses(cache).map { business in
            let review = cache.fitReviews?[business.id]
            let currentReview = review == nil || review?.strategyRevision == cache.kairosContext?.strategyRevision
            let fit = currentReview ? (review?.decision ?? .unassessed) : .unassessed
            let reason = currentReview ? (review?.reason ?? "Review this business against your audience and offer.") : "KAIROS targeting changed; review the previous fit decision again."
            let linked = linkedByBusiness[business.id] ?? []
            let recent = linked.filter {
                guard business.verifiedWebsite, $0.status.isOpen, !($0.sourceMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let state = cache.kairosContext?.enquiryStates?[$0.sourceID!], state.eligible, state.lastMessageAt == $0.sourceUpdatedAt,
                      let at = dates[$0.sourceID!]?.flatMap({ $0 }), at <= now, now.timeIntervalSince(at) <= 30 * 86_400 else { return false }
                return true
            }
            let reasons = linked.map { enquiry -> String in
                guard let state = cache.kairosContext?.enquiryStates?[enquiry.sourceID!] else {
                    if cache.kairosContext?.enquiryStates != nil {
                        return "\(enquiry.sourceID!): absent from the bounded inbox window. Earlier evidence is retained; absence is not retraction and current classification is unknown."
                    }
                    return "\(enquiry.sourceID!): refresh KAIROS context to verify the current source classification."
                }
                return "\(enquiry.sourceID!): KAIROS intent \(state.intent), status \(state.status), incoming text \(state.hasIncomingText ? "available" : "unavailable"), source date \(state.lastMessageAt). Retrieved \(cache.kairosContext?.inboxFetchedAt ?? cache.kairosContext?.fetchedAt ?? "unknown"). Closed, older or mismatched records stay historical."
            }
            return DiscoveryAttention(business: business, fit: fit, fitReason: reason, enquiries: linked, recentOpenEnquiries: recent,
                                      latestRecentAt: recent.compactMap { dates[$0.sourceID!]?.flatMap({ $0 }) }.max(), interestReasons: reasons)
        }.sorted {
            if ($0.fit == .outside) != ($1.fit == .outside) { return $0.fit != .outside }
            if $0.recentOpenEnquiries.isEmpty != $1.recentOpenEnquiries.isEmpty { return !$0.recentOpenEnquiries.isEmpty }
            if ($0.fit == .fits) != ($1.fit == .fits) { return $0.fit == .fits }
            if $0.business.supportedContacts.isEmpty != $1.business.supportedContacts.isEmpty { return !$0.business.supportedContacts.isEmpty }
            let a = $0.latestRecentAt ?? .distantPast
            let b = $1.latestRecentAt ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
    }

    /// Suggestions only. A domain mentioned in a message does not prove sender ownership.
    static func suggestion(_ enquiry: Lead, for business: DiscoveryBusiness) -> String? {
        suggestions(enquiry, businesses: [business])[business.id]
    }

    /// Extract identity hints once per enquiry, even when reviewing many website groups.
    static func suggestions(_ enquiry: Lead, businesses: [DiscoveryBusiness]) -> [String: String] {
        let text = enquiry.sourceMessage ?? ""
        let ns = text as NSString
        var hosts = Set<String>(), mailboxes = Set<String>()
        let urls = try? NSRegularExpression(pattern: #"(?i)(?:https?://|www\.)[^\s<>\"()]+"#)
        for match in urls?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if let value = host(ns.substring(with: match.range)) { hosts.insert(value) }
        }
        let emails = try? NSRegularExpression(pattern: #"(?i)[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@([a-z0-9-]+(?:\.[a-z0-9-]+)+)"#)
        for match in emails?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            mailboxes.insert(ns.substring(with: match.range).lowercased())
        }
        guard !hosts.isEmpty || !mailboxes.isEmpty else { return [:] }
        let domains = Set(mailboxes.compactMap { $0.split(separator: "@").last.map(String.init) }.filter { !sharedMail.contains($0) })
        var out: [String: String] = [:]
        for business in businesses where business.verifiedWebsite {
            guard let domain = host(business.candidate.website) else { continue }
            if hosts.contains(domain) {
                out[business.id] = "The incoming text mentions this website (\(domain)). Check the sender's relationship before confirming."
            } else if business.supportedContacts.contains(where: { $0.kind == .email && mailboxes.contains($0.value.lowercased()) }) {
                out[business.id] = "The incoming text contains the website-published mailbox. Confirm which business the enquiry concerns."
            } else if domains.contains(domain) {
                out[business.id] = "The incoming text contains an email at this business domain. Sender ownership is unverified; confirm the association."
            }
        }
        return out
    }
}
