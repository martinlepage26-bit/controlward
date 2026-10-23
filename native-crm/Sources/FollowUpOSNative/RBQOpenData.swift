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
    /// "Categorie" values on the licence (Specialisee / Generale).
    var licenceClasses: [String] = []
    /// Sub-category codes of the licence ("15.5", "2.5", "GPC" ...). The JSON file has one record per licence.
    var subcategories: [String]
    /// Always `RBQ / Données Québec, CC BY 4.0`.
    var provenance: String
}

/// The RBQ active-licence file from Données Québec (CC BY 4.0). Water and Earth ruled it on (Oct 23, 6:10 AM ET):
/// only the one fixed JSON download URL (Water, 6:55 AM ET: JSON only), a 10 s delay, at most one download a day, stream-parsed from a local cache.
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

    /// Stream-parses the cached JSON file in 1 MB chunks, emitting one licence per record. Anything that is not the real
    /// shape {"Liste Licence":[{"Licence":{...}}]} (a CSV, a missing, renamed or unknown key, a flat or truncated record, an
    /// empty file) throws refused:open-data-schema. Nothing is skipped silently; the caller holds construction trades instead.
    static func parse(file: URL, source: ICPConfig.OpenDataSource, chunkSize: Int = 1 << 20, each: (RBQLicence) -> Void) throws {
        try checkFieldMap(source)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var reader = try RBQReader(source: source)
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { try reader.feed(chunk, each: each) }
        try reader.finish()
    }

    static func parse(data: Data, source: ICPConfig.OpenDataSource) throws -> [RBQLicence] {
        try checkFieldMap(source)
        var reader = try RBQReader(source: source)
        var licences: [RBQLicence] = []
        try reader.feed(data) { licences.append($0) }
        try reader.finish()
        return licences
    }

    /// The config may never map a role to a never-stored field (Courriel, phone, Mandataire ...).
    static func checkFieldMap(_ source: ICPConfig.OpenDataSource) throws {
        let forbidden = Set(source.neverStoredFields.map { $0.lowercased() })
        if source.fields.contains(where: { forbidden.contains($0.label.lowercased()) }) {
            throw LeadPipelineRefusal(code: "refused:open-data-config", detail: "a never-stored field is mapped")
        }
    }

    static let schemaCode = "refused:open-data-schema"
    static func schema(_ detail: String) -> LeadPipelineRefusal { LeadPipelineRefusal(code: schemaCode, detail: detail) }

    /// Roles every JSON licence record must carry (sub-categories nested in `subcategory_list`), plus the wrapper and nested keys.
    static let jsonRoles = ["licence_number", "name", "other_names", "municipality", "region_code", "region", "subcategory_list"]
    static let requiredLabels = jsonRoles + ["json_record", "category", "subcategory"]

    static func keyRefusal(_ present: [String], source: ICPConfig.OpenDataSource) -> LeadPipelineRefusal? {
        let missing = jsonRoles.compactMap { source.label($0) }.filter { !present.contains($0) }
        let unknown = source.knownHeaders.map { known in present.filter { !known.contains($0) } } ?? []
        guard !missing.isEmpty || !unknown.isEmpty else { return nil }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing key(s): " + missing.joined(separator: ", ")) }
        if !unknown.isEmpty { parts.append("unknown key(s): " + unknown.sorted().joined(separator: ", ")) }
        return schema(parts.joined(separator: "; "))
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
        guard let licence = match(name: prospect.organisation, municipality: municipality) else {
            prospect.rbqCheck = "no-match"
            return
        }
        prospect.rbqCheck = "matched"
        prospect.rbqCategories = licence.subcategories
        // The licence's own Municipalité decides the area hold; the map/own-site town only fills a blank one.
        let town = licence.municipality.trimmingCharacters(in: .whitespacesAndNewlines)
        prospect.rbqMunicipality = town.isEmpty ? municipality : town
        prospect.dataAttribution = source.attribution
    }
}

/// Splits a JSON document into the objects of its first array, without loading the whole file.
struct JSONRecordSplitter {
    private var recordDepth: Int?
    private var inString = false
    private var escaped = false
    private var capturing = false
    private var buffer = Data()
    private var stack: [UInt8] = []
    private var closed = false

    /// True once the document's brackets balance and no record or string is left open.
    var isComplete: Bool { closed && stack.isEmpty && !capturing && !inString }

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
                if stack.isEmpty { closed = true }
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

/// Reads the RBQ JSON file, one licence per record. Throws refused:open-data-schema on anything else.
struct RBQReader {
    let source: ICPConfig.OpenDataSource
    private let wrapper: String, listLabel: String, categoryLabel: String, codeLabel: String
    private let nestedKeys: Set<String>
    private var started = false
    private var json = JSONRecordSplitter()
    private var records = 0
    private var error: LeadPipelineRefusal?

    init(source: ICPConfig.OpenDataSource) throws {
        self.source = source
        let missing = RBQOpenData.requiredLabels.filter { source.label($0) == nil }
        guard missing.isEmpty else { throw RBQOpenData.schema("no label for: " + missing.joined(separator: ", ")) }
        wrapper = source.label("json_record")!
        listLabel = source.label("subcategory_list")!
        categoryLabel = source.label("category")!
        codeLabel = source.label("subcategory")!
        nestedKeys = Set(source.knownSubcategoryKeys ?? [categoryLabel, codeLabel])
    }

    mutating func feed(_ chunk: Data, each: (RBQLicence) -> Void) throws {
        if let error { throw error }
        var bytes = chunk[...]
        if !started {
            guard let first = bytes.firstIndex(where: { !Self.skippable($0) }) else { return }
            guard bytes[first] == 0x7B || bytes[first] == 0x5B else { throw fail(RBQOpenData.schema("not a JSON file (a CSV or other format)")) }
            started = true
            bytes = bytes[first...]
        }
        var objects: [Data] = []
        json.feed(Data(bytes)) { objects.append($0) }
        for object in objects { each(try licence(object)) }
    }

    mutating func finish() throws {
        if let error { throw error }
        guard started else { throw fail(RBQOpenData.schema("empty file")) }
        guard json.isComplete else { throw fail(RBQOpenData.schema("truncated file after \(records) record(s)")) }
        guard records > 0 else { throw fail(RBQOpenData.schema("no licence records found")) }
    }

    private static func skippable(_ byte: UInt8) -> Bool { byte == 0xEF || byte == 0xBB || byte == 0xBF || byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    private mutating func fail(_ refusal: LeadPipelineRefusal) -> LeadPipelineRefusal { error = refusal; return refusal }

    private mutating func licence(_ object: Data) throws -> RBQLicence {
        records += 1
        guard let outer = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any] else {
            throw fail(RBQOpenData.schema("record \(records) is not a JSON object"))
        }
        guard outer.count == 1, let record = outer[wrapper] as? [String: Any] else {
            throw fail(RBQOpenData.schema("record \(records) is not {\"\(wrapper)\":{...}}; keys: \(outer.keys.sorted().joined(separator: ", "))"))
        }
        if let refusal = RBQOpenData.keyRefusal(Array(record.keys), source: source) { throw fail(refusal) }
        func value(_ role: String) -> String { source.label(role).map { RBQOpenData.stringValue(record[$0]) } ?? "" }
        var classes: [String] = [], codes: [String] = []
        if let raw = record[listLabel], !(raw is NSNull) {
            guard let items = raw as? [Any] else { throw fail(RBQOpenData.schema("'\(listLabel)' is not a list in record \(records)")) }
            for item in items {
                guard let entry = item as? [String: Any] else { throw fail(RBQOpenData.schema("'\(listLabel)' entry is not an object in record \(records)")) }
                let unknown = entry.keys.filter { !nestedKeys.contains($0) }
                guard entry[codeLabel] != nil, unknown.isEmpty else {
                    let detail = entry[codeLabel] == nil ? "missing key(s): \(codeLabel)" : "unknown key(s): \(unknown.sorted().joined(separator: ", "))"
                    throw fail(RBQOpenData.schema("\(detail) in '\(listLabel)', record \(records)"))
                }
                classes.append(RBQOpenData.stringValue(entry[categoryLabel]))
                codes.append(RBQOpenData.stringValue(entry[codeLabel]))
            }
        }
        let otherNames: [String]
        if let label = source.label("other_names"), let list = record[label] as? [Any] {
            otherNames = list.map { RBQOpenData.stringValue($0) }
        } else {
            otherNames = value("other_names").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let number = value("licence_number")
        guard !number.isEmpty else { throw fail(RBQOpenData.schema("record \(records) has no licence number")) }
        return RBQLicence(licenceNumber: number, name: value("name"), otherNames: Self.unique(otherNames), municipality: value("municipality"),
                          regionCode: value("region_code"), region: value("region"), licenceClasses: Self.unique(classes),
                          subcategories: Self.unique(codes), provenance: source.label)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
