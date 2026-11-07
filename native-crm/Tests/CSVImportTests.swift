import Foundation

/// CSV import against the file shapes real spreadsheet tools export: CRLF line
/// endings, French-locale semicolons, byte-order marks, legacy encodings, and
/// French-formatted amounts.
@MainActor
enum CSVImportTests {
    static func run() -> Bool {
        let tests: [(String, () throws -> Void)] = [
            ("CSV: CRLF line endings split rows", crlfRows),
            ("CSV: bare CR line endings split rows", crRows),
            ("CSV: quoted fields keep embedded CRLF and quotes", quotedCRLF),
            ("CSV: semicolon delimiter is detected", semicolonRows),
            ("CSV: tab delimiter is detected", tabRows),
            ("CSV: Excel sep= hint line sets the delimiter", separatorHint),
            ("CSV: commas inside quotes do not outvote semicolons", quotedCommasInSemicolonHeader),
            ("CSV: leading byte-order mark is dropped", bomDropped),
            ("CSV: leading blank lines do not hide the delimiter", leadingBlankLines),
            ("CSV: sep= hint after a blank line is honoured", separatorHintAfterBlankLine),
            ("CSV: a stray comma in the header does not outvote tabs", tabHeaderWithComma),
            ("CSV: French decimals do not outvote semicolons", semicolonWithDecimalCommas),
            ("CSV: amounts in English and French formats", amounts),
            ("CSV: Excel CRLF export imports leads", crlfImport),
            ("CSV: French-locale export imports leads and amounts", frenchImport),
            ("CSV: UTF-16 export imports", utf16Import),
            ("CSV: Windows-1252 export imports accents", windows1252Import),
            ("CSV: Windows-1252 punctuation and ligatures import", windows1252Punctuation),
            ("CSV: Windows-1252 extended letters import", windows1252ExtendedLetters),
            ("CSV: every defined Windows-1252 C1 character decodes", windows1252DefinedCharacters),
            ("CSV: undefined Windows-1252 bytes are rejected", windows1252UndefinedBytes),
            ("CSV: UTF-16 without a byte-order mark imports", bareUTF16Import),
            ("CSV: binary file is rejected as unsupported text", binaryRejected),
            ("CSV: UTF-8 with a corrupt byte is rejected, not garbled", corruptUTF8Rejected),
            ("CSV: Mac Roman with undefined Windows-1252 bytes is rejected", macRomanRejected),
            ("CSV: header-only file reports nothing imported", headerOnlyNotice),
            ("CSV: unrecognized headers say so", unknownHeadersNotice),
            ("CSV: Lantern CRLF export with BOM imports", baeaCRLFWithBOM),
            ("CSV: empty Lantern file reports nothing imported", baeaEmptyNotice),
            ("Lantern: failed CSV save publishes nothing and retry survives reload", baeaCSVSaveFailure),
            ("Lantern: failed workbook save publishes nothing and retry survives reload", baeaWorkbookSaveFailure),
            ("Lantern: reimport preserves reviewed identity and CRM context", baeaReimportContext),
            ("Lantern: invalid language, score or sample rejects the whole file", baeaInvalidRows),
            ("Lantern: ambiguous existing audit name rejects the whole file", baeaAmbiguousName),
            ("Lantern: canonical workbook preserves scaled scores and transcript evidence", baeaCanonicalEvidence),
            ("Lantern: invalid canonical scores never become zero scores", baeaCanonicalInvalid),
            ("Lantern: unfilled canonical template imports no scored evidence", baeaCanonicalTemplate),
            ("Lantern rollup: CSV scores use sample weights and ignore row order", baeaWeightedScores),
            ("Lantern rollup: large valid weights keep the boundary score valid", baeaWeightedBoundary),
            ("Lantern rollup: canonical transcripts contribute equally", baeaCanonicalMean),
            ("Lantern rollup: fractional scores retain their precision", baeaFractionalScores),
            ("Lantern rollup: a missing language stays unscored with no task", baeaMissingLanguage),
            ("Lantern rollup: partial score columns stay unscored", baeaIncompleteScores),
            ("Lantern rollup: zero-sample rows do not affect the mean", baeaZeroWeight),
            ("Lantern rollup: averages and automation exclude unscored audits", baeaComparableAverage),
            ("Lantern rollup: genuine measured zero remains scored", baeaMeasuredZero),
            ("Lantern rollup: an owner can mark an assessment incomplete", baeaOwnerIncomplete),
            ("Lantern rollup: legacy integer scores and absent metadata still decode", baeaLegacyScores),
            ("Lantern rollup: legacy multi-row evidence awaits source weights or review", baeaLegacyMultirow),
            ("CSV-1: organisation headers (EN/FR) fill company; first non-empty wins and is named", csv1OrganisationHeaders),
            ("CSV-2: nameless rows are skipped with their row numbers, not dropped", csv2NamelessRows),
            ("CSV-3: unrecognised columns are named in the result", csv3IgnoredColumns),
            ("CSV-4: unreadable amount or date warns with row, column and raw value; ambiguous dates never guessed", csv4Values),
            ("CSV-5: the import result stays until closed (no 2.6 s notice)", csv5PersistentResult),
            ("CSV-6: a failed save is a failed import and keeps none of the file's leads", csv6SaveFailure),
            ("CSV-7: placeholder and role names go to review, not into the pipeline", csv7PlaceholderNames),
            ("CSV-8: the same file twice imports nothing the second time; existing leads are flagged duplicate-lead", csv8Reimport),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("CSV import tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    private static func freshStore() throws -> (AppStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AppStore(storageURL: directory.appendingPathComponent("data/workspace.json"), secrets: InMemorySecretStore()), directory)
    }

    private static func file(_ name: String, _ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Parser

    static func crlfRows() throws {
        let rows = CSVParser.parse("name,email\r\nJane,j@example.test\r\nBob,b@example.test\r\n")
        try expect(rows == [["name", "email"], ["Jane", "j@example.test"], ["Bob", "b@example.test"]], "CRLF rows: \(rows)")
    }

    static func crRows() throws {
        let rows = CSVParser.parse("name,email\rJane,j@example.test\r")
        try expect(rows == [["name", "email"], ["Jane", "j@example.test"]], "CR rows: \(rows)")
    }

    static func quotedCRLF() throws {
        let rows = CSVParser.parse("name,notes\r\nJane,\"line one\r\nline \"\"two\"\"\"\r\n")
        try expect(rows == [["name", "notes"], ["Jane", "line one\r\nline \"two\""]], "quoted CRLF: \(rows)")
    }

    static func semicolonRows() throws {
        let rows = CSVParser.parse("nom;courriel;soumission\r\nJane;j@example.test;2 500,00 $\r\n")
        try expect(rows == [["nom", "courriel", "soumission"], ["Jane", "j@example.test", "2 500,00 $"]], "semicolon rows: \(rows)")
    }

    static func tabRows() throws {
        let rows = CSVParser.parse("name\temail\nJane, Q.\tj@example.test\n")
        try expect(rows == [["name", "email"], ["Jane, Q.", "j@example.test"]], "tab rows: \(rows)")
    }

    static func separatorHint() throws {
        let rows = CSVParser.parse("sep=;\r\nname;notes\r\nJane;a,b,c,d\r\n")
        try expect(rows == [["name", "notes"], ["Jane", "a,b,c,d"]], "sep= rows: \(rows)")
    }

    static func quotedCommasInSemicolonHeader() throws {
        let rows = CSVParser.parse("\"name, full\";email\nJane;j@example.test\n")
        try expect(rows == [["name, full", "email"], ["Jane", "j@example.test"]], "quoted header rows: \(rows)")
    }

    static func bomDropped() throws {
        let rows = CSVParser.parse("\u{FEFF}audit,language\nPilot,FR\n")
        try expect(rows.first?.first == "audit", "BOM survived: \(rows)")
    }

    static func leadingBlankLines() throws {
        let rows = CSVParser.parse("\u{FEFF}\r\n\r\nnom;courriel\r\nJane;j@example.test\r\n")
        try expect(rows == [["nom", "courriel"], ["Jane", "j@example.test"]], "leading blank rows: \(rows)")
        let tabs = CSVParser.parse("\n\nname\temail\nJane\tj@example.test\n")
        try expect(tabs == [["name", "email"], ["Jane", "j@example.test"]], "leading blank tab rows: \(tabs)")
    }

    static func separatorHintAfterBlankLine() throws {
        let rows = CSVParser.parse("\r\nsep=;\r\nname;notes\r\nJane;a,b,c,d\r\n")
        try expect(rows == [["name", "notes"], ["Jane", "a,b,c,d"]], "sep= after blank rows: \(rows)")
    }

    static func tabHeaderWithComma() throws {
        let rows = CSVParser.parse("Name, full\tEmail\nJane Doe\tj@example.test\nBob Roy\tb@example.test\n")
        try expect(rows == [["Name, full", "Email"], ["Jane Doe", "j@example.test"], ["Bob Roy", "b@example.test"]], "tab rows with comma header: \(rows)")
    }

    static func semicolonWithDecimalCommas() throws {
        let rows = CSVParser.parse("Montant;Nom\n1,5;Jane\n2,25;Bob\n")
        try expect(rows == [["Montant", "Nom"], ["1,5", "Jane"], ["2,25", "Bob"]], "semicolon rows with decimal commas: \(rows)")
        let ragged = CSVParser.parse("name,email,notes\nJane,j@example.test\nBob,b@example.test,x;y\n")
        try expect(ragged.first == ["name", "email", "notes"] && ragged.count == 3, "ragged comma rows: \(ragged)")
    }

    static func amounts() throws {
        let cases: [(String, Double?)] = [
            ("2500", 2_500), ("$2,500", 2_500), ("$2,500.00", 2_500), ("2 500,00 $", 2_500),
            ("2\u{00A0}500,50 $", 2_500.5), ("2\u{202F}500 $", 2_500), ("2.500,00 €", 2_500),
            ("1,234,567.89", 1_234_567.89), ("1.234.567,89", 1_234_567.89), ("12,50", 12.5),
            ("99.95", 99.95), ("99.950", 99.95), ("0.125", 0.125), ("1.250", 1.25), ("1250.000", 1_250),
            ("2,500", 2_500), ("999,999", 999_999), ("0,125", 0.125), ("1234,567", 1_234.567),
            ("1.234.567", 1_234_567), ("1,234,567", 1_234_567), ("", nil), ("n/a", nil),
        ]
        for (raw, expected) in cases {
            let parsed = CSVAmount.parse(raw)
            try expect(parsed == expected, "\"\(raw)\" parsed as \(String(describing: parsed)), expected \(String(describing: expected))")
        }
    }

    // MARK: - Lead import

    static func crlfImport() throws {
        let (store, directory) = try freshStore()
        let url = try file("excel.csv", Data("\u{FEFF}Name,Email,Quote\r\nJane Doe,jane@example.test,\"$1,200.00\"\r\nBob Roy,bob@example.test,800\r\n".utf8), in: directory)
        try expect(try store.importCSV(from: url) == 2, "CRLF export did not import two leads")
        try expect(Set(store.leads.map(\.name)) == ["Jane Doe", "Bob Roy"], "CRLF lead names: \(store.leads.map(\.name))")
        try expect(store.leads.first { $0.name == "Jane Doe" }?.quoteAmount == 1_200, "CRLF quote amount is incorrect")
    }

    static func frenchImport() throws {
        let (store, directory) = try freshStore()
        let url = try file("fr.csv", Data("Nom;Courriel;Entreprise;Soumission\r\nÉlise Côté;elise@example.test;Rénovations Côté;2 500,00 $\r\n".utf8), in: directory)
        try expect(try store.importCSV(from: url) == 1, "French export did not import one lead")
        let lead = store.leads.first
        try expect(lead?.email == "elise@example.test" && lead?.company == "Rénovations Côté", "French columns were not mapped")
        try expect(lead?.name == "Élise Côté", "French name: \(String(describing: lead?.name))")
        try expect(lead?.quoteAmount == 2_500, "French amount parsed as \(String(describing: lead?.quoteAmount))")

        let split = try file("fr-split.csv", Data("Prénom;Nom;Téléphone\r\nÉlise;Côté;514-555-0100\r\n".utf8), in: directory)
        try expect(try store.importCSV(from: split) == 1, "Prénom/Nom export did not import one lead")
        try expect(store.leads.first?.name == "Élise Côté" && store.leads.first?.phone == "514-555-0100", "Prénom/Nom was not combined: \(String(describing: store.leads.first?.name))")
    }

    static func utf16Import() throws {
        let (store, directory) = try freshStore()
        var data = Data([0xFF, 0xFE])
        data.append("name\temail\r\nÉlise\telise@example.test\r\n".data(using: .utf16LittleEndian)!)
        let url = try file("unicode.txt", data, in: directory)
        try expect(try store.importCSV(from: url) == 1, "UTF-16 export did not import one lead")
        try expect(store.leads.first?.name == "Élise", "UTF-16 name: \(String(describing: store.leads.first?.name))")
    }

    static func windows1252Import() throws {
        let (store, directory) = try freshStore()
        let url = try file("legacy.csv", "name,email\r\nÉlise Côté,elise@example.test\r\n".data(using: .windowsCP1252)!, in: directory)
        try expect(try store.importCSV(from: url) == 1, "Windows-1252 export did not import one lead")
        try expect(store.leads.first?.name == "Élise Côté", "Windows-1252 name: \(String(describing: store.leads.first?.name))")
    }

    static func windows1252Punctuation() throws {
        let (store, directory) = try freshStore()
        let text = "name,company,notes\r\nZoé L’Écuyer,Cœur & Fils,“5 à 7” – 20 € …\r\n"
        let url = try file("legacy-punct.csv", text.data(using: .windowsCP1252)!, in: directory)
        try expect(try store.importCSV(from: url) == 1, "Windows-1252 punctuation file did not import one lead")
        try expect(store.leads.first?.name == "Zoé L’Écuyer" && store.leads.first?.company == "Cœur & Fils", "Windows-1252 punctuation: \(String(describing: store.leads.first?.name))")
    }

    static func windows1252ExtendedLetters() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["Šárka", "Žofie", "Aleš", "Blaž", "Ÿvette"]
        let text = "name,email\r\n" + names.map { "\($0),lead@example.test\r\n" }.joined()
        let url = try file("legacy-letters.csv", text.data(using: .windowsCP1252)!, in: directory)
        try expect(try store.importCSV(from: url) == names.count, "valid extended letters rejected")
        try expect(store.leads.map(\.name) == names, "extended names were changed")
    }

    static func windows1252DefinedCharacters() throws {
        // All 27 defined characters in the 0x80...0x9F byte range, separated so
        // adjacent bytes cannot accidentally look like a UTF-8 sequence.
        let text = "€ ‚ ƒ „ … † ‡ ˆ ‰ Š ‹ Œ Ž ‘ ’ “ ” • – — ˜ ™ š › œ ž Ÿ"
        try expect(ImportLimits.decodeText(text.data(using: .windowsCP1252)!) == text, "defined Windows-1252 characters rejected or changed")
    }

    static func windows1252UndefinedBytes() throws {
        for byte: UInt8 in [0x81, 0x8D, 0x8F, 0x90, 0x9D] {
            var data = Data("name,email\r\nInvalid".utf8)
            data.append(byte)
            data.append(Data(",lead@example.test\r\n".utf8))
            try expectUnsupportedText("undefined.csv", data, "undefined Windows-1252 byte \(byte)")
        }
    }

    static func bareUTF16Import() throws {
        for (label, encoding) in [("LE", String.Encoding.utf16LittleEndian), ("BE", .utf16BigEndian)] {
            for name in ["Jane Doe", "Élise Côté"] {
                let (store, directory) = try freshStore()
                let url = try file("bare-utf16.csv", "name,email\r\n\(name),lead@example.test\r\n".data(using: encoding)!, in: directory)
                try expect(try store.importCSV(from: url) == 1, "BOM-less UTF-16 \(label) \"\(name)\" did not import one lead")
                try expect(store.leads.first?.name == name && store.leads.first?.email == "lead@example.test", "BOM-less UTF-16 \(label) lead: \(String(describing: store.leads.first?.name))")
            }
        }
    }

    private static func expectUnsupportedText(_ name: String, _ data: Data, _ what: String) throws {
        let (store, directory) = try freshStore()
        let url = try file(name, data, in: directory)
        do {
            _ = try store.importCSV(from: url)
        } catch let error as NSError where error.domain == "ContextwardImport" && error.code == 415 {
            try expect(store.leads.isEmpty, "\(what) left leads behind")
            return
        }
        throw SmokeTestFailure.failed("\(what) was not rejected with 415")
    }

    static func binaryRejected() throws {
        try expectUnsupportedText("image.csv", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0xFF, 0x81]), "binary file")
    }

    static func corruptUTF8Rejected() throws {
        var data = Data("name,email\nÉlise Côté,elise@example.test\nBob,".utf8)
        data.append(0xE9) // one Latin-1 byte in an otherwise UTF-8 file
        data.append(Data("ric@example.test\n".utf8))
        try expectUnsupportedText("corrupt.csv", data, "UTF-8 file with a corrupt byte")
    }

    static func macRomanRejected() throws {
        // Some Mac Roman byte sequences are also valid Windows-1252 and cannot
        // be distinguished automatically. Here ç is 0x8D, undefined in CP1252.
        try expectUnsupportedText("mac.csv", "name,email\rFrançois Côté,lead@example.test\r".data(using: .macOSRoman)!, "Mac Roman with undefined Windows-1252 bytes")
    }

    static func headerOnlyNotice() throws {
        let (store, directory) = try freshStore()
        let url = try file("empty.csv", Data("name,email\r\n".utf8), in: directory)
        try expect(try store.importCSV(from: url) == 0, "header-only file imported leads")
        try expect(store.lastCSVImport?.summary == "No valid leads found in CSV.", "header-only result: \(String(describing: store.lastCSVImport?.summary))")
    }

    static func unknownHeadersNotice() throws {
        let (store, directory) = try freshStore()
        let url = try file("unknown.csv", Data("foo,bar\n1,2\n".utf8), in: directory)
        try expect(try store.importCSV(from: url) == 0, "unknown headers imported leads")
        try expect(store.lastCSVImport?.summary.hasPrefix("No recognized columns") == true, "unknown headers result: \(String(describing: store.lastCSVImport?.summary))")
        try expect(store.lastCSVImport?.ignoredColumns == ["foo", "bar"], "unknown headers named: \(String(describing: store.lastCSVImport?.ignoredColumns))")
    }

    // MARK: - Lantern import

    static func baeaCRLFWithBOM() throws {
        let (store, directory) = try freshStore()
        let csv = "\u{FEFF}audit,client,language,disclosure,escalation,context_transfer,tone,hallucinations,sample_size\r\nPilot,Demo Co,FR,80,60,70,90,95,20\r\nPilot,Demo Co,EN,90,90,90,90,95,20\r\n"
        let url = try file("baea.csv", Data(csv.utf8), in: directory)
        try expect(try store.importBAEACSV(from: url) == 1, "Lantern CRLF export did not import one audit")
        try expect(store.audits.contains { $0.name == "Pilot" && $0.sampleSizeFR == 20 && $0.sampleSizeEN == 20 }, "Lantern CRLF scores were not imported")
    }

    static func baeaEmptyNotice() throws {
        let (store, directory) = try freshStore()
        let url = try file("baea-empty.csv", Data("audit,language\r\n".utf8), in: directory)
        try expect(try store.importBAEACSV(from: url) == 0, "empty Lantern file imported audits")
        try expect(store.notice == "No Lantern scores found.", "empty Lantern notice: \(String(describing: store.notice))")
    }

    private static let lanternCSV = "audit,client,language,disclosure,escalation,context_transfer,tone,hallucinations,sample_size\nPilot,Demo Co,FR,80,60,70,90,95,20\nPilot,Demo Co,EN,90,90,90,90,95,20\n"

    private static func workspaceBytes(_ workspace: PersistentWorkspace) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(workspace)
    }

    private static func baeaSaveFailure(workbook: Bool) throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.commitWorkspace { $0.business.name = "Existing synthetic workspace" }
        let input: URL
        if workbook {
            input = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/baea-synthetic.xlsx")
        } else { input = try file("lantern.csv", Data(lanternCSV.utf8), in: directory) }
        let before = try workspaceBytes(store.workspace)
        let durable = try Data(contentsOf: store.storageURL)
        let folder = store.storageURL.deletingLastPathComponent()
        let saved = directory.appendingPathComponent("saved-workspace")
        try FileManager.default.moveItem(at: folder, to: saved)
        try Data("Synthetic write blocker".utf8).write(to: folder)
        func run() throws -> Int { try workbook ? store.importBAEAXLSX(from: input) : store.importBAEACSV(from: input) }
        var refused = false
        do { _ = try run() } catch { refused = true }
        try expect(refused, "failed Lantern write was reported as successful")
        try expect(try workspaceBytes(store.workspace) == before, "failed Lantern write published in-memory records")
        try expect(try Data(contentsOf: saved.appendingPathComponent("workspace.json")) == durable, "failed import changed saved records")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: saved, to: folder)
        try expect(try run() == 1, "retry did not import one audit")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try expect(try workspaceBytes(reloaded.workspace) == workspaceBytes(store.workspace), "retry did not survive reload")
    }

    static func baeaCSVSaveFailure() throws { try baeaSaveFailure(workbook: false) }
    static func baeaWorkbookSaveFailure() throws { try baeaSaveFailure(workbook: true) }

    static func baeaReimportContext() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("lantern.csv", Data(lanternCSV.replacingOccurrences(of: ",80,", with: ",80.0,").replacingOccurrences(of: ",20\n", with: ",20.0\n").utf8), in: directory)
        try expect(try store.importBAEACSV(from: input) == 1, "initial import failed")
        var reviewed = store.audits[0]
        reviewed.companyID = UUID(); reviewed.contactID = UUID(); reviewed.leadID = UUID()
        reviewed.findings = "Owner-reviewed finding"; reviewed.remediation = "Owner-reviewed next action"
        reviewed.methodologyVersion = "Owner-reviewed method"
        try expect(store.update(reviewed), "could not save reviewed context")
        try expect(try store.importBAEACSV(from: input) == 1, "reimport failed")
        let actual = store.audits[0]
        try expect(store.audits.count == 1 && actual.id == reviewed.id && actual.createdAt == reviewed.createdAt, "reimport replaced the reviewed audit identity")
        try expect(actual.companyID == reviewed.companyID && actual.contactID == reviewed.contactID && actual.leadID == reviewed.leadID, "reimport discarded CRM links")
        try expect(actual.findings == reviewed.findings && actual.remediation == reviewed.remediation && actual.methodologyVersion == reviewed.methodologyVersion, "reimport discarded owner context")
        try expect(actual.sampleSizeFR == 20 && actual.sampleSizeEN == 20 && actual.transcripts.count == 2, "replay accumulated sample or transcript duplicates")
        try expect(actual.transcripts.map(\.id) == reviewed.transcripts.map(\.id), "identical transcript identities changed on replay")
    }

    static func baeaInvalidRows() throws {
        let cases = [
            ("language", "Later,Demo Co,DE,80,60,70,90,95,20"),
            ("disclosure", "Later,Demo Co,FR,oops,60,70,90,95,20"),
            ("disclosure", "Later,Demo Co,FR,101,60,70,90,95,20"),
            ("sample_size", "Later,Demo Co,FR,80,60,70,90,95,-1"),
            ("sample_size", "Later,Demo Co,FR,80,60,70,90,95,1.5")
        ]
        for (column, row) in cases {
            let (store, directory) = try freshStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try store.commitWorkspace { $0.business.name = "Existing" }
            let before = try workspaceBytes(store.workspace)
            let csv = lanternCSV.split(separator: "\n").prefix(2).joined(separator: "\n") + "\n" + row + "\n"
            let input = try file("invalid-lantern.csv", Data(csv.utf8), in: directory)
            var message: String?
            do { _ = try store.importBAEACSV(from: input) } catch { message = error.localizedDescription }
            try expect(message?.contains("row 3") == true && message?.contains(column) == true, "invalid \(column) was accepted or lacked row/column explanation")
            try expect(try workspaceBytes(store.workspace) == before, "a later invalid row left a partial import")
            try expect(try workspaceBytes(AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore()).workspace) == before, "invalid input changed durable records")
        }
    }

    static func baeaAmbiguousName() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.commitWorkspace { $0.audits = [BilingualAudit(name: "Pilot"), BilingualAudit(name: "Pilot")] }
        let before = try workspaceBytes(store.workspace)
        let csv = lanternCSV + "New audit,Demo Co,FR,80,60,70,90,95,1\n"
        let input = try file("ambiguous-lantern.csv", Data(csv.utf8), in: directory)
        var refused = false
        do { _ = try store.importBAEACSV(from: input) } catch { refused = true }
        try expect(refused, "ambiguous audit identity was silently replaced")
        try expect(try workspaceBytes(store.workspace) == before, "ambiguous import deleted audits or imported part of the file")
    }

    private static func canonicalWorkbook(in directory: URL, score: String = "4", template: Bool = false, multirow: Bool = false) throws -> URL {
        let root = directory.appendingPathComponent("workbook-\(UUID())")
        let sheets = root.appendingPathComponent("xl/worksheets")
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        func sheet(_ rows: [[String]]) -> String {
            let body = rows.enumerated().map { offset, row in
                "<row r=\"\(offset + 1)\">" + row.enumerated().map { index, value in
                    "<c r=\"\(String(UnicodeScalar(65 + index)!))\(offset + 1)\" t=\"inlineStr\"><is><t>\(value)</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            return "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(body)</sheetData></worksheet>"
        }
        let headers = ["Transcript ID", "Workflow", "Date", "D1 Self-Disclosure", "D2 Escalation Trigger Accuracy", "D3 Context Transfer Completeness", "D4 Tone/Register Consistency", "D5 Hallucination Flags", "Taxonomy Code(s)", "Notes / Quoted Excerpt"]
        try sheet([["Overview"]]).write(to: sheets.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)
        let en = template ? ["synthetic-en"] + Array(repeating: "", count: 9) : ["synthetic-en", "support", "2026-11-06", score, "4", "4", "4", "4", "FIXTURE-EN", "Synthetic English excerpt"]
        let fr = template ? ["synthetic-fr"] + Array(repeating: "", count: 9) : ["synthetic-fr", "support", "2026-11-06", "3", "3", "3", "3", "3", "FIXTURE-FR", "Synthetic French excerpt"]
        let enRows = multirow ? [headers, ["synthetic-en-1", "support", "2026-11-06", "1", "1", "1", "1", "1", "FIXTURE-EN", "First English excerpt"], ["synthetic-en-2", "support", "2026-11-06", "5", "5", "5", "5", "5", "FIXTURE-EN", "Second English excerpt"]] : [headers, en]
        let frRows = multirow ? [headers, ["synthetic-fr", "support", "2026-11-06", "2", "2", "2", "2", "2", "FIXTURE-FR", "French excerpt"]] : [headers, fr]
        try sheet(enRows).write(to: sheets.appendingPathComponent("sheet2.xml"), atomically: true, encoding: .utf8)
        try sheet(frRows).write(to: sheets.appendingPathComponent("sheet3.xml"), atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("synthetic-canonical.xlsx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.arguments = ["-qr", output.path, "xl"]; zip.currentDirectoryURL = root
        try zip.run(); zip.waitUntilExit()
        try expect(zip.terminationStatus == 0, "could not create canonical fixture")
        return output
    }

    static func baeaCanonicalEvidence() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(try store.importBAEAXLSX(from: canonicalWorkbook(in: directory)) == 1, "canonical workbook did not import")
        let audit = store.audits[0]
        try expect(audit.english.disclosure == 80 && audit.french.disclosure == 60 && audit.languageGap == 20, "canonical scores were not scaled correctly")
        try expect(audit.sampleSizeEN == 1 && audit.sampleSizeFR == 1 && audit.transcripts.count == 2, "canonical samples were not retained")
        let en = audit.transcripts.first { $0.language == .english }
        try expect(en?.transcriptID == "synthetic-en" && en?.workflow == "support" && en?.date == "2026-11-06", "canonical transcript identity/context was dropped")
        try expect(en?.taxonomyCodes == "FIXTURE-EN" && en?.notes == "Synthetic English excerpt", "canonical taxonomy or quoted evidence was dropped")
    }

    static func baeaCanonicalInvalid() throws {
        for score in ["oops", "6", "", "NaN"] {
            let (store, directory) = try freshStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = try canonicalWorkbook(in: directory, score: score)
            var refused = false
            do { _ = try store.importBAEAXLSX(from: input) } catch { refused = true }
            try expect(refused && store.audits.isEmpty, "invalid canonical score was converted to a valid zero score")
        }
    }

    static func baeaCanonicalTemplate() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try canonicalWorkbook(in: directory, template: true)
        try expect(try store.importBAEAXLSX(from: input) == 0, "unfilled template was counted as scored evidence")
        try expect(store.audits.isEmpty && store.notice == "No Lantern scores found.", "template created a misleading audit")
        try expect(!FileManager.default.fileExists(atPath: store.storageURL.path), "empty template wrote a workspace")
    }

    private static let rollupHeader = "audit,client,language,disclosure,escalation,context_transfer,tone,hallucinations,sample_size\n"
    private static let weightedRows = [
        "Weighted,Fixture,FR,20,20,20,20,20,1",
        "Weighted,Fixture,FR,100,100,100,100,100,3",
        "Weighted,Fixture,EN,60,60,60,60,60,4"
    ]

    static func baeaWeightedScores() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("weighted.csv", Data((rollupHeader + weightedRows.joined(separator: "\n")).utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let initial = store.audits[0]
        let gap: Double? = initial.languageGap
        try expect(Double(initial.french.disclosure) == 80 && Double(initial.english.disclosure) == 60 && gap == 20, "the last row replaced the sample-weighted language score")
        try expect(initial.sampleSizeFR == 4 && initial.sampleSizeEN == 4 && initial.transcripts.count == 3, "sample or transcript evidence was lost")
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String: Any]
        let traces = raw["transcripts"] as! [[String: Any]]
        try expect(traces.compactMap { $0["sampleCount"] as? Int } == [1, 3, 4], "per-row sample weights were not retained with source evidence")
        try (rollupHeader + weightedRows.reversed().joined(separator: "\n")).write(to: input, atomically: true, encoding: .utf8)
        _ = try store.importBAEACSV(from: input)
        let replay = store.audits[0]
        try expect(Double(replay.french.disclosure) == 80 && Double(replay.english.disclosure) == 60, "row order changed the aggregate")
        try expect(replay.id == initial.id && Set(replay.transcripts.map(\.id)) == Set(initial.transcripts.map(\.id)), "reordered identical evidence changed identities")
    }

    static func baeaWeightedBoundary() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let weights = [20159073515986425, 28328001726103041, 76792789922227480]
        let rows = weights.map { "Boundary,Fixture,FR,100,100,100,100,100,\($0)" }
            + ["Boundary,Fixture,EN,100,100,100,100,100,1"]
        let input = try file("boundary.csv", Data((rollupHeader + rows.joined(separator: "\n")).utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let audit = store.audits[0]
        try expect(audit.french.disclosure == 100 && audit.languageGap == 0 && audit.priority == "Low", "floating-point boundary noise invalidated a complete assessment")
        try expect(audit.sampleSizeFR == weights.reduce(0, +), "large valid sample counts lost precision")
    }

    static func baeaCanonicalMean() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importBAEAXLSX(from: canonicalWorkbook(in: directory, multirow: true))
        let audit = store.audits[0]
        let gap: Double? = audit.languageGap
        try expect(Double(audit.english.disclosure) == 60 && Double(audit.french.disclosure) == 40 && gap == 20, "canonical transcripts were not averaged")
        try expect(audit.sampleSizeEN == 2 && audit.sampleSizeFR == 1 && audit.transcripts.count == 3, "canonical sample counts changed")
    }

    static func baeaFractionalScores() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("fractional.csv", Data((rollupHeader + "Fractional,Fixture,FR,12.5,12.5,12.5,12.5,12.5,1\nFractional,Fixture,EN,10,10,10,10,10,1\n").utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let audit = store.audits[0]
        let gap: Double? = audit.languageGap
        try expect(Double(audit.french.disclosure) == 12.5 && gap.map { abs($0 - 2.5) < 0.000001 } == true, "fractional scores were refused or rounded")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try expect(try workspaceBytes(reloaded.workspace) == workspaceBytes(store.workspace), "fractional precision did not survive reload")
        let backup = directory.appendingPathComponent("fractional-backup.json")
        try store.exportControlWardBackup(to: backup)
        let restored = AppStore(storageURL: directory.appendingPathComponent("restored/workspace.json"), secrets: InMemorySecretStore())
        try restored.restoreControlWardBackup(Data(contentsOf: backup), confirmed: true)
        try expect(restored.audits == store.audits, "backup/restore lost fractional scores or source weights")
        let reopened = AppStore(storageURL: restored.storageURL, secrets: InMemorySecretStore())
        try expect(reopened.audits == store.audits, "restored fractional evidence did not survive restart")
    }

    static func baeaMissingLanguage() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("french-only.csv", Data((rollupHeader + "Unpaired,Fixture,FR,80,80,80,80,80,1\n").utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let gap: Double? = store.audits[0].languageGap
        let average: Double? = store.averageLanguageGap
        try expect(gap == nil && average == nil && store.audits[0].priority == "Unscored", "missing English was presented as a measured zero")
        _ = store.runAutomations()
        try expect(store.tasks.isEmpty, "missing-language evidence created a remediation task")
    }

    static func baeaIncompleteScores() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("partial.csv", Data("audit,client,language,escalation,samples\nPartial,Fixture,FR,20,1\nPartial,Fixture,EN,80,1\n".utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let gap: Double? = store.audits[0].languageGap
        try expect(gap == nil && store.audits[0].priority == "Unscored", "missing score dimensions were invented as zeros in a comparison")
        try expect(store.audits[0].transcripts.count == 2, "partial source evidence was dropped")
        _ = store.runAutomations()
        try expect(store.tasks.isEmpty, "incomplete scores created a remediation task")
    }

    static func baeaZeroWeight() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = weightedRows + ["Weighted,Fixture,FR,0,0,0,0,0,0"]
        let input = try file("zero-weight.csv", Data((rollupHeader + rows.joined(separator: "\n")).utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let audit = store.audits[0]
        let gap: Double? = audit.languageGap
        try expect(Double(audit.french.disclosure) == 80 && gap == 20 && audit.sampleSizeFR == 4, "zero-sample evidence changed the mean")
        try expect(audit.transcripts.count == 4, "zero-sample source row was lost")
    }

    static func baeaComparableAverage() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = ["Known,Fixture,FR,80,80,80,80,80,1", "Known,Fixture,EN,60,60,60,60,60,1", "Unpaired,Fixture,FR,100,100,100,100,100,1"]
        let input = try file("averages.csv", Data((rollupHeader + rows.joined(separator: "\n")).utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let average: Double? = store.averageLanguageGap
        try expect(average == 20, "unscored audit inflated the average")
        _ = store.runAutomations()
        try expect(store.tasks.count == 1 && store.tasks[0].title.contains("Known"), "automation did not restrict remediation to measured gaps")
    }

    static func baeaMeasuredZero() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("measured-zero.csv", Data((rollupHeader + "Measured,Fixture,FR,0,0,0,0,0,1\nMeasured,Fixture,EN,10,10,10,10,10,1\n").utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        let gap: Double? = store.audits[0].languageGap
        try expect(gap == 10 && store.audits[0].priority == "High", "genuine measured zero was confused with absent evidence")
    }

    static func baeaOwnerIncomplete() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("owner-review.csv", Data(lanternCSV.utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.audits[0])) as! [String: Any]
        raw["frenchScoresComplete"] = false
        let reviewed = try JSONDecoder().decode(BilingualAudit.self, from: JSONSerialization.data(withJSONObject: raw))
        try expect(store.update(reviewed), "owner review failed to save")
        let gap: Double? = store.audits[0].languageGap
        try expect(gap == nil && store.audits[0].priority == "Unscored", "owner's incomplete-assessment decision was ignored")
        _ = try store.importBAEACSV(from: input)
        let refreshedGap: Double? = store.audits[0].languageGap
        try expect(refreshedGap == nil, "source refresh erased the owner's withholding decision")
        _ = store.runAutomations()
        try expect(store.tasks.isEmpty, "owner-unscored audit created a task")
    }

    static func baeaLegacyScores() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("legacy.csv", Data((rollupHeader + "Legacy,Fixture,FR,80,80,80,80,80,1\nLegacy,Fixture,EN,60,60,60,60,60,1\n").utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.audits[0])) as! [String: Any]
        raw.removeValue(forKey: "frenchScoresComplete"); raw.removeValue(forKey: "englishScoresComplete")
        var traces = raw["transcripts"] as! [[String: Any]]
        for i in traces.indices { traces[i].removeValue(forKey: "sampleCount"); traces[i].removeValue(forKey: "scoreFieldsComplete") }
        raw["transcripts"] = traces
        let legacy = try JSONDecoder().decode(BilingualAudit.self, from: JSONSerialization.data(withJSONObject: raw))
        let gap: Double? = legacy.languageGap
        try expect(gap == 20 && legacy.sampleSizeFR == 1 && legacy.sampleSizeEN == 1, "legacy integer assessment no longer decodes")
    }

    static func baeaLegacyMultirow() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try file("legacy-rows.csv", Data((rollupHeader + weightedRows.joined(separator: "\n")).utf8), in: directory)
        _ = try store.importBAEACSV(from: input)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.audits[0])) as! [String: Any]
        raw["french"] = ["disclosure": 100, "escalation": 100, "contextTransfer": 100, "tone": 100, "hallucinations": 100]
        raw.removeValue(forKey: "frenchScoresComplete"); raw.removeValue(forKey: "englishScoresComplete")
        var traces = raw["transcripts"] as! [[String: Any]]
        for i in traces.indices { traces[i].removeValue(forKey: "sampleCount"); traces[i].removeValue(forKey: "scoreFieldsComplete") }
        raw["transcripts"] = traces
        let legacy = try JSONDecoder().decode(BilingualAudit.self, from: JSONSerialization.data(withJSONObject: raw))
        let gap: Double? = legacy.languageGap
        try expect(gap == nil && legacy.priority == "Unscored", "legacy last-row score was endorsed without its missing weights")
        try expect(Double(legacy.french.disclosure) == 100 && legacy.transcripts.count == 3, "legacy evidence was modified or lost")
    }

    // MARK: - Slice CSV (Water 9:42 AM ET). Made-up rows only.

    private static func importResult(_ csv: String, name: String = "leads.csv", store: AppStore? = nil) throws -> (AppStore, CSVImportResult) {
        let (fresh, directory) = try freshStore()
        let target = store ?? fresh
        let url = try file(name, Data(csv.utf8), in: directory)
        _ = try target.importCSV(from: url)
        guard let result = target.lastCSVImport else { throw SmokeTestFailure.failed("no import result kept on the store") }
        return (target, result)
    }

    static func csv1OrganisationHeaders() throws {
        for header in ["organization", "org", "organisation", "institution", "employer", "account", "firm", "agency", "établissement", "etablissement",
                       "employeur", "entreprise", "compagnie", "Organisation Name", "ÉTABLISSEMENT", " Org ", "Employer_", "company"] {
            let (store, _) = try importResult("name,\(header)\nAlex Exemple,Société Fictive\n")
            try expect(store.leads.first?.company == "Société Fictive", "header \"\(header)\" did not fill company: \(String(describing: store.leads.first?.company))")
        }
        let (store, result) = try importResult("name,org,employer\nAlex Exemple,,Employeur Fictif\nBea Exemple,Org Fictive,Autre Fictif\n")
        try expect(store.leads.first { $0.name == "Alex Exemple" }?.company == "Employeur Fictif", "second column used when the first is empty")
        try expect(store.leads.first { $0.name == "Bea Exemple" }?.company == "Org Fictive", "first non-empty wins")
        try expect(result.companyColumns == ["org", "employer"], "result names the company columns used: \(result.companyColumns)")
    }

    static func csv2NamelessRows() throws {
        let (store, result) = try importResult("name,email\nAlex Exemple,a@example.test\n,b@example.test\nBea Exemple,c@example.test\n  ,d@example.test\nCy Exemple,e@example.test\n")
        try expect(result.imported == 3 && store.leads.count == 3, "imported 3, got \(result.imported)")
        try expect(result.skipped == [CSVRowNote(row: 3, reason: "no-name"), CSVRowNote(row: 5, reason: "no-name")], "skipped rows: \(result.skipped)")
    }

    static func csv3IgnoredColumns() throws {
        let (_, result) = try importResult("name,Favourite colour,email,Notes2\nAlex Exemple,blue,a@example.test,x\n")
        try expect(result.ignoredColumns == ["Favourite colour", "Notes2"], "ignored columns: \(result.ignoredColumns)")
        try expect(result.imported == 1, "the known columns still import")
    }

    static func csv4Values() throws {
        for raw in ["5000", "5 000", "5,000.00", "5 000,00 $", "$5,000"] {
            try expect(CSVValue.amount(raw) == .value(5_000), "amount \"\(raw)\": \(CSVValue.amount(raw))")
        }
        for raw in ["about 5k", "5k", "TBD", "five thousand"] {
            try expect(CSVValue.amount(raw) == .unreadable, "amount \"\(raw)\" should be unreadable: \(CSVValue.amount(raw))")
        }
        for raw in ["2026-10-23", "23/10/2026", "Oct 23, 2026"] {
            try expect(CSVValue.date(raw) == .day("2026-10-23"), "date \"\(raw)\": \(CSVValue.date(raw))")
        }
        try expect(CSVValue.date("03/04/2026") == .ambiguous, "03/04/2026 is ambiguous: \(CSVValue.date("03/04/2026"))")
        try expect(CSVValue.date("next week") == .unreadable && CSVValue.date("") == .empty && CSVValue.amount(" ") == .empty, "unreadable and empty")
        let csv = "name,quote,date\nA Exemple,5000,2026-10-23\nB Exemple,1,2026-10-23\nC Exemple,2,2026-10-23\nD Exemple,3,2026-10-23\nE Exemple,4,2026-10-23\nF Exemple,about 5k,03/04/2026\nG Exemple,6,someday\n"
        let (store, result) = try importResult(csv)
        try expect(result.imported == 7, "rows with bad values still import: \(result.imported)")
        try expect(store.leads.first { $0.name == "F Exemple" }?.quoteAmount == nil, "unreadable quote left empty")
        try expect(result.warnings == ["row 7, quote: \"about 5k\"", "row 7, date: \"03/04/2026\" (ambiguous day/month, not guessed)", "row 8, date: \"someday\""],
                   "warnings: \(result.warnings)")
    }

    static func csv5PersistentResult() throws {
        let (store, result) = try importResult("name,email,colour\nAlex Exemple,a@example.test,red\n,b@example.test,blue\nNone identified,c@example.test,green\n", name: "salon.csv")
        try expect(store.notice == nil, "no 2.6 s notice for a CSV import: \(String(describing: store.notice))")
        try expect(result.fileName == "salon.csv" && result.imported == 1 && result.skipped.count == 1 && result.flagged.count == 1, "counts: \(result)")
        let lines = CSVImportPresentation.lines(result)
        for needle in ["salon.csv", "Imported 1", "Skipped 1", "Flagged 1", "row 3: no-name", "row 4: placeholder", "ignored column: colour"] {
            try expect(lines.contains { $0.contains(needle) }, "panel shows \"\(needle)\": \(lines)")
        }
        // Nothing clears it but Martin: other store work and time do not.
        store.showNoticeForTesting("another notice")
        try expect(store.lastCSVImport == result, "result still there after other activity")
        store.dismissCSVImport()
        try expect(store.lastCSVImport == nil, "closed by Martin")
    }

    static func csv6SaveFailure() throws {
        let (store, directory) = try freshStore()
        let before = store.leads.count
        // Force the save to throw: the data folder becomes a plain file.
        let data = directory.appendingPathComponent("data")
        try? FileManager.default.removeItem(at: data)
        try Data("not a folder".utf8).write(to: data)
        let url = try file("fail.csv", Data("name,email\nAlex Exemple,a@example.test\nBea Exemple,b@example.test\n".utf8), in: directory)
        _ = try? store.importCSV(from: url)
        let result = store.lastCSVImport
        try expect(result?.failure != nil && result?.imported == 0, "result says the import failed: \(String(describing: result))")
        try expect(result?.summary.hasPrefix("Import failed") == true && result?.summary.contains("Imported") == false, "no success text: \(String(describing: result?.summary))")
        try expect(store.leads.count == before && !store.leads.contains { $0.name == "Alex Exemple" }, "none of the file's leads kept: \(store.leads.map(\.name))")
    }

    static func csv7PlaceholderNames() throws {
        let names = ["None identified", "n/a", "N/A", "TBD", "Unknown", "-", "Role only", "Alex Exemple; Bea Exemple", "CRO (Jane Doe)",
                     "Chief Risk Officer", "Directeur général", "Privacy Officer", "one two three four five six seven",
                     "Jean-François Tremblay", "Mary O'Neil"]
        let csv = "name,org\n" + names.map { "\"\($0)\",Org Fictive" }.joined(separator: "\n") + "\n"
        let (store, result) = try importResult(csv)
        try expect(Set(store.leads.map(\.name)) == ["Jean-François Tremblay", "Mary O'Neil"], "only the two people import: \(store.leads.map(\.name))")
        try expect(result.flagged.map(\.row) == Array(2...14), "flagged rows: \(result.flagged)")
        let reasons = Dictionary(uniqueKeysWithValues: result.flagged.map { ($0.row, $0.reason) })
        try expect(reasons[2] == "placeholder" && reasons[9] == "semicolon" && reasons[10] == "person-in-parentheses" && reasons[11] == "title-only"
                   && reasons[12] == "title-only" && reasons[13] == "title-only" && reasons[14] == "more-than-6-words", "reasons: \(reasons)")
        for name in names.prefix(13) { try expect(CSVNameCheck.flag(name) != nil, "\"\(name)\" not flagged") }
        for name in ["Jean-François Tremblay", "Mary O'Neil", "Élise Côté", "Anne-Marie St-Pierre"] { try expect(CSVNameCheck.flag(name) == nil, "\"\(name)\" flagged") }
    }

    /// The header line and row shapes of the 42-row file imported on 2026-10-23, with made-up values.
    static let sessionHeader = "lead_id,approval_status,priority,batch,batch1_rank,name,title,org,offer,trigger_and_link,trigger_live,within_90_days,title_source,contact_route,fit,risk,chi_call,draft_connection_fr,draft_connection_en,draft_followup_fr,draft_followup_en,batch1_trigger_summary"
    static func sessionFixture() -> String {
        let rows = (1...42).map { index -> String in
            let rank = index <= 20 ? String(index) : ""
            return "L-\(String(format: "%03d", index)),pending review,P\(index % 3 + 1),batch \(index % 2 + 1),\(rank),Personne Fictive \(index),,Organisation Fictive \(index),offre,\"https://example.test/\(index)\",,,,,,\"risque fictif\",,,,,,"
        }
        return ([sessionHeader] + rows).joined(separator: "\r\n") + "\r\n"
    }

    static func csv8Reimport() throws {
        let (store, directory) = try freshStore()
        let url = try file("leads-today.csv", Data(sessionFixture().utf8), in: directory)
        let first = try store.importCSV(from: url)
        let second = try store.importCSV(from: url)
        try expect(first == 42 && second == 0 && store.leads.count == 42, "42 then 0: \(first), \(second), \(store.leads.count)")
        let result = try unwrapResult(store)
        try expect(result.alreadyImportedAt != nil && result.summary.contains("already imported at"), "second result: \(result.summary)")
        // A copy under another name has the same bytes: still already imported.
        let copy = try file("leads-today-copy.csv", Data(sessionFixture().utf8), in: directory)
        try expect(try store.importCSV(from: copy) == 0, "same bytes, other name")
        // Different bytes, one row matching an existing lead by normalised name and company.
        let other = try file("other.csv", Data("name,org\n personne fictive 7 ,ORGANISATION FICTIVE 7\nNouvelle Personne,Org Nouvelle\n".utf8), in: directory)
        try expect(try store.importCSV(from: other) == 1, "only the new lead imports")
        let flagged = try unwrapResult(store).flagged
        try expect(flagged == [CSVRowNote(row: 2, reason: "duplicate-lead")], "duplicate flagged, no merge: \(flagged)")
        try expect(store.leads.count == 43, "no merge, no second copy: \(store.leads.count)")
    }

    private static func unwrapResult(_ store: AppStore) throws -> CSVImportResult {
        guard let result = store.lastCSVImport else { throw SmokeTestFailure.failed("no import result") }
        return result
    }
}
