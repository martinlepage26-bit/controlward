import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// bin/prove-rbq-hold <rbq-licences.json>: loads a real RBQ JSON file through the same parser and config the app uses and
// prints aggregate counts only: licences read, licences the conflict hold catches (by configured municipality and with no
// location), and the count per held code. It never prints a firm name, licence number or any town other than the configured
// ones, writes nothing and makes no network request.
// If the file is not the real JSON shape the parser refuses it (refused:open-data-schema) and the app keeps the
// fail-closed SOS hold where it still applies; this tool then exits 2 and says so.

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard let configIndex = args.firstIndex(of: "--config"), configIndex + 1 < args.count else { fail("missing --config <Resources/config directory>") }
let files = args.dropFirst().enumerated().filter { $0.offset != configIndex - 1 && $0.offset != configIndex }.map(\.element)
guard !files.isEmpty else { fail("usage: bin/prove-rbq-hold <path to the RBQ JSON file>") }

let config: ICPConfig
do { config = try ICPConfig.load(directory: URL(fileURLWithPath: args[configIndex + 1])) } catch { fail("config: \(error)") }
guard let source = RBQOpenData.source(config) else { fail("rbq_open_data is not enabled in icp.json") }
guard let area = config.conflictAreas.first(where: { $0.rbqSubcategoryCodes != nil }), let listed = area.rbqSubcategoryCodes else {
    fail("no conflict area lists RBQ sub-category codes")
}
let wanted = listed.map(RBQOpenData.normalizeCode)
let places = area.municipalities ?? []
print("RBQ hold proof: area \(area.id), held codes \(wanted.joined(separator: ", ")), municipalities \(places.isEmpty ? "(all of \(area.region))" : places.joined(separator: ", ")) (whole normalised Municipalité; blank = held), fail-closed segments \((area.rbqRequiredSegments ?? []).joined(separator: ", "))")

var status: Int32 = 0
for path in files {
    let url = URL(fileURLWithPath: path)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
    var licences = 0, held = 0, overlap = 0
    var perCode: [String: Int] = [:], carrying: [String: Int] = [:]
    var perPlace: [String: Int] = [:], noLocation = 0
    // Diagnostics only (never part of the hold): code-qualifying licences whose town merely contains a configured name.
    var substringOnly = 0, codeQualifying = 0
    do {
        try RBQOpenData.parse(file: url, source: source) { licence in
            licences += 1
            let codes = Set(licence.subcategories.map(RBQOpenData.normalizeCode))
            for code in wanted where codes.contains(code) { carrying[code, default: 0] += 1 }
            // The same predicate the app uses (LeadDefinition.rbqHeldCodes), so these counts are what the app holds.
            let anywhere = LeadDefinition.rbqHeldCodes(licence.subcategories, area: area)
            if !anywhere.isEmpty {
                codeQualifying += 1
                let town = LeadDefinition.placeKey(licence.municipality)
                if case .outside = LeadDefinition.rbqAreaMatch(licence.municipality, area: area),
                   places.contains(where: { town.contains(LeadDefinition.placeKey($0)) }) { substringOnly += 1 }
            }
            let holding = LeadDefinition.rbqHeldCodes(licence.subcategories, area: area, municipality: licence.municipality)
            if !holding.isEmpty {
                held += 1
                switch LeadDefinition.rbqAreaMatch(licence.municipality, area: area) {
                case .inside(let place): perPlace[place, default: 0] += 1
                case .unknown: noLocation += 1
                case .outside: break
                }
            }
            if holding.count > 1 { overlap += 1 }
            for code in holding { perCode[code, default: 0] += 1 }
        }
        let share = licences > 0 ? Double(held) * 100 / Double(licences) : 0
        print("\(url.lastPathComponent) (\(bytes) bytes): licences=\(licences) held=\(held) (\(String(format: "%.1f", share))%)")
        let inArea = perPlace.values.reduce(0, +)
        print("  held in the municipalities: \(inArea) (\(places.map { "\($0) \(perPlace[$0, default: 0])" }.joined(separator: ", ")))")
        print("  held with no location (blank Municipalité): \(noLocation)")
        print("  held total: \(inArea) + \(noLocation) = \(inArea + noLocation) (held=\(held))")
        print("  licences with a held code anywhere in the province: \(codeQualifying); outside whose town contains a configured name (not held, substring check): \(substringOnly)")
        for condition in area.rbqCodeConditions ?? [] {
            print("  rule for \(RBQOpenData.normalizeCode(condition.code)): not held with all of [\(condition.notHeldIfAllOf.joined(separator: ", "))] or any code starting with [\(condition.notHeldIfAnyCodeStartsWith.joined(separator: ", "))]")
        }
        for code in wanted { print("  code \(code): carried by \(carrying[code, default: 0]), held on it \(perCode[code, default: 0]) licence(s)") }
        print("  held on more than one code (overlap): \(overlap)")
        print("  check: \(wanted.map { String(perCode[$0, default: 0]) }.joined(separator: " + ")) - \(overlap) = \(wanted.reduce(0) { $0 + perCode[$1, default: 0] } - overlap) (held=\(held))")
        print("  not held: \(licences - held)")
    } catch let refusal as LeadPipelineRefusal {
        print("\(url.lastPathComponent) (\(bytes) bytes): \(refusal.code) (\(refusal.detail.isEmpty ? "-" : refusal.detail)): the app keeps the fail-closed SOS hold where it still applies (plumbing or excavation in the listed municipalities, or a firm whose town cannot be read)")
        status = 2
    } catch {
        print("\(url.lastPathComponent): unreadable (\(error.localizedDescription)): the app keeps the fail-closed SOS hold where it still applies (plumbing or excavation in the listed municipalities, or a firm whose town cannot be read)")
        status = 2
    }
}
exit(status)
