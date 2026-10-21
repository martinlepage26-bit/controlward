import AuthenticationServices
import SwiftUI

struct MailAccountsSection: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var mail: MailIntakeController
    @State private var clientDraft = ""
    @State private var clientMessage: String?
    @State private var authorizer = GoogleWebAuthorizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.open").foregroundStyle(CWPalette.goldIcon)
                Text("Mail accounts").font(.system(size: 15, weight: .semibold)).foregroundStyle(CWPalette.ink)
            }
            Text("Refresh saves subject, sender, recipients, and date. Opening a message loads the full body from the mailbox and does not store it here. Reply, forward, drafts, archive, and Trash use the Gmail connection; sending and Trash ask you to confirm. Sign-ins use your browser. Refresh tokens stay in the macOS Keychain. An older read-only sign-in needs Connect again before it can change mail. Refreshes every 10 minutes while ControlWard is open.")
                .font(.system(size: 11)).foregroundStyle(CWPalette.gray)
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
                    Image(systemName: account.isSignIn ? "envelope.badge" : "arrow.turn.down.right")
                        .foregroundStyle(CWPalette.goldIcon).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email).font(.system(size: 13, weight: .semibold)).foregroundStyle(CWPalette.ink)
                        Text(account.isSignIn ? mail.state(account).label
                             : "Forwarded into \(account.forwardsInto ?? ""); labelled by recipient. \(mail.state(account).label)")
                            .font(.system(size: 11)).foregroundStyle(stateColor(mail.state(account)))
                    }
                    Spacer()
                    if account.isSignIn {
                        if mail.tokens.exists(account.email) {
                            Button("Refresh") { Task { await mail.refresh(account, store: store) } }
                            Button("Disconnect", role: .destructive) { mail.disconnect(account) }
                        } else {
                            Button("Connect") {
                                Task { await mail.connect(account, store: store) { try await authorizer.authorize($0, callbackScheme: $1) } }
                            }.buttonStyle(.borderedProminent).tint(CWPalette.bronze)
                        }
                    }
                }
                .padding(.vertical, 6)
                if account != MailAccount.all.last { Divider().overlay(CWPalette.canvas) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cwCard(16)
        .onAppear { clientDraft = mail.clientID }
    }

    private func stateColor(_ state: MailAccountState) -> Color {
        switch state {
        case .failed: CWPalette.red
        case .synced, .idle: CWPalette.green
        case .syncing: CWPalette.blue
        case .notConnected: CWPalette.gray
        }
    }
}

/// Compact status strip for the Email page.
struct MailIntakeStatusBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var mail: MailIntakeController
    var body: some View {
        HStack(spacing: 10) {
            ForEach(MailAccount.signIns) { account in
                Label("\(account.email): \(mail.state(account).label)", systemImage: "envelope")
                    .font(.system(size: 11)).foregroundStyle(CWPalette.gray).lineLimit(1)
            }
            Spacer()
            Button("Refresh mail") { Task { await mail.refreshAll(store: store) } }.tint(CWPalette.bronze).disabled(!mail.anyConnected)
        }
    }
}
