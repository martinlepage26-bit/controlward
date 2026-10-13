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
            ("CSV: undefined Windows-1252 bytes are rejected", windows1252UndefinedRejected),
            ("CSV: UTF-16 without a byte-order mark imports", bareUTF16Import),
            ("CSV: binary file is rejected as unsupported text", binaryRejected),
            ("CSV: UTF-8 with a corrupt byte is rejected, not garbled", corruptUTF8Rejected),
            ("CSV: Mac Roman with undefined Windows-1252 bytes is rejected", macRomanRejected),
            ("CSV: header-only file reports nothing imported", headerOnlyNotice),
            ("CSV: unrecognized headers say so", unknownHeadersNotice),
            ("CSV: Lantern CRLF export with BOM imports", baeaCRLFWithBOM),
            ("CSV: empty Lantern file reports nothing imported", baeaEmptyNotice),
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
        return (AppStore(storageURL: directory.appendingPathComponent("data/workspace.json")), directory)
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

    static func windows1252ExtendedLetters() throws {
        let (store, directory) = try freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["Šárka", "Žaneta", "Dušan", "Dražen", "Ÿvette", "ƒ"]
        let text = "name,email\r\n" + names.map { "\($0),lead@example.test\r\n" }.joined()
        let url = try file("legacy-letters.csv", text.data(using: .windowsCP1252)!, in: directory)
        try expect(try store.importCSV(from: url) == names.count, "Windows-1252 names were rejected")
        try expect(Set(store.leads.map(\.name)) == Set(names), "Windows-1252 names were garbled")
    }

    static func windows1252UndefinedRejected() throws {
        for byte: UInt8 in [0x81, 0x8D, 0x8F, 0x90, 0x9D] {
            var data = Data("name,email\n".utf8)
            data.append(byte)
            data.append(Data("name,lead@example.test\n".utf8))
            try expectUnsupportedText("undefined.csv", data, "undefined Windows-1252 byte \(byte)")
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
        // è is 0x8F in Mac Roman, undefined in Windows-1252. Other Mac Roman
        // text can also be valid Windows-1252 and cannot reliably be rejected.
        try expectUnsupportedText("mac.csv", "name,email\rÉlise Lefèvre,elise@example.test\r".data(using: .macOSRoman)!, "Mac Roman file")
    }

    static func headerOnlyNotice() throws {
        let (store, directory) = try freshStore()
        let url = try file("empty.csv", Data("name,email\r\n".utf8), in: directory)
        try expect(try store.importCSV(from: url) == 0, "header-only file imported leads")
        try expect(store.notice == "No valid leads found in CSV.", "header-only notice: \(String(describing: store.notice))")
    }

    static func unknownHeadersNotice() throws {
        let (store, directory) = try freshStore()
        let url = try file("unknown.csv", Data("foo,bar\n1,2\n".utf8), in: directory)
        try expect(try store.importCSV(from: url) == 0, "unknown headers imported leads")
        try expect(store.notice?.hasPrefix("No recognized columns") == true, "unknown headers notice: \(String(describing: store.notice))")
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
}
