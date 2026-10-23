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

    /// Stream-parses the cached file in 1 MB chunks; only one record is held at a time.
    static func parse(file: URL, source: ICPConfig.OpenDataSource, chunkSize: Int = 1 << 20, each: (RBQLicence) -> Void) throws {
        try checkFieldMap(source)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var splitter = JSONRecordSplitter()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            splitter.feed(chunk) { if let licence = licence(from: $0, source: source) { each(licence) } }
        }
    }

    static func parse(data: Data, source: ICPConfig.OpenDataSource) throws -> [RBQLicence] {
        try checkFieldMap(source)
        var splitter = JSONRecordSplitter()
        var out: [RBQLicence] = []
        splitter.feed(data) { if let licence = licence(from: $0, source: source) { out.append(licence) } }
        return out
    }

    /// The config may never map a role to a never-stored field (Courriel, phone, Mandataire ...).
    static func checkFieldMap(_ source: ICPConfig.OpenDataSource) throws {
        let forbidden = Set(source.neverStoredFields.map { $0.lowercased() })
        if source.fields.contains(where: { forbidden.contains($0.label.lowercased()) }) {
            throw LeadPipelineRefusal(code: "refused:open-data-config", detail: "a never-stored field is mapped")
        }
    }

    static func licence(from object: Data, source: ICPConfig.OpenDataSource) -> RBQLicence? {
        guard let dictionary = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any] else { return nil }
        func value(_ role: String) -> String {
            guard let label = source.label(role), let raw = dictionary[label] else { return "" }
            return stringValue(raw)
        }
        func list(_ role: String) -> [String] {
            guard let label = source.label(role), let raw = dictionary[label] else { return [] }
            if let array = raw as? [Any] { return array.map(stringValue).filter { !$0.isEmpty } }
            return stringValue(raw).split(whereSeparator: { ";|\n".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let name = value("name")
        guard !name.isEmpty else { return nil }
        return RBQLicence(licenceNumber: value("licence_number"), name: name, otherNames: list("other_names"),
                          municipality: value("municipality"), regionCode: value("region_code"), region: value("region"),
                          subcategories: list("subcategory_list"), provenance: source.label)
    }

    private static func stringValue(_ raw: Any) -> String {
        switch raw {
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
