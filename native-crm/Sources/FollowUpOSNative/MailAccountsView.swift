import AuthenticationServices
import SwiftUI

/// System-browser Google sign-in. ControlWard never sees the password; only the code returns.
@MainActor
final class GoogleWebAuthorizer: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { continuation.resume(throwing: MailIntakeError.cancelled) }
                else { continuation.resume(throwing: MailIntakeError.signInFailed) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: MailIntakeError.signInFailed) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

struct MailAccountsSection: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var mail: MailIntakeController
    @State private var clientDraft = ""
    @State private var clientMessage: String?
    @State private var authorizer = GoogleWebAuthorizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Mail accounts")
            Text("Live intake of message metadata (subject, sender, recipients, date) into the Local review inbox. Read-only Gmail access; bodies are never fetched. Sign-ins use your browser and are stored in the macOS Keychain. Refreshes every 10 minutes while ControlWard is open.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Google OAuth client ID (…apps.googleusercontent.com)", text: $clientDraft).textFieldStyle(.roundedBorder)
                Button("Save") {
                    do { try mail.saveClientID(clientDraft); clientMessage = "Client ID saved." }
                    catch { clientMessage = error.localizedDescription }
                }
            }
            if let clientMessage { Text(clientMessage).font(.caption) }
            ForEach(MailAccount.all) { account in
                HStack(spacing: 12) {
                    Image(systemName: account.isSignIn ? "envelope.badge" : "arrow.turn.down.right").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email).font(.headline)
                        Text(account.isSignIn ? mail.state(account).label
                             : "Forwarded into \(account.forwardsInto ?? ""); labelled by recipient. \(mail.state(account).label)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.isSignIn {
                        if mail.tokens.exists(account.email) {
                            Button("Refresh") { Task { await mail.refresh(account, store: store) } }
                            Button("Disconnect", role: .destructive) { mail.disconnect(account) }
                        } else {
                            Button("Connect") {
                                Task { await mail.connect(account, store: store) { try await authorizer.authorize($0, callbackScheme: $1) } }
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .crmCard()
        .onAppear { clientDraft = mail.clientID }
    }
}

/// Compact status strip for the Email page.
struct MailIntakeStatusBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var mail: MailIntakeController
    var body: some View {
        HStack(spacing: 10) {
            ForEach(MailAccount.signIns) { account in
                Label("\(account.email): \(mail.state(account).label)", systemImage: "envelope").font(.caption).lineLimit(1)
            }
            Spacer()
            Button("Refresh mail") { Task { await mail.refreshAll(store: store) } }.disabled(!mail.anyConnected)
        }
    }
}
