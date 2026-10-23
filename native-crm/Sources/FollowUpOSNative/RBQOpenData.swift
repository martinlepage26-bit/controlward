import Foundation

/// One active RBQ licence, reduced to the fields ControlWard may use: discovery and the conflict hold by
/// licence category. Courriel, phone, Mandataire, Adresse and NEQ are never read into memory.
struct RBQLicence: Codable, Equatable, Sendable {
    var licenceNumber: String
    var name: String
    var otherNames: [String]
    var municipality: String
    var regionCode: String
    var region: String
    /// "Categorie" values seen on the licence's rows (Specialisee / Generale).
    var licenceClasses: [String] = []
    /// Sub-category codes of the whole licence ("15.5", "2.5", "GPC" ...), grouped across rows.
    var subcategories: [String]
    /// Always `RBQ / Données Québec, CC BY 4.0`.
    var provenance: String
}

/// The RBQ active-licence file from Données Québec (CC BY 4.0). Water and Earth ruled it on (Oct 23, 6:10 AM ET):
/// only the two fixed download URLs, a 10 s delay, at most one download a day, stream-parsed from a local cache.
enum RBQOpenData {
    static let sourceID = "rbq_open_data"

    struct CacheMeta: Codable, Equatable, Sendable {
        var url: String
        var fetchedAt: Date
        var bytes: Int
    }

    static func source(_ config: ICPConfig) -> ICPConfig.OpenDataSource? {
        config.allowlist.openDataSources.first { $0.id == sourceID && $0.enabled }
    }

    static func cacheFile(in directory: URL) -> URL { directory.appendingPathComponent("rbq-licences.json") }
    static func metaFile(in directory: URL) -> URL { directory.appendingPathComponent("rbq-licences.meta.json") }

    /// True when the cached copy is younger than `max_download_age_hours`.
    static func cacheIsFresh(directory: URL, source: ICPConfig.OpenDataSource, now: Date) -> Bool {
        guard FileManager.default.fileExists(atPath: cacheFile(in: directory).path),
              let data = try? Data(contentsOf: metaFile(in: directory)),
              let meta = try? JSONDecoder.iso.decode(CacheMeta.self, from: data) else { return false }
        return now.timeIntervalSince(meta.fetchedAt) < source.maxDownloadAgeHours * 3600
    }

    /// Downloads the JSON file only when the cache is older than a day. Returns the cache file.
    @discardableResult
    static func refreshCache(config: ICPConfig, transport: GuardedLeadTransport, directory: URL, now: Date) async throws -> URL {
        guard let source = source(config) else { throw LeadPipelineRefusal(code: "refused:source-disabled:\(sourceID)") }
        if cacheIsFresh(directory: directory, source: source, now: now) { return cacheFile(in: directory) }
        guard let jsonURL = source.downloadUrls.first(where: { $0.hasSuffix(".json") }).flatMap(URL.init(string:)) else {
            throw LeadPipelineRefusal(code: "refused:open-data-path")
        }
        let response = try await transport.fetch(jsonURL, purpose: .openData(id: sourceID), maxBytes: source.maxResponseBytes)
        guard (200..<300).contains(response.status) else { throw LeadPipelineRefusal(code: "error:\(response.status)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try response.body.write(to: cacheFile(in: directory), options: .atomic)
        let meta = CacheMeta(url: jsonURL.absoluteString, fetchedAt: now, bytes: response.body.count)
        try JSONEncoder.iso.encode(meta).write(to: metaFile(in: directory), options: .atomic)
        return cacheFile(in: directory)
    }

    /// Stream-parses the cached file in 1 MB chunks. The format (JSON or CSV) is read from the first byte. Rows are grouped by
    /// "Numéro de licence" before anything is emitted, so a licence's sub-categories are complete when the hold looks at them.
    /// A missing or unknown column throws refused:open-data-header; nothing is skipped silently.
    static func parse(file: URL, source: ICPConfig.OpenDataSource, chunkSize: Int = 1 << 20, each: (RBQLicence) -> Void) throws {
        try checkFieldMap(source)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var reader = RBQReader(source: source)
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { try reader.feed(chunk) }
        try reader.finish().forEach(each)
    }

    static func parse(data: Data, source: ICPConfig.OpenDataSource) throws -> [RBQLicence] {
        try checkFieldMap(source)
        var reader = RBQReader(source: source)
        try reader.feed(data)
        return try reader.finish()
    }

    /// The config may never map a role to a never-stored field (Courriel, phone, Mandataire ...).
    static func checkFieldMap(_ source: ICPConfig.OpenDataSource) throws {
        let forbidden = Set(source.neverStoredFields.map { $0.lowercased() })
        if source.fields.contains(where: { forbidden.contains($0.label.lowercased()) }) {
            throw LeadPipelineRefusal(code: "refused:open-data-config", detail: "a never-stored field is mapped")
        }
    }

    /// Roles every CSV header row must carry (one row per licence x sub-category).
    static let csvRoles = ["licence_number", "name", "other_names", "municipality", "region_code", "region", "category", "subcategory"]
    /// Roles every JSON licence record must carry (sub-categories nested in `subcategory_list`).
    static let jsonRoles = ["licence_number", "name", "other_names", "municipality", "region_code", "region", "subcategory_list"]

    static func headerRefusal(_ present: [String], roles: [String], source: ICPConfig.OpenDataSource, extraKnown: [String] = []) -> LeadPipelineRefusal? {
        var missing: [String] = []
        for role in roles {
            guard let label = source.label(role) else { missing.append("<no label for \(role)>"); continue }
            if !present.contains(label) { missing.append(label) }
        }
        var unknown: [String] = []
        if let known = source.knownHeaders {
            let allowed = Set(known + extraKnown)
            unknown = present.filter { !allowed.contains($0) }
        }
        guard !missing.isEmpty || !unknown.isEmpty else { return nil }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing column(s): " + missing.joined(separator: ", ")) }
        if !unknown.isEmpty { parts.append("unknown column(s): " + unknown.joined(separator: ", ")) }
        return LeadPipelineRefusal(code: "refused:open-data-header", detail: parts.joined(separator: "; "))
    }

    /// Sub-category codes compare trimmed and upper-cased, with a trailing ".0" dropped (RBQ's list writes "16.0", the file "16").
    static func normalizeCode(_ code: String) -> String {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasSuffix(".0") { value.removeLast(2) }
        return value
    }

    static func stringValue(_ raw: Any?) -> String {
        guard let raw else { return "" }
        return stringValue(raw)
    }

    static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { ";|\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func stringValue(_ raw: Any) -> String {
        switch raw {
        case is NSNull: return ""
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map(stringValue).joined(separator: "; ")
        case let object as [String: Any]: return object.values.map(stringValue).joined(separator: " ")
        default: return ""
        }
    }

    /// Name key used to match an RBQ licence to a business found by discovery.
    static func nameKey(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CA")).lowercased()
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let noise: Set<String> = ["inc", "ltee", "ltd", "enr", "senc", "s", "e", "n", "c", "the", "les", "le", "la"]
        return words.filter { !noise.contains($0) }.joined(separator: " ")
    }
}

/// Index of licences by name key, for matching discovery candidates (by name and municipality only).
struct RBQIndex: Sendable {
    private var byName: [String: [RBQLicence]] = [:]
    private(set) var count = 0

    init(_ licences: [RBQLicence] = []) { licences.forEach { add($0) } }

    mutating func add(_ licence: RBQLicence) {
        count += 1
        for name in [licence.name] + licence.otherNames {
            let key = RBQOpenData.nameKey(name)
            if !key.isEmpty { byName[key, default: []].append(licence) }
        }
    }

    func match(name: String, municipality: String?) -> RBQLicence? {
        let candidates = byName[RBQOpenData.nameKey(name)] ?? []
        if let municipality, !municipality.isEmpty {
            let town = RBQOpenData.nameKey(municipality)
            if let hit = candidates.first(where: { RBQOpenData.nameKey($0.municipality) == town }) { return hit }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Adds licence categories and the attribution to a prospect. Never touches contact, route, address or person.
    func enrich(_ prospect: inout ProspectRecord, municipality: String?, source: ICPConfig.OpenDataSource) {
        guard let licence = match(name: prospect.organisation, municipality: municipality) else { return }
        prospect.rbqCategories = licence.subcategories
        prospect.dataAttribution = source.attribution
    }
}

/// Splits a JSON document into the objects of its first array, without loading the whole file.
struct JSONRecordSplitter {
    private var depth = 0
    private var recordDepth: Int?
    private var inString = false
    private var escaped = false
    private var capturing = false
    private var buffer = Data()
    private var stack: [UInt8] = []

    mutating func feed(_ chunk: Data, emit: (Data) -> Void) {
        for byte in chunk {
            if capturing { buffer.append(byte) }
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B: // [
                stack.append(byte)
                if recordDepth == nil { recordDepth = stack.count }
            case 0x7B: // {
                if !capturing, let recordDepth, stack.count == recordDepth, stack.last == 0x5B {
                    capturing = true
                    buffer = Data([byte])
                }
                stack.append(byte)
            case 0x5D, 0x7D: // ] }
                if !stack.isEmpty { stack.removeLast() }
                if capturing, byte == 0x7D, let recordDepth, stack.count == recordDepth {
                    capturing = false
                    emit(buffer)
                    buffer = Data()
                }
            default: break
            }
        }
    }
}

/// Collects rows into one licence per "Numéro de licence", keeping first-seen order.
struct RBQGrouper {
    private var order: [String] = []
    private var byNumber: [String: RBQLicence] = [:]
    var count: Int { order.count }

    mutating func add(number: String, name: String, otherNames: [String], municipality: String, regionCode: String, region: String,
                      classes: [String], codes: [String], provenance: String) {
        guard var licence = byNumber[number] else {
            order.append(number)
            byNumber[number] = RBQLicence(licenceNumber: number, name: name, otherNames: Self.unique(otherNames), municipality: municipality,
                                          regionCode: regionCode, region: region, licenceClasses: Self.unique(classes),
                                          subcategories: Self.unique(codes), provenance: provenance)
            return
        }
        if licence.name.isEmpty { licence.name = name }
        if licence.municipality.isEmpty { licence.municipality = municipality }
        if licence.regionCode.isEmpty { licence.regionCode = regionCode }
        if licence.region.isEmpty { licence.region = region }
        licence.otherNames = Self.unique(licence.otherNames + otherNames)
        licence.licenceClasses = Self.unique(licence.licenceClasses + classes)
        licence.subcategories = Self.unique(licence.subcategories + codes)
        byNumber[number] = licence
    }

    func licences() -> [RBQLicence] { order.compactMap { byNumber[$0] } }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Reads the RBQ file in either real shape and feeds the grouper. Fails loudly on a header it does not recognise.
struct RBQReader {
    private enum Format { case undecided, json, csv }
    let source: ICPConfig.OpenDataSource
    private var format = Format.undecided
    private var lead = Data()
    private var json = JSONRecordSplitter()
    private var csv = CSVRowSplitter()
    private var columns: [String: Int]?
    private var headerWidth = 0
    private var rows = 0
    private var error: LeadPipelineRefusal?
    private var grouper = RBQGrouper()

    init(source: ICPConfig.OpenDataSource) { self.source = source }

    mutating func feed(_ chunk: Data) throws {
        if let error { throw error }
        if format == .undecided {
            lead.append(chunk)
            guard let first = lead.first(where: { !Self.skippable($0) }) else { return }
            format = (first == 0x7B || first == 0x5B) ? .json : .csv
            let pending = lead
            lead = Data()
            try consume(pending)
        } else {
            try consume(chunk)
        }
    }

    mutating func finish() throws -> [RBQLicence] {
        if let error { throw error }
        if format == .csv {
            var tail: [[String]] = []
            csv.finish { tail.append($0) }
            for row in tail { try csvRow(row) }
        }
        guard grouper.count > 0 else {
            throw LeadPipelineRefusal(code: "refused:open-data-header", detail: format == .undecided ? "empty file" : "no licence records found")
        }
        return grouper.licences()
    }

    private static func skippable(_ byte: UInt8) -> Bool { byte == 0xEF || byte == 0xBB || byte == 0xBF || byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    private mutating func consume(_ chunk: Data) throws {
        switch format {
        case .json:
            var records: [Data] = []
            json.feed(chunk) { records.append($0) }
            for record in records { try jsonRecord(record) }
        case .csv:
            var batch: [[String]] = []
            csv.feed(chunk) { batch.append($0) }
            for row in batch { try csvRow(row) }
        case .undecided: break
        }
    }

    private mutating func fail(_ refusal: LeadPipelineRefusal) -> LeadPipelineRefusal { error = refusal; return refusal }

    private mutating func csvRow(_ row: [String]) throws {
        if row.count == 1 && row[0].isEmpty { return }
        guard let columns else {
            if let refusal = RBQOpenData.headerRefusal(row, roles: RBQOpenData.csvRoles, source: source) { throw fail(refusal) }
            var map: [String: Int] = [:]
            for (index, label) in row.enumerated() where map[label] == nil { map[label] = index }
            self.columns = map
            headerWidth = row.count
            return
        }
        rows += 1
        guard row.count == headerWidth else {
            throw fail(LeadPipelineRefusal(code: "refused:open-data-row", detail: "row \(rows) has \(row.count) columns, header has \(headerWidth)"))
        }
        func value(_ role: String) -> String {
            guard let label = source.label(role), let index = columns[label] else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try add(number: value("licence_number"), name: value("name"), otherNames: RBQOpenData.splitList(value("other_names")),
                municipality: value("municipality"), regionCode: value("region_code"), region: value("region"),
                classes: [value("category")], codes: [value("subcategory")])
    }

    private mutating func jsonRecord(_ object: Data) throws {
        rows += 1
        guard let outer = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any] else {
            throw fail(LeadPipelineRefusal(code: "refused:open-data-header", detail: "record \(rows) is not a JSON object"))
        }
        let wrapper = source.label("json_record")
        guard let record = wrapper.map({ outer[$0] as? [String: Any] }) ?? outer else {
            throw fail(LeadPipelineRefusal(code: "refused:open-data-header",
                                           detail: "record \(rows) is not {\"\(wrapper ?? "")\":{...}}; keys: \(outer.keys.sorted().joined(separator: ", "))"))
        }
        if let refusal = RBQOpenData.headerRefusal(Array(record.keys), roles: RBQOpenData.jsonRoles, source: source) { throw fail(refusal) }
        func value(_ role: String) -> String { source.label(role).map { RBQOpenData.stringValue(record[$0]) } ?? "" }
        var classes: [String] = [], codes: [String] = []
        let categoryLabel = source.label("category") ?? "", codeLabel = source.label("subcategory") ?? ""
        if let listLabel = source.label("subcategory_list"), let raw = record[listLabel], !(raw is NSNull) {
            guard let items = raw as? [Any] else {
                throw fail(LeadPipelineRefusal(code: "refused:open-data-header", detail: "'\(listLabel)' is not a list in record \(rows)"))
            }
            for item in items {
                guard let entry = item as? [String: Any] else {
                    throw fail(LeadPipelineRefusal(code: "refused:open-data-header", detail: "'\(listLabel)' entry is not an object in record \(rows)"))
                }
                let unknown = entry.keys.filter { $0 != categoryLabel && $0 != codeLabel }
                guard entry[codeLabel] != nil, unknown.isEmpty else {
                    let detail = entry[codeLabel] == nil ? "missing column(s): \(codeLabel)" : "unknown column(s): \(unknown.sorted().joined(separator: ", "))"
                    throw fail(LeadPipelineRefusal(code: "refused:open-data-header", detail: "\(detail) in '\(listLabel)', record \(rows)"))
                }
                classes.append(RBQOpenData.stringValue(entry[categoryLabel]))
                codes.append(RBQOpenData.stringValue(entry[codeLabel]))
            }
        }
        let otherNames: [String]
        if let label = source.label("other_names"), let list = record[label] as? [Any] {
            otherNames = list.map { RBQOpenData.stringValue($0) }
        } else {
            otherNames = RBQOpenData.splitList(value("other_names"))
        }
        try add(number: value("licence_number"), name: value("name"), otherNames: otherNames, municipality: value("municipality"),
                regionCode: value("region_code"), region: value("region"), classes: classes, codes: codes)
    }

    private mutating func add(number: String, name: String, otherNames: [String], municipality: String, regionCode: String, region: String,
                              classes: [String], codes: [String]) throws {
        guard !number.isEmpty else {
            throw fail(LeadPipelineRefusal(code: "refused:open-data-row", detail: "row \(rows) has no licence number"))
        }
        grouper.add(number: number, name: name, otherNames: otherNames, municipality: municipality, regionCode: regionCode, region: region,
                    classes: classes, codes: codes, provenance: source.label)
    }
}

/// Splits RFC 4180 CSV (quoted fields, doubled quotes, commas and newlines inside quotes, CRLF or LF) into rows, streaming.
struct CSVRowSplitter {
    private var field = Data()
    private var row: [String] = []
    private var inQuotes = false
    private var quotePending = false
    private var firstRow = true

    mutating func feed(_ chunk: Data, emit: ([String]) -> Void) {
        for byte in chunk {
            if inQuotes {
                if quotePending {
                    quotePending = false
                    if byte == 0x22 { field.append(0x22); continue }
                    inQuotes = false
                } else if byte == 0x22 {
                    quotePending = true
                    continue
                } else {
                    field.append(byte)
                    continue
                }
            }
            switch byte {
            case 0x22 where field.isEmpty: inQuotes = true
            case 0x2C: endField()
            case 0x0A: endField(); emitRow(emit)
            case 0x0D: break
            default: field.append(byte)
            }
        }
    }

    mutating func finish(emit: ([String]) -> Void) {
        if quotePending { quotePending = false; inQuotes = false }
        if !field.isEmpty || !row.isEmpty { endField(); emitRow(emit) }
    }

    private mutating func endField() {
        var text = String(decoding: field, as: UTF8.self)
        if firstRow && row.isEmpty && text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        row.append(text)
        field = Data()
    }

    private mutating func emitRow(_ emit: ([String]) -> Void) {
        emit(row)
        row = []
        firstRow = false
    }
}
