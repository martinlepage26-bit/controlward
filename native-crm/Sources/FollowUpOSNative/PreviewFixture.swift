#if DEBUG && CONTEXTWARD_ACCEPTANCE
import Foundation

/// Errors and dependencies for the isolated, offline acceptance preview.
enum PreviewIsolationError: LocalizedError {
    case externalNetworkDisabled

    var errorDescription: String? {
        "External network access is disabled in the isolated preview."
    }
}

struct PreviewNoNetworkHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw PreviewIsolationError.externalNetworkDisabled
    }
}

struct PreviewNoNetworkLeadTransport: LeadTransport {
    func send(_ request: URLRequest) async throws -> LeadHTTPResponse {
        throw PreviewIsolationError.externalNetworkDisabled
    }
}

/// Preview-only settings storage. It has no UserDefaults/CFPreferences bridge.
@MainActor
final class InMemoryPreviewPreferences: MailPreferences {
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

/// Compiled only into the isolated preview, never the release app.
@MainActor enum PreviewFixture {
    private static var prepared = false
    private static var isolatedPreferences: InMemoryPreviewPreferences?
    private static let previewClientID = "offline-preview.invalid.apps.googleusercontent.com"

    static func prepare() {
        guard !prepared else { return }
        let root = StorageLocation.directory
        guard FileManager.default.fileExists(atPath: root.path),
              !FileManager.default.fileExists(atPath: StorageLocation.workspaceFile.path) else {
            fatalError("The isolated preview storage root is unavailable or not fresh.")
        }

        let preferences = InMemoryPreviewPreferences()
        let independentPreferences = InMemoryPreviewPreferences()
        guard independentPreferences.string(forKey: GoogleOAuthConfig.defaultsKey) == nil else {
            fatalError("Preview preference instances must not share persisted state.")
        }
        // This synthetic value exists only in the preview's dictionary; sign-in is disabled below.
        preferences.set(previewClientID, forKey: GoogleOAuthConfig.defaultsKey)
        guard preferences.string(forKey: GoogleOAuthConfig.defaultsKey) == previewClientID else {
            fatalError("Could not initialize in-memory preview preferences.")
        }
        isolatedPreferences = preferences

        var workspace = PersistentWorkspace()
        workspace.business.name = "Synthetic review workspace"
        workspace.business.industry = "Consulting"
        var company = Company(); company.name = "Érable Studio"; company.domain = "erable.example.test"; company.industry = "Design"
        workspace.companies = [company]
        var contact = Contact(); contact.firstName = "Camille"; contact.lastName = "Example"; contact.email = "camille@example.test"; contact.companyID = company.id
        workspace.contacts = [contact]
        var task = CRMTask(); task.title = "Review project brief"; task.details = "Synthetic fixture — no client data"; task.dueDate = "2026-10-15"; task.companyID = company.id
        workspace.tasks = [task]
        var opportunity = Opportunity(); opportunity.name = "Synthetic onboarding review"; opportunity.stage = .proposal; opportunity.companyID = company.id; opportunity.amount = 2400
        workspace.opportunities = [opportunity]
        var lead = Lead(); lead.name = "Alex Example"; lead.email = "alex@example.test"; lead.company = company.name; lead.nextFollowUp = "2026-10-16"
        workspace.leads = [lead]
        var note = CRMNote(); note.title = "Review checklist"; note.body = "All displayed records are synthetic."; note.companyID = company.id
        workspace.notes = [note]
        var signal = Signal(); signal.title = "GAP fixture: clearer handoffs"; signal.source = .imported; signal.sourceID = "gap:synthetic-1"; signal.sourceActive = true; signal.evidence = "Synthetic research fixture for interface review."; signal.nextAction = "Review before creating project work"; signal.priority = 70; signal.fitScore = 60; signal.intentScore = 40
        workspace.signals = [signal]
        workspace.controlWard.mail = [MailMetadata(sourceID: "synthetic-message-1", subject: "Project review follow-up", sender: "camille@example.test", recipient: "owner@example.test", receivedAt: "2026-10-17T09:00:00Z", provider: "synthetic", accountID: "preview", synthetic: true)]
        workspace.activity = [ActivityEvent(kind: "preview", message: "Synthetic preview workspace created.")]
        do {
            try SecureFiles.writePrivate(JSONEncoder().encode(workspace), to: StorageLocation.workspaceFile)
            guard FileManager.default.fileExists(atPath: StorageLocation.workspaceFile.path) else {
                fatalError("Could not verify the isolated preview workspace.")
            }
        } catch {
            fatalError("Could not create the isolated preview fixture: \(error.localizedDescription)")
        }
        prepared = true
    }

    static func makeStore() -> AppStore {
        prepare()
        let store = AppStore(storageURL: StorageLocation.workspaceFile,
                             secrets: InMemorySecretStore(),
                             transport: PreviewNoNetworkHTTPTransport())
        guard store.storageURL.standardizedFileURL == StorageLocation.workspaceFile.standardizedFileURL,
              store.secrets is InMemorySecretStore,
              store.transport is PreviewNoNetworkHTTPTransport,
              SyncTarget.allCases.allSatisfy({ store.endpoint(for: $0).isEmpty }) else {
            fatalError("Could not inject every isolated preview store and transport.")
        }
        return store
    }

    static func makeMailController() -> MailIntakeController {
        prepare()
        guard let isolatedPreferences else {
            fatalError("Isolated preview preferences were not initialized.")
        }
        let controller = MailIntakeController(tokens: InMemoryMailTokenStore(),
                                              transport: PreviewNoNetworkHTTPTransport(),
                                              preferences: isolatedPreferences)
        guard controller.tokens is InMemoryMailTokenStore,
              controller.transport is PreviewNoNetworkHTTPTransport,
              controller.clientID == previewClientID,
              MailAccount.all == MailAccount.preview else {
            fatalError("Could not inject isolated mail accounts, credentials, settings and transport.")
        }
        return controller
    }
}
#endif
