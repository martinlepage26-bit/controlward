import Foundation

/// Red-team regression tests. Each test runs independently so a single run
/// reports every failing control, then the process exits non-zero on failure.
@MainActor
enum SecurityTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        let tests: [(String, () throws -> Void)] = [
            ("F1 storage: workspace file 600, directory 700", storagePermissions),
            ("F1 storage: default location is Application Support/Contextward", defaultLocation),
            ("F1 storage: loading tightens an existing loose file", loadTightensPermissions),
            ("F1 storage: corrupt workspace is preserved and blocks writes", corruptWorkspaceBlocksWrites),
            ("F7 outbox: directory 700, packages 600", outboxPermissions),
            ("F7 outbox: discarding deletes staged packages", outboxDiscardDeletes),
            ("F7 outbox: marking synced deletes the package", outboxSyncedDeletes),
            ("F1 migration: copy, verify hash, chmod legacy 600, keep legacy", migrationCopiesAndVerifies),
            ("F1 migration: never overwrites an existing workspace", migrationRefusesOverwrite),
            ("F5 caps: CSV over 20 MB is rejected", csvSizeCap),
            ("F5 caps: CSV over 10,000 rows is rejected", csvRowCap),
            ("F5 caps: LeadGen JSON over 20 MB is rejected", leadGenSizeCap),
            ("F5 caps: LeadGen JSON over 10,000 events is rejected", leadGenRowCap),
            ("F5 caps: Exchange JSON over 20 MB is rejected", exchangeSizeCap),
            ("F5 caps: BAEA CSV over 20 MB is rejected", baeaCSVSizeCap),
            ("F4 caps: XLSX file over 20 MB is rejected", xlsxFileSizeCap),
            ("F4 caps: XLSX entry that inflates past the cap is rejected", xlsxInflateCap),
            ("F4 zip: real openpyxl workbook imports in-process", xlsxRealFixture),
            ("F5 headers: exact names only, no substring capture", csvHeaderExact),
            ("F5 headers: known alternative names are accepted", csvHeaderAliases),
            ("F5 LeadGen: unsupported schema version is rejected", leadGenSchemaVersion),
            ("F5 LeadGen: wrongly typed fields are rejected", leadGenWrongTypes),
            ("F6 endpoint: user:pass@ and token query are stripped", endpointStripsSecrets),
            ("F6 endpoint: JWT-looking query values are stripped", endpointStripsTokenValues),
            ("F6 endpoint: secrets already on disk are scrubbed on load", endpointScrubsOnLoad),
            ("F9 reset: requires confirmation", resetRequiresConfirmation),
            ("F9 reset: writes a timestamped 600 backup first", resetWritesBackup),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Security tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    // MARK: - Helpers

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    private static func expectImportError(_ code: Int, _ body: () throws -> Any) throws {
        do {
            _ = try body()
        } catch let error as NSError where error.domain == "ContextwardImport" && error.code == code {
            try expect(!error.localizedDescription.isEmpty, "import error has no message")
            return
        } catch {
            throw SmokeTestFailure.failed("expected ContextwardImport \(code), got \((error as NSError).domain) \((error as NSError).code)")
        }
        throw SmokeTestFailure.failed("expected ContextwardImport \(code), import succeeded")
    }

    private static func freshStore() throws -> (AppStore, URL) {
        let directory = try tempDir().appendingPathComponent("data", isDirectory: true)
        return (AppStore(storageURL: directory.appendingPathComponent("workspace.json")), directory)
    }

    private static func bigFile(_ name: String, prefix: String, bytes: Int, suffix: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var data = Data(prefix.utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: bytes))
        data.append(Data(suffix.utf8))
        try data.write(to: url)
        return url
    }

    private static let overCap = 21 * 1024 * 1024

    // MARK: - Storage

    static func storagePermissions() throws {
        let (store, directory) = try freshStore()
        store.createWorkspace(name: "Permissions Test", industry: "Consulting")
        try expect(try mode(store.storageURL) == 0o600, "workspace.json mode is \(String(try mode(store.storageURL), radix: 8)), expected 600")
        try expect(try mode(directory) == 0o700, "data directory mode is \(String(try mode(directory), radix: 8)), expected 700")
    }

    static func defaultLocation() throws {
        let path = StorageLocation.workspaceFile.path
        try expect(path.hasSuffix("/Library/Application Support/Contextward/workspace.json"), "default workspace path is not in Application Support/Contextward")
    }

    static func loadTightensPermissions() throws {
        let directory = try tempDir().appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = directory.appendingPathComponent("workspace.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = AppStore(storageURL: file)
        try expect(try mode(file) == 0o600, "existing workspace.json was not tightened to 600")
        try expect(try mode(directory) == 0o700, "existing data directory was not tightened to 700")
    }

    static func corruptWorkspaceBlocksWrites() throws {
        let directory = try tempDir()
        let file = directory.appendingPathComponent("workspace.json")
        let original = Data("{not valid workspace json".utf8)
        try original.write(to: file)
        let store = AppStore(storageURL: file)
        guard case .blocked(let reason) = store.recoveryState else {
            throw SmokeTestFailure.failed("corrupt workspace did not enter recovery state")
        }
        try expect(reason.contains("preserved"), "recovery state does not explain preservation")
        store.createWorkspace(name: "Must Not Overwrite", industry: "Testing")
        try expect(try Data(contentsOf: file) == original, "a write overwrote the corrupt workspace")
    }

    // MARK: - Outbox

    private static func stagedStore() throws -> (AppStore, URL) {
        let (store, directory) = try freshStore()
        store.createWorkspace(name: "Outbox Test", industry: "Consulting")
        store.queueSync(to: .twenty)
        try expect(store.stageSyncOutbox() == 1, "outbox package was not staged")
        return (store, directory.appendingPathComponent("outbox", isDirectory: true))
    }

    private static func packageFiles(_ outbox: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
    }

    static func outboxPermissions() throws {
        let (_, outbox) = try stagedStore()
        try expect(try mode(outbox) == 0o700, "outbox directory mode is \(String(try mode(outbox), radix: 8)), expected 700")
        let files = packageFiles(outbox)
        try expect(files.count == 2, "expected a package and a manifest, found \(files.count)")
        for file in files { try expect(try mode(file) == 0o600, "\(file.lastPathComponent) mode is \(String(try mode(file), radix: 8)), expected 600") }
    }

    static func outboxDiscardDeletes() throws {
        let (store, outbox) = try stagedStore()
        try expect(store.discardStagedPackages() == 1, "discard did not report one package")
        try expect(packageFiles(outbox).isEmpty, "discarded outbox package still exists on disk")
        try expect(store.syncJobs.first?.status == "discarded", "sync job was not marked discarded")
    }

    static func outboxSyncedDeletes() throws {
        let (store, outbox) = try stagedStore()
        guard let job = store.syncJobs.first else { throw SmokeTestFailure.failed("no sync job") }
        store.markSynced(job)
        try expect(packageFiles(outbox).isEmpty, "synced outbox package still exists on disk")
        try expect(store.syncJobs.first?.status == "synced", "sync job was not marked synced")
    }

    // MARK: - Migration

    static func migrationCopiesAndVerifies() throws {
        let root = try tempDir()
        let legacyDirectory = root.appendingPathComponent("native-crm/data", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = legacyDirectory.appendingPathComponent("workspace.json")
        var workspace = PersistentWorkspace()
        var lead = Lead.blank(); lead.name = "Migrated Lead"
        workspace.leads = [lead]
        let bytes = try JSONEncoder().encode(workspace)
        try bytes.write(to: legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.path)
        let destination = root.appendingPathComponent("Application Support/Contextward/workspace.json")

        try WorkspaceMigration.migrateLegacy(from: legacy, to: destination)

        try expect(FileManager.default.fileExists(atPath: destination.path), "migrated workspace was not written")
        try expect(try Data(contentsOf: destination) == bytes, "migrated bytes differ from the legacy file")
        try expect(FileManager.default.fileExists(atPath: legacy.path), "legacy workspace was deleted")
        try expect(try mode(legacy) == 0o600, "legacy workspace was not chmod 600")
        try expect(try mode(destination) == 0o600, "migrated workspace is not 600")
        try expect(try mode(destination.deletingLastPathComponent()) == 0o700, "migrated data directory is not 700")
        try expect(AppStore(storageURL: destination).leads.count == 1, "migrated workspace did not load")
    }

    static func migrationRefusesOverwrite() throws {
        let root = try tempDir()
        let legacy = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(PersistentWorkspace()).write(to: legacy)
        let destination = root.appendingPathComponent("dest/workspace.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = Data("{\"leads\":[]}".utf8)
        try existing.write(to: destination)
        var threw = false
        do { try WorkspaceMigration.migrateLegacy(from: legacy, to: destination) } catch { threw = true }
        try expect(threw, "migration overwrote an existing workspace without error")
        try expect(try Data(contentsOf: destination) == existing, "existing workspace bytes changed")
    }

    // MARK: - Import caps

    static func csvSizeCap() throws {
        let (store, directory) = try freshStore()
        let file = try bigFile("big.csv", prefix: "name\n", bytes: overCap, suffix: "\n", in: directory.deletingLastPathComponent())
        try expectImportError(413) { try store.importCSV(from: file) }
    }

    static func csvRowCap() throws {
        let (store, directory) = try freshStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("rows.csv")
        let body = "name\n" + (0...10_000).map { "Row \($0)" }.joined(separator: "\n") + "\n"
        try body.write(to: file, atomically: true, encoding: .utf8)
        try expectImportError(413) { try store.importCSV(from: file) }
    }

    static func leadGenSizeCap() throws {
        let (store, directory) = try freshStore()
        let file = try bigFile("big.json", prefix: "[{\"email\":\"a@example.test\",\"pad\":\"", bytes: overCap, suffix: "\"}]", in: directory.deletingLastPathComponent())
        try expectImportError(413) { try store.importLeadGenJSON(from: file) }
    }

    static func leadGenRowCap() throws {
        let (store, directory) = try freshStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("events.json")
        let events = (0...10_000).map { "{\"email\":\"lead\($0)@example.test\"}" }.joined(separator: ",")
        try "[\(events)]".write(to: file, atomically: true, encoding: .utf8)
        try expectImportError(413) { try store.importLeadGenJSON(from: file) }
    }

    static func exchangeSizeCap() throws {
        let (store, directory) = try freshStore()
        let file = try bigFile("exchange.json", prefix: "{\"pad\":\"", bytes: overCap, suffix: "\"}", in: directory.deletingLastPathComponent())
        try expectImportError(413) { try store.importExchange(from: file) }
    }

    static func baeaCSVSizeCap() throws {
        let (store, directory) = try freshStore()
        let file = try bigFile("baea.csv", prefix: "audit,language\n", bytes: overCap, suffix: ",FR\n", in: directory.deletingLastPathComponent())
        try expectImportError(413) { try store.importBAEACSV(from: file) }
    }

    static func xlsxFileSizeCap() throws {
        let (store, directory) = try freshStore()
        let file = try bigFile("big.xlsx", prefix: "PK", bytes: overCap, suffix: "", in: directory.deletingLastPathComponent())
        try expectImportError(413) { try store.importBAEAXLSX(from: file) }
    }

    static func xlsxInflateCap() throws {
        let (store, directory) = try freshStore()
        let root = directory.deletingLastPathComponent().appendingPathComponent("bomb", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("xl/worksheets", isDirectory: true), withIntermediateDirectories: true)
        var sheet = Data("<worksheet><sheetData>".utf8)
        sheet.append(Data(repeating: UInt8(ascii: " "), count: 60 * 1024 * 1024))
        sheet.append(Data("</sheetData></worksheet>".utf8))
        try sheet.write(to: root.appendingPathComponent("xl/worksheets/sheet1.xml"))
        let archive = directory.deletingLastPathComponent().appendingPathComponent("bomb.xlsx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.arguments = ["-qr", archive.path, "xl"]; zip.currentDirectoryURL = root
        try zip.run(); zip.waitUntilExit()
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        try expect((size?.intValue ?? .max) < 1_000_000, "zip bomb fixture did not compress")
        try expectImportError(413) { try store.importBAEAXLSX(from: archive) }
    }

    static func xlsxRealFixture() throws {
        let (store, _) = try freshStore()
        let fixture = fixtures.appendingPathComponent("baea-synthetic.xlsx")
        try expect(try store.importBAEAXLSX(from: fixture) == 1, "openpyxl workbook did not import one audit")
        try expect(store.audits.contains { $0.name == "Synthetic fixture audit" && $0.sampleSizeFR == 12 && $0.sampleSizeEN == 14 }, "openpyxl workbook scores were not imported")
    }

    // MARK: - Header matching

    static func csvHeaderExact() throws {
        let (store, directory) = try freshStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("headers.csv")
        try "name,username_email_backup,phone_extension_notes,email\nJane Doe,captured@example.test,999,jane@example.test\n".write(to: file, atomically: true, encoding: .utf8)
        try expect(try store.importCSV(from: file) == 1, "exact-header CSV did not import one lead")
        let lead = store.leads.first
        try expect(lead?.name == "Jane Doe", "a substring header overwrote the name")
        try expect(lead?.email == "jane@example.test", "email came from the wrong column")
        try expect(lead?.phone == "", "a substring header filled the phone")
    }

    static func csvHeaderAliases() throws {
        let (store, directory) = try freshStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("aliases.csv")
        try "Customer Name,E-mail,Phone Number,Quote Amount\nAlex Roy,alex@example.test,514-555-0100,$1200\n".write(to: file, atomically: true, encoding: .utf8)
        try expect(try store.importCSV(from: file) == 1, "alias-header CSV did not import one lead")
        let lead = store.leads.first
        try expect(lead?.name == "Alex Roy" && lead?.email == "alex@example.test" && lead?.phone == "514-555-0100" && lead?.quoteAmount == 1_200, "known alternative headers were not mapped")
    }

    // MARK: - LeadGen schema

    static func leadGenSchemaVersion() throws {
        let (store, directory) = try freshStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("v2.json")
        try "[{\"schema_version\":\"leadgen.event.v2\",\"email\":\"lead@example.test\"}]".write(to: file, atomically: true, encoding: .utf8)
        try expectImportError(422) { try store.importLeadGenJSON(from: file) }
        try expect(store.leads.isEmpty, "unsupported LeadGen schema still imported a lead")
        try "[{\"schema_version\":\"leadgen.event.v1\",\"email\":\"lead@example.test\"}]".write(to: file, atomically: true, encoding: .utf8)
        try expect(try store.importLeadGenJSON(from: file) == 1, "supported LeadGen schema did not import")
    }

    static func leadGenWrongTypes() throws {
        let (store, directory) = try freshStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("types.json")
        try "[{\"email\":\"lead@example.test\",\"fit_score\":\"high\"}]".write(to: file, atomically: true, encoding: .utf8)
        var threw = false
        do { _ = try store.importLeadGenJSON(from: file) } catch { threw = true }
        try expect(threw, "wrongly typed LeadGen field was silently accepted")
        try expect(store.leads.isEmpty, "wrongly typed LeadGen payload imported a lead")
    }

    // MARK: - Endpoint secrets

    static func endpointStripsSecrets() throws {
        let (store, _) = try freshStore()
        store.setEndpoint("https://svc-user:pa55word-value@api.example.test/v1?token=abcdef123456&region=ca", for: .twenty)
        let stored = store.endpoint(for: .twenty)
        try expect(!stored.contains("pa55word-value") && !stored.contains("svc-user"), "userinfo was persisted")
        try expect(!stored.contains("abcdef123456"), "token query value was persisted")
        try expect(stored.contains("api.example.test/v1") && stored.contains("region=ca"), "non-secret URL parts were lost")
        let onDisk = try String(contentsOf: store.storageURL, encoding: .utf8)
        try expect(!onDisk.contains("pa55word-value") && !onDisk.contains("abcdef123456"), "secret reached workspace.json")
    }

    static func endpointStripsTokenValues() throws {
        let (store, _) = try freshStore()
        store.setEndpoint("https://api.example.test/hook?x=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLXZhbHVl&page=2", for: .leadgen)
        let stored = store.endpoint(for: .leadgen)
        try expect(!stored.contains("eyJhbGciOiJIUzI1NiJ9"), "JWT-looking query value was persisted")
        try expect(stored.contains("page=2"), "non-secret query item was lost")
    }

    static func endpointScrubsOnLoad() throws {
        let directory = try tempDir()
        let file = directory.appendingPathComponent("workspace.json")
        var workspace = PersistentWorkspace()
        workspace.connectorEndpoints = [SyncTarget.pharos.rawValue: "https://ops:hunter2-secret@scan.example.test/api?api_key=zzz999"]
        try JSONEncoder().encode(workspace).write(to: file)
        let store = AppStore(storageURL: file)
        let stored = store.endpoint(for: .pharos)
        try expect(!stored.contains("hunter2-secret") && !stored.contains("zzz999"), "legacy secret survived load")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        try expect(!onDisk.contains("hunter2-secret") && !onDisk.contains("zzz999"), "legacy secret was not scrubbed from disk")
    }

    // MARK: - Reset

    static func resetRequiresConfirmation() throws {
        let (store, _) = try freshStore()
        var lead = Lead.blank(); lead.name = "Keep Me"; store.add(lead)
        var threw = false
        do { _ = try store.resetAll(confirmed: false) } catch { threw = true }
        try expect(threw, "unconfirmed reset did not throw")
        try expect(store.leads.count == 1, "unconfirmed reset erased data")
    }

    static func resetWritesBackup() throws {
        let (store, directory) = try freshStore()
        var lead = Lead.blank(); lead.name = "Backed Up"; store.add(lead)
        _ = try store.resetAll(confirmed: true)
        try expect(store.leads.isEmpty, "confirmed reset did not erase the workspace")
        let backups = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("workspace-backup-") && $0.pathExtension == "json" }
        try expect(backups.count == 1, "expected one timestamped backup, found \(backups.count)")
        guard let backup = backups.first else { return }
        try expect(backup.lastPathComponent.range(of: #"^workspace-backup-\d{8}-\d{6}"#, options: .regularExpression) != nil, "backup name is not timestamped")
        try expect(try mode(backup) == 0o600, "backup mode is \(String(try mode(backup), radix: 8)), expected 600")
        let restored = try JSONDecoder().decode(PersistentWorkspace.self, from: Data(contentsOf: backup))
        try expect(restored.leads.count == 1, "backup does not contain the pre-reset leads")
    }
}
