import Foundation

enum AccountIdentity {
    /// Exact host matching only: never collapse subsidiaries, franchises or public suffixes.
    static func domain(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty, !input.contains("@"), !input.contains(" ") else { return nil }
        guard let url = URLComponents(string: input.contains("://") ? input : "https://" + input),
              ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }),
              !["gmail.com", "outlook.com", "hotmail.com", "yahoo.com", "icloud.com", "proton.me", "protonmail.com"].contains(host) else { return nil }
        return host
    }

    static func candidates(for raw: String, companies: [Company]) -> [Company] {
        guard let key = domain(raw) else { return [] }
        return companies.filter { domain($0.domain) == key }
    }

    static func isVerified(_ company: Company, in gtm: GTMWorkspace, at now: Date) -> Bool {
        guard let review = gtm.identities.last(where: { $0.companyID == company.id && $0.reviewedAt <= now }) else { return false }
        return review.companyName == company.name && review.domain == domain(company.domain) && !review.reason.isEmpty
    }
}
