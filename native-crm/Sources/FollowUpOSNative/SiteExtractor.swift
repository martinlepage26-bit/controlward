import Foundation

/// Reads one page from a business's own site: visible text, a verbatim street address, named people with
/// titles, a public contact route, a consent basis and trigger signals. Nothing here makes a request.
enum SiteExtractor {
    struct Person: Equatable, Sendable {
        var name: String
        var title: String
    }

    struct Page: Equatable, Sendable {
        var url: String
        var fetchedAt: Date
        var text: String
        var links: [String]
        var emails: [String]
        var phones: [String]
        var address: String?
        var people: [Person]
        var linkedinURLs: [String]
        var refusesSolicitation: Bool
    }

    static func read(html: String, url: URL, fetchedAt: Date) -> Page {
        let text = visibleText(html)
        let links = hrefs(html, base: url)
        var emails = links.compactMap { $0.lowercased().hasPrefix("mailto:") ? MailAddress.bare(String($0.dropFirst(7)).components(separatedBy: "?")[0]) : nil }
        emails += matches(text, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}").map { MailAddress.bare($0) }
        var phones = links.compactMap { $0.lowercased().hasPrefix("tel:") ? String($0.dropFirst(4)).removingPercentEncoding : nil }
        phones += matches(text, "\\(?\\b[2-9][0-9]{2}\\)?[ .-][0-9]{3}[ .-][0-9]{4}\\b")
        return Page(url: url.absoluteString, fetchedAt: fetchedAt, text: text, links: links,
                    emails: unique(emails.filter { !$0.isEmpty }), phones: unique(phones),
                    address: address(in: text), people: people(in: text),
                    linkedinURLs: links.filter { URL(string: $0)?.host.map { HostMatch.belongs($0, to: "linkedin.com") } == true },
                    refusesSolicitation: refusesSolicitation(text))
    }

    // MARK: - Text

    static func visibleText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "template", "svg"] {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/address|/section|/article|/footer|/header|p|div|li|h[1-6]|tr|address)\\b[^>]*>",
                                         with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        let named = ["&amp;": "&", "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
                     "&eacute;": "é", "&egrave;": "è", "&ecirc;": "ê", "&agrave;": "à", "&acirc;": "â", "&ccedil;": "ç",
                     "&ocirc;": "ô", "&icirc;": "î", "&ucirc;": "û", "&ugrave;": "ù", "&Eacute;": "É", "&rsquo;": "’", "&ndash;": "–", "&mdash;": "—"]
        var out = text
        for (entity, value) in named { out = out.replacingOccurrences(of: entity, with: value) }
        for match in matches(out, "&#(x?[0-9A-Fa-f]+);") {
            let body = match.dropFirst(2).dropLast()
            let code = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            if let code, let scalar = Unicode.Scalar(code) { out = out.replacingOccurrences(of: match, with: String(Character(scalar))) }
        }
        return out
    }

    static func hrefs(_ html: String, base: URL) -> [String] {
        let raw = captures(html, "href\\s*=\\s*[\"']([^\"']+)[\"']")
        return unique(raw.compactMap { value in
            let decoded = decodeEntities(value)
            if decoded.lowercased().hasPrefix("mailto:") || decoded.lowercased().hasPrefix("tel:") { return decoded }
            return URL(string: decoded, relativeTo: base)?.absoluteURL.absoluteString
        })
    }

    // MARK: - Address, people, consent

    /// A Québec street address on one line of the page, ending with a postal code. Returned exactly as written.
    static func address(in text: String) -> String? {
        let pattern = "\\b\\d{1,5}[A-Za-z]?(?:-\\d{1,5})?,? [^\\n]{3,140}?\\b[A-Za-z]\\d[A-Za-z][ -]?\\d[A-Za-z]\\d\\b"
        for line in text.components(separatedBy: "\n") {
            if let range = line.range(of: pattern, options: .regularExpression) {
                let candidate = String(line[range])
                let lower = candidate.lowercased()
                let streetWords = ["rue", "boul", "avenue", "av.", "chemin", "ch.", "route", "rang", "place", "côte", "cote", "street", "st.", "road", "montée", "promenade", "autoroute", "square", "allée", "terrasse", "croissant", "carré"]
                if streetWords.contains(where: { lower.contains($0) }) { return candidate }
            }
        }
        return nil
    }

    static let titleWords = ["président", "présidente", "president", "directeur", "directrice", "director", "propriétaire", "owner",
                             "fondateur", "fondatrice", "founder", "associé", "associée", "partner", "gestionnaire", "manager",
                             "dentiste", "médecin", "physiothérapeute", "pharmacien", "pharmacienne", "chef", "responsable", "coordonnateur",
                             "coordonnatrice", "vice-président", "vice-présidente", "ceo", "coo", "cto", "dg", "chief"]

    /// "Prénom Nom, Titre", "Prénom Nom – Titre", "Titre : Prénom Nom" or "Dr Prénom Nom" followed by a title line.
    static func people(in text: String) -> [Person] {
        let name = "((?:Dr\\.? |Dre |Me )?[A-ZÀ-Ý][a-zà-ÿ'’]+(?:-[A-ZÀ-Ý][a-zà-ÿ'’]+)?(?: [A-ZÀ-Ý][a-zà-ÿ'’]+(?:-[A-ZÀ-Ý][a-zà-ÿ'’]+)?){1,2})"
        var found: [Person] = []
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.count <= 160 {
            for pair in capturePairs(line, "^\(name)\\s*[,–—|-]\\s*(.{3,80})$") where isTitle(pair.1) {
                found.append(Person(name: clean(pair.0), title: pair.1.trimmingCharacters(in: .whitespaces)))
            }
            for pair in capturePairs(line, "^(.{3,60}?)\\s*:\\s*\(name)$") where isTitle(pair.0) {
                found.append(Person(name: clean(pair.1), title: pair.0.trimmingCharacters(in: .whitespaces)))
            }
            if line.range(of: "^\(name)$", options: .regularExpression) != nil, index + 1 < lines.count,
               lines[index + 1].count <= 80, isTitle(lines[index + 1]) {
                found.append(Person(name: clean(line), title: lines[index + 1]))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func isTitle(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
        return words.contains { titleWords.contains($0) }
    }

    private static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: "^(Dr\\.?|Dre|Me) ", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// A page that says it wants no unsolicited messages removes the conspicuous-publication basis (CASL 10(9)(b)).
    static func refusesSolicitation(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["aucune sollicitation", "pas de sollicitation", "sollicitation interdite", "ne pas solliciter", "no solicitation",
                "no unsolicited", "do not solicit", "messages non sollicités", "courriels non sollicités", "sans sollicitation"].contains { lower.contains($0) }
    }

    /// Trigger signals from icp.json found in a page's own text. Job postings only count on a careers page.
    static func triggers(in page: Page, segment: ICPConfig.Segment, config: ICPConfig) -> [ProspectTrigger] {
        let path = (URL(string: page.url)?.path ?? "").lowercased()
        var out: [ProspectTrigger] = []
        for kind in segment.triggers {
            if kind == "job_posting", !["carri", "emploi", "career", "job"].contains(where: { path.contains($0) }) { continue }
            guard let phrase = config.triggerSignals[kind]?.first(where: { phraseMatches($0, in: page.text) }) else { continue }
            out.append(ProspectTrigger(kind: kind, url: page.url, fetchedAt: page.fetchedAt, origin: .pageFetch,
                                       publishedAt: kind == "job_posting" ? publishedDate(in: page.text) : nil,
                                       summary: "\(kind): “\(phrase)” on \(path.isEmpty ? "/" : path)"))
        }
        return out
    }

    /// Water 12:19, Earth/Air 12:21: a trigger phrase counts only as whole words. An all-capitals acronym
    /// ("AI", "IA") matches only in capitals, so "j'ai", "said", "via" or "média" never count; every other
    /// phrase matches in any case, with or without accents ("Decision automatisee" = "décision automatisée").
    static func phraseMatches(_ phrase: String, in text: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let acronym = trimmed.count >= 2 && trimmed.allSatisfy { $0.isLetter && $0.isUppercase }
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA")).lowercased()
        }
        let needle = acronym ? trimmed : fold(trimmed)
        let haystack = acronym ? text : fold(text)
        let words = needle.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }

    /// A date written as YYYY-MM-DD on the page (used for job postings).
    static func publishedDate(in text: String) -> Date? {
        guard let match = matches(text, "\\b20[0-9]{2}-[01][0-9]-[0-3][0-9]\\b").first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Toronto")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: match)
    }

    // MARK: - Regex helpers

    static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    static func capturePairs(_ text: String, _ pattern: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard $0.numberOfRanges > 2, $0.range(at: 1).location != NSNotFound, $0.range(at: 2).location != NSNotFound else { return nil }
            return (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
