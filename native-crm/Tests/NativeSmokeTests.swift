import Foundation

enum SmokeTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

@main
@MainActor
struct NativeSmokeTests {
    static func main() async throws {
        guard WorkspaceModuleTests.run() else { throw SmokeTestFailure.failed("Workspace module policy tests failed") }
        guard OverviewModelTests.run() else { throw SmokeTestFailure.failed("Overview model tests failed") }
        guard ControlWardTests.run() else { throw SmokeTestFailure.failed("ControlWard workflow tests failed") }
        let securityPassed = SecurityTests.run()
        let integrationPassed = await IntegrationTests.run()
        let leadInboxPassed = await LeadInboxTests.run()
        let gapsPassed = await GapAnalysisTests.run()
        let kairosPassed = await KairosTests.run()
        let mailPassed = await MailIntakeTests.run()
        let buildInfoPassed = BuildInfoTests.run()
        let discoveryPassed = await DiscoveryTests.run()
        let gtmPassed = GTMTests.run()
        let csvPassed = CSVImportTests.run()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("followupos-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("workspace.json")

        let store = AppStore(storageURL: storage)
        store.createWorkspace(name: "Martin Studio", industry: "Consulting")

        var won = Lead.blank()
        won.name = "Won Customer"
        won.status = .won
        won.quoteAmount = 1_200
        won.nextFollowUp = nil
        store.add(won)

        var open = Lead.blank()
        open.name = "Open Customer"
        open.status = .quoteSent
        open.quoteAmount = 800
        store.add(open)

        let reloaded = AppStore(storageURL: storage)
        try expect(reloaded.business.name == "Martin Studio", "business profile did not persist")
        try expect(reloaded.leads.count == 2, "lead count did not persist")
        try expect(reloaded.dollarsWon == 1_200, "won revenue metric is incorrect")
        try expect(reloaded.activePipeline == 800, "active pipeline metric is incorrect")
        try expect(reloaded.closeRate == 100, "close rate is incorrect")

        var company = Company()
        company.name = "Acme Builders"
        company.industry = "Construction"
        store.add(company)
        var contact = Contact()
        contact.firstName = "Alex"
        contact.lastName = "Builder"
        contact.companyID = company.id
        store.add(contact)
        var opportunity = Opportunity()
        opportunity.name = "Kitchen project"
        opportunity.amount = 4_000
        opportunity.companyID = company.id
        opportunity.contactID = contact.id
        opportunity.stage = .proposal
        store.add(opportunity)
        var task = CRMTask()
        task.title = "Send proposal"
        task.opportunityID = opportunity.id
        store.add(task)
        var note = CRMNote()
        note.title = "Discovery notes"
        note.body = "Customer prefers a spring start."
        note.contactID = contact.id
        store.add(note)
        let entityReload = AppStore(storageURL: storage)
        try expect(entityReload.companies.count == 1, "company did not persist")
        try expect(entityReload.contacts.first?.companyID == company.id, "contact relationship did not persist")
        try expect(entityReload.opportunities.first?.contactID == contact.id, "opportunity relationship did not persist")
        try expect(entityReload.tasks.first?.opportunityID == opportunity.id, "task relationship did not persist")
        try expect(entityReload.notes.first?.contactID == contact.id, "note relationship did not persist")

        var cadenceLead = Lead.blank()
        cadenceLead.name = "Cadence Customer"
        store.add(cadenceLead)
        store.markMessageSent(on: &cadenceLead, message: "First message")
        try expect(cadenceLead.sequenceStage == 1, "first cadence stage is incorrect")
        try expect(cadenceLead.history.count == 1, "first follow-up history was not logged")
        try expect(
            cadenceLead.nextFollowUp == CalendarCRM.addDays(1, to: CalendarCRM.dayString()),
            "first follow-up did not schedule at one day"
        )
        store.markMessageSent(on: &cadenceLead, message: "Second message")
        try expect(
            cadenceLead.nextFollowUp == CalendarCRM.addDays(3, to: CalendarCRM.dayString()),
            "second follow-up did not schedule at three days"
        )

        let csv = "name,email,service,quote\n\"Smith, Jane\",jane@example.com,Renovation,2500\n"
        let csvURL = directory.appendingPathComponent("leads.csv")
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        try expect(try store.importCSV(from: csvURL) == 1, "CSV import count is incorrect")
        try expect(store.leads.first?.name == "Smith, Jane", "quoted CSV name was not preserved")
        try expect(store.leads.first?.quoteAmount == 2_500, "CSV quote amount is incorrect")

        var signal = Signal()
        signal.title = "High-intent website inquiry"
        signal.source = .website
        signal.fitScore = 90
        signal.intentScore = 80
        signal.priority = 85
        signal.nextAction = "Route to Martin"
        store.add(signal)
        var audit = BilingualAudit()
        audit.name = "Pilot language audit"
        audit.sampleSizeFR = 20
        audit.sampleSizeEN = 20
        audit.french.escalation = 60
        audit.english.escalation = 90
        store.add(audit)
        let opsReload = AppStore(storageURL: storage)
        try expect(opsReload.signals.first?.priority == 85, "signal did not persist")
        try expect(opsReload.audits.first?.languageGap ?? 0 > 0, "BAEA language gap was not computed")
        try expect(opsReload.audits.first?.priority == "High", "BAEA priority band is incorrect")

        var due = Lead.blank()
        due.name = "Due Automation Lead"
        due.nextFollowUp = CalendarCRM.addDays(-1, to: CalendarCRM.dayString())
        store.add(due)
        try expect(store.runAutomations() >= 2, "local automations did not create expected actions")
        try expect(store.tasks.contains { $0.leadID == due.id }, "due follow-up automation did not create a linked task")
        try expect(store.signals.contains { $0.title == signal.title && $0.status == .qualified }, "high-intent signal was not qualified")

        let leadGenJSON = """
        [{"event_id":"evt_test_1","captured_at":"2026-08-30T12:00:00Z","raw_identity":{"email":"lead@example.com","first_name":"Lead","last_name":"Gen","company_name_raw":"Signal Co"},"fit_score":80,"intent_score":90,"composite_score":85}]
        """
        let jsonURL = directory.appendingPathComponent("leadgen.json")
        try leadGenJSON.write(to: jsonURL, atomically: true, encoding: .utf8)
        try expect(try store.importLeadGenJSON(from: jsonURL) == 1, "LeadGen JSON import count is incorrect")
        try expect(store.leads.contains { $0.email == "lead@example.com" }, "LeadGen identity was not imported")
        try expect(store.signals.contains { $0.evidence.contains("leadgen.json") && $0.priority == 85 }, "LeadGen signal provenance was not preserved")

        let baeaCSV = "audit,client,language,disclosure,escalation,context_transfer,tone,hallucinations,sample_size\nPilot export,Demo Co,FR,80,60,70,90,95,20\nPilot export,Demo Co,EN,90,90,90,90,95,20\n"
        let baeaURL = directory.appendingPathComponent("baea-export.csv")
        try baeaCSV.write(to: baeaURL, atomically: true, encoding: .utf8)
        try expect(try store.importBAEACSV(from: baeaURL) == 1, "BAEA CSV import count is incorrect")
        try expect(store.audits.contains { $0.name == "Pilot export" && $0.sampleSizeFR == 20 && $0.sampleSizeEN == 20 }, "BAEA CSV scores were not imported")

        let xlsxRoot = directory.appendingPathComponent("xlsx-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: xlsxRoot.appendingPathComponent("xl/worksheets", isDirectory: true), withIntermediateDirectories: true)
        let sharedXML = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>audit</t></si><si><t>client</t></si><si><t>language</t></si><si><t>escalation</t></si><si><t>sample_size</t></si><si><t>Workbook audit</t></si><si><t>Demo Co</t></si><si><t>FR</t></si><si><t>70</t></si><si><t>20</t></si></sst>"
        let sheetXML = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c><c r=\"C1\" t=\"s\"><v>2</v></c><c r=\"D1\" t=\"s\"><v>3</v></c><c r=\"E1\" t=\"s\"><v>4</v></c></row><row r=\"2\"><c r=\"A2\" t=\"s\"><v>5</v></c><c r=\"B2\" t=\"s\"><v>6</v></c><c r=\"C2\" t=\"s\"><v>7</v></c><c r=\"D2\" t=\"s\"><v>8</v></c><c r=\"E2\" t=\"s\"><v>9</v></c></row></sheetData></worksheet>"
        try sharedXML.write(to: xlsxRoot.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)
        try sheetXML.write(to: xlsxRoot.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        let xlsxURL = directory.appendingPathComponent("baea-fixture.xlsx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.arguments = ["-qr", xlsxURL.path, "xl"]; zip.currentDirectoryURL = xlsxRoot; try zip.run(); zip.waitUntilExit()
        try expect(try store.importBAEAXLSX(from: xlsxURL) == 1, "BAEA XLSX import count is incorrect")
        try expect(store.audits.contains { $0.name == "Workbook audit" && $0.sampleSizeFR == 20 }, "BAEA XLSX scores were not imported")
        try expect(store.audits.contains { $0.transcripts.contains { $0.language == .french } }, "BAEA transcript evidence was not retained")
        let canonicalWorkbook = URL(fileURLWithPath: "/Users/pharos_ai/Downloads/BAEA/PHAROS-BAEA-WKBK-v1.0_Scoring_Workbook.xlsx")
        if FileManager.default.fileExists(atPath: canonicalWorkbook.path) {
            try expect(try store.importBAEAXLSX(from: canonicalWorkbook) == 1, "canonical BAEA workbook was not imported")
            try expect(store.audits.contains { $0.sampleSizeFR > 0 && $0.sampleSizeEN > 0 }, "canonical BAEA workbook did not yield both languages")
        }

        let exchangeURL = directory.appendingPathComponent("contextward-exchange.json")
        try store.exportExchange(to: exchangeURL)
        let exchangeData = try Data(contentsOf: exchangeURL)
        let exchange = try JSONDecoder().decode(WorkspaceExchange.self, from: exchangeData)
        try expect(exchange.schemaVersion == "contextward.exchange.v1", "exchange schema version is incorrect")
        try expect(exchange.signals.contains { $0.evidence.contains("leadgen.json") }, "exchange omitted signal provenance")
        let importedWorkspaceURL = directory.appendingPathComponent("imported-workspace.json")
        let importedStore = AppStore(storageURL: importedWorkspaceURL)
        try expect(try importedStore.importExchange(from: exchangeURL) > 0, "exchange merge imported no records")
        try expect(importedStore.signals.contains { $0.evidence.contains("leadgen.json") }, "exchange merge lost signal provenance")
        store.queueSync(to: .twenty)
        let syncReload = AppStore(storageURL: storage)
        try expect(syncReload.syncJobs.first?.target == .twenty && syncReload.syncJobs.first?.status == "queued", "sync intent did not persist")
        try expect(store.stageSyncOutbox() == 1, "sync outbox was not staged")
        try expect(store.syncJobs.first?.status == "staged", "sync job was not marked staged")
        try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outbox/\(SyncTarget.twenty.rawValue)-\(store.syncJobs.first!.id.uuidString).json").path), "sync outbox package was not written")
        let manifest = store.syncManifest(for: store.syncJobs.first!)
        try expect(manifest.idempotencyKey.hasPrefix("ctx_"), "sync manifest lacks idempotency key")
        try expect(manifest.entityCounts["signals"] == store.signals.count, "sync manifest counts are incorrect")

        var risky = Lead.blank()
        risky.name = "Risky Notes"
        risky.notes = "temporary api key should be removed"
        store.add(risky)
        try expect(store.runLocalExposureScan() > 0, "local exposure scan found no expected finding")
        try expect(store.exposureFindings.contains { $0.severity == .high && $0.recordID == risky.id }, "sensitive-looking note finding was not recorded")
        store.setEndpoint("https://twenty.example.test/api", for: .twenty)
        let endpointReload = AppStore(storageURL: storage)
        try expect(endpointReload.endpoint(for: .twenty) == "https://twenty.example.test/api", "connector endpoint did not persist")

        let identifiers = [Lead().id, FollowUpEvent(date: CalendarCRM.dayString(), message: "Test").id]
        for identifier in identifiers {
            let value = identifier.uuidString
            try expect(value[value.index(value.startIndex, offsetBy: 14)] == "4", "generated identifier is not UUID v4")
        }

        print("PASS: persistence, metrics, cadence, CSV import, operations integration, and UUID v4")
        try expect(securityPassed, "security tests failed")
        try expect(integrationPassed, "integration tests failed")
        try expect(leadInboxPassed, "lead inbox tests failed")
        try expect(gapsPassed, "gap analysis tests failed")
        try expect(kairosPassed, "Kairos tests failed")
        try expect(mailPassed, "Mail intake tests failed")
        try expect(buildInfoPassed, "Build info tests failed")
        try expect(discoveryPassed, "discovery tests failed")
        try expect(csvPassed, "CSV import tests failed")
        try expect(gtmPassed, "account intelligence tests failed")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SmokeTestFailure.failed(message) }
    }
}
