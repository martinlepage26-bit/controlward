import Foundation

/// Complete published ASCII tokens only. Unsupported neighbouring text must never
/// become a different mailbox; this is not a deliverability or ownership check.
enum PublishedEmailRules {
    private static let atom = #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}"#

    static func key(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"\A"# + atom + #"\z"#, options: .regularExpression) != nil,
              !value.contains(".."), let local = value.split(separator: "@").first,
              !local.hasPrefix("."), !local.hasSuffix(".") else { return nil }
        return value.lowercased() // Only the already-validated ASCII address is normalized.
    }

    static func addresses(in text: String) -> [String] {
        let printed = SiteExtractor.normalizePrintedEmail(text)
        let pattern = #"(?<![^\s(<>,:])"# + atom + #"(?=$|[\s<>,;)\]]|[.!?](?=\s|$))"#
        return SiteExtractor.matches(printed, pattern).compactMap(key)
    }

    static func mailto(_ link: String) -> String? {
        guard link.utf8.count <= 4096, link.prefix(7).lowercased() == "mailto:" else { return nil }
        let recipient = link.dropFirst(7).prefix { $0 != "?" && $0 != "#" }
        // Decode one URI layer only; HTML entities were decoded when the href was read.
        guard let decoded = String(recipient).removingPercentEncoding else { return nil }
        return key(decoded)
    }
}

/// A structural check, not a subscriber lookup or proof that a business owns a number.
/// NANP format and fictional range: https://nanpa.com/about and
/// https://www.nanpa.com/numbering/555-line-numbers (checked 2026-11-08).
enum PublishedPhoneRules {
    static func key(_ raw: String) -> String? {
        guard raw.utf8.count <= 160 else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ";")
        guard let first = parts.first, first.range(of: #"^\+?[0-9() .\-\x{00A0}]+$"#, options: .regularExpression) != nil else { return nil }
        let digits = first.filter(\.isNumber)
        var extensionSuffix = ""
        if parts.count > 1 {
            guard parts.count == 2, parts[1].range(of: #"(?i)^ext=[0-9]{1,8}$"#, options: .regularExpression) != nil else { return nil }
            extensionSuffix = ";" + parts[1].lowercased()
        }
        let global = first.hasPrefix("+")
        let national: String
        if digits.count == 11 && digits.hasPrefix("1") { national = String(digits.dropFirst()) }
        else if !global && digits.count == 10 { national = digits }
        else {
            // Retain other complete-looking global routes without guessing a country or checking assignment.
            guard global, (7...15).contains(digits.count), let start = digits.first,
                  start != "0", start != "1" else { return nil }
            return "+" + digits + extensionSuffix
        }
        let characters = Array(national)
        guard ("2"..."9").contains(characters[0]), ("2"..."9").contains(characters[3]) else { return nil }
        // Only the administrator's explicitly fictional block is excluded here; other numbers
        // are not asserted to be assigned, reachable or personally owned.
        if national.dropFirst(3).hasPrefix("555"), let line = Int(national.suffix(4)), (100...199).contains(line) { return nil }
        return "+1" + national + extensionSuffix
    }
}

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
        /// LIVE-R4: the page's body text only: no nav, header or footer, and no link text. Trigger phrases are matched here.
        var bodyText: String = ""
        /// Own-business prose with inline link text retained, but no navigation or quoted testimonials.
        var claimText: String = ""
        var links: [String]
        var emails: [String]
        var phones: [String]
        /// Raw candidates remain available for audit redaction; only structurally usable routes enter phones.
        var phoneCandidates: [String] = []
        var address: String?
        var people: [Person]
        var linkedinURLs: [String]
        var refusesSolicitation: Bool
    }

    static func read(html: String, url: URL, fetchedAt: Date) -> Page {
        let text = visibleText(html)
        let links = hrefs(html, base: url)
        let emails = links.compactMap(PublishedEmailRules.mailto) + PublishedEmailRules.addresses(in: text)
        var phones = links.compactMap { $0.lowercased().hasPrefix("tel:") ? String($0.dropFirst(4)).removingPercentEncoding : nil }
        phones += matches(text, "\\(?\\b[2-9][0-9]{2}\\)?[ .-][0-9]{3}[ .-][0-9]{4}\\b")
        return Page(url: url.absoluteString, fetchedAt: fetchedAt, text: text, bodyText: bodyText(html), claimText: claimText(html), links: links,
                    emails: unique(emails.filter { !$0.isEmpty }), phones: unique(phones.filter { PublishedPhoneRules.key($0) != nil }), phoneCandidates: unique(phones),
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

    /// LIVE-R4: visible text without nav, header and footer blocks and without any link text. Each removed block becomes a
    /// line break, so every body line is still a verbatim piece of the page's visible text.
    static func bodyText(_ html: String) -> String {
        var body = html
        for tag in ["script", "style", "noscript", "template", "svg", "nav", "header", "footer", "a"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "<br>", options: [.regularExpression, .caseInsensitive])
        }
        return visibleText(body)
    }

    static func claimText(_ html: String) -> String {
        var body = html
        for tag in ["nav", "header", "footer", "blockquote"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "<br>", options: [.regularExpression, .caseInsensitive])
        }
        return visibleText(body)
    }

    static func decodeEntities(_ text: String) -> String {
        let named = ["&amp;": "&", "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
                     "&eacute;": "é", "&egrave;": "è", "&ecirc;": "ê", "&agrave;": "à", "&acirc;": "â", "&ccedil;": "ç",
                     "&ocirc;": "ô", "&icirc;": "î", "&ucirc;": "û", "&ugrave;": "ù", "&Eacute;": "É", "&rsquo;": "’", "&ndash;": "–", "&mdash;": "—"]
        // A single bounded pass over the original input cannot recursively unescape
        // generated entities or depend on dictionary iteration order.
        guard let regex = try? NSRegularExpression(pattern: #"&(?:#[xX][0-9A-Fa-f]{1,8}|#[0-9]{1,10}|[A-Za-z][A-Za-z0-9]{1,31});"#) else { return text }
        let source = text as NSString, out = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let entity = source.substring(with: match.range)
            var decoded = named[entity]
            if decoded == nil, entity.hasPrefix("&#") {
                let body = entity.dropFirst(2).dropLast()
                let hexadecimal = body.first == "x" || body.first == "X"
                let code = hexadecimal ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let code, let scalar = Unicode.Scalar(code) { decoded = String(scalar) }
            }
            if let decoded { out.replaceCharacters(in: match.range, with: decoded) }
        }
        return out as String
    }

    static func normalizePrintedEmail(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]*@[ \\t]*", with: "@", options: .regularExpression)
    }

    static func hrefs(_ html: String, base: URL) -> [String] {
        let raw = capturePairs(html, #"(?i:href)\s*=\s*(["'])(.+?)\1"#).map(\.1)
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
        // An explicitly printed Québec unit/building address may omit a street-type word and
        // wrap its city and postal code onto separate lines. Keep the exact text, including newlines.
        let unitAddress = #"(?im)^\d{1,5}\s*[-–]\s*\d{1,5}[ \t]+[\p{L}][^\n]{2,100}\n[\p{L} .’'\-]{2,60},?[ \t]+(?:QC|Québec|Quebec)\n[GHJ]\d[A-Z][ -]?\d[A-Z]\d\b"#
        if let range = text.range(of: unitAddress, options: .regularExpression) { return String(text[range]) }
        return nil
    }

    static let titleWords = ["président", "présidente", "president", "directeur", "directrice", "director", "propriétaire", "owner",
                             "fondateur", "fondatrice", "founder", "associé", "associée", "partner", "gestionnaire", "manager",
                             "dentiste", "médecin", "physiothérapeute", "pharmacien", "pharmacienne", "chef", "responsable", "coordonnateur",
                             "coordonnatrice", "vice-président", "vice-présidente", "ceo", "coo", "cto", "dg", "chief"]

    private static let personNamePattern = "((?:Dr\\.? |Dre |Me )?[A-ZÀ-Ý][a-zà-ÿ'’]+(?:-[A-ZÀ-Ý][a-zà-ÿ'’]+)?(?: [A-ZÀ-Ý][a-zà-ÿ'’]+(?:-[A-ZÀ-Ý][a-zà-ÿ'’]+)?){1,2})"

    /// "Prénom Nom, Titre", "Prénom Nom – Titre", "Titre : Prénom Nom" or "Dr Prénom Nom" followed by a title line.
    static func people(in text: String) -> [Person] {
        let name = personNamePattern
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

    /// Some own-site notices explicitly identify the company's privacy officer and executive title
    /// in a sentence. Require the exact researched organisation and a current executive role;
    /// do not infer that a privacy officer is an executive, or that a client belongs to this business.
    static func declaredExecutives(in text: String, organisation: String) -> [Person] {
        guard !organisation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let company = NSRegularExpression.escapedPattern(for: organisation)
        let prefix = "(?i:Le responsable de la protection des renseignements personnels chez \(company) est )"
        let pattern = "^\(prefix)\(personNamePattern)\\s*,\\s*([^.!?;\\n]{3,80})(?:\\.|$)"
        // The whole title must consist of affirmative roles, not merely contain a role word.
        // This also withholds e.g. "not CEO", "future CEO" and "CEO starting next year".
        let role = #"(?:(?:co[- ]?|vice[- ]?)?(?:président(?:e)?|president|fondateur|fondatrice|founder)|CEO|directeur général|directrice générale)"#
        let executive = "(?i)^\\s*\(role)(?:(?:\\s*[,/&-]\\s*|\\s+(?:(?:et|and)\\s+)?)\(role))*\\s*$"
        return text.components(separatedBy: .newlines).filter { $0.count <= 500 }.flatMap { line in
            capturePairs(line, pattern).compactMap { name, title in
                guard title.range(of: executive, options: .regularExpression) != nil else { return nil }
                return Person(name: clean(name), title: title.trimmingCharacters(in: .whitespaces))
            }
        }
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

    /// Trigger signals from icp.json found in a page's own body text (LIVE-R4: never nav, header, footer or link text). Job postings only count on a careers page.
    static func triggers(in page: Page, segment: ICPConfig.Segment, config: ICPConfig) -> [ProspectTrigger] {
        let path = (URL(string: page.url)?.path ?? "").lowercased()
        var out: [ProspectTrigger] = []
        for kind in segment.triggers {
            if kind == "job_posting", !["carri", "emploi", "career", "job"].contains(where: { path.contains($0) }) { continue }
            guard let phrase = config.triggerSignals[kind]?.first(where: { phraseMatches($0, in: page.bodyText) }) else { continue }
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
