import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One item from a SEAO or MERX feed, a newsroom or a careers page.
struct WatchItem: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var link: String
    var organisation: String?
    var publishedAt: Date?
    var deadline: Date?
    var status: String
}

/// Compares what a watched page or feed says now with what was stored, and decides the trigger state.
enum TenderWatcher {
    /// live = unchanged, changed = deadline or status moved, gone = awarded, cancelled or no longer listed.
    static func state(previous: WatchItem?, current: WatchItem?) -> TriggerState {
        guard let current else { return .gone }
        let status = current.status.lowercased()
        if ["awarded", "adjugé", "adjugée", "octroyé", "cancelled", "annulé", "closed", "fermé"].contains(where: { status.contains($0) }) { return .gone }
        guard let previous else { return .live }
        if previous.deadline != current.deadline || previous.status.lowercased() != status { return .changed }
        return .live
    }

    /// An organisation with an open tender is blocked from outreach (S3-R14).
    static func openTender(for organisation: String, in items: [WatchItem], now: Date) -> WatchItem? {
        let key = RBQOpenData.nameKey(organisation)
        return items.first { item in
            guard let org = item.organisation, RBQOpenData.nameKey(org) == key else { return false }
            return state(previous: nil, current: item) != .gone && (item.deadline.map { $0 > now } ?? true)
        }
    }

    /// RSS 2.0 or Atom. Deadlines are read from a `deadline`/`closingDate` element when the feed provides one.
    static func parseFeed(_ data: Data) -> [WatchItem] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        var items: [WatchItem] = []
        private var current: [String: String]?
        private var text = ""
        private var atomLink: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = name.lowercased()
            if element == "item" || element == "entry" { current = [:]; atomLink = nil }
            if element == "link", current != nil, let href = attributes["href"] { atomLink = href }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.lowercased()
            if element == "item" || element == "entry" {
                if let fields = current { items.append(Self.item(fields, link: atomLink)) }
                current = nil
                return
            }
            if current != nil {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, current?[element] == nil { current?[element] = value }
            }
        }

        static func item(_ fields: [String: String], link: String?) -> WatchItem {
            let url = fields["link"] ?? link ?? ""
            return WatchItem(id: fields["guid"] ?? fields["id"] ?? url, title: fields["title"] ?? "", link: url,
                             organisation: fields["organisation"] ?? fields["organization"] ?? fields["author"] ?? fields["dc:creator"],
                             publishedAt: date(fields["pubdate"] ?? fields["published"] ?? fields["updated"]),
                             deadline: date(fields["deadline"] ?? fields["closingdate"] ?? fields["datefermeture"]),
                             status: fields["status"] ?? fields["statut"] ?? "open")
        }

        static func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            if let iso = ISO8601DateFormatter().date(from: text) { return iso }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss"] {
                formatter.dateFormat = format
                formatter.timeZone = TimeZone(identifier: format == "yyyy-MM-dd" ? "America/Toronto" : "UTC")
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }
}
