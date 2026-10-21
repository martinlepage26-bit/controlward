import AppKit
import SwiftUI

enum LiveMailSession {
    @MainActor
    static func connector(for message: MailMetadata, intake: MailIntakeController) async -> any MailboxConnecting {
        let aliases = Dictionary(uniqueKeysWithValues: MailAccount.all.compactMap { account -> (String, String)? in
            guard let owner = account.forwardsInto else { return nil }
            return (account.email, owner)
        })
        let signIns = Set(MailAccount.signIns.map(\.email))
        let connected = Set(signIns.filter { intake.tokens.exists($0) })
        let route = MailConnectorRouting.route(
            sourceID: message.sourceID, provider: message.provider, synthetic: message.synthetic,
            accountID: message.accountID, signIns: signIns, aliases: aliases, connected: connected)
        switch route {
        case .disabled(let provider, let reason):
            return DisabledMailbox(providerID: provider, accountID: message.accountID, reason: reason)
        case .gmail(let owner, let provider):
            do {
                let engine = MailIntakeEngine(config: try intake.config(), tokens: intake.tokens, transport: intake.transport)
                let token = try await engine.accessToken(for: owner)
                let transport = intake.transport
                let http = ClosureMailHTTP { request in
                    let response = try await transport.send(request)
                    return MailHTTPResponse(status: response.status, body: response.body)
                }
                let scopes = await GmailMailboxClient(token: token, from: owner, http: http).grantedScopes()
                return GmailMailboxConnector(providerID: provider, accountID: owner, scopes: scopes, token: token, from: owner, http: http)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "The mailbox connection is not available."
                return DisabledMailbox(providerID: provider, accountID: owner, reason: reason)
            }
        }
    }
}

@MainActor
final class MailActionModel: ObservableObject {
    @Published var body: MailMessageBody?
    @Published var support: [MailActionSupport] = []
    @Published var status: String?
    @Published var loading = false
    private var connector: (any MailboxConnecting)?

    func load(message: MailMetadata, intake: MailIntakeController) async {
        loading = true
        status = nil
        body = nil
        let connector = await LiveMailSession.connector(for: message, intake: intake)
        self.connector = connector
        support = connector.supports()
        do {
            body = try await connector.fetchBody(sourceID: message.sourceID)
        } catch {
            status = error.localizedDescription
        }
        loading = false
    }

    /// Runs a command the user already confirmed when the action requires it.
    /// Returns an error string and leaves the mailbox unchanged when the connector refuses.
    func perform(_ command: MailCommand, store: AppStore, localID: UUID) async -> String? {
        guard let connector else { return "No mailbox connector is available for this message." }
        do {
            _ = try await connector.perform(command)
            support = connector.supports()
            if command.action == .trash {
                do { try store.forgetMailMetadata(id: localID) }
                catch { status = "Moved to Trash in the mailbox. The local metadata row could not be removed." ; return nil }
                status = "Moved to Trash. The message is still in the mailbox Trash and was not erased."
            } else if command.action.sends {
                status = "Sent."
            } else if command.action == .editDraft {
                status = "Draft saved. Nothing was sent."
            } else if command.action == .archive {
                status = "Archived."
            } else if command.action == .markRead {
                status = "Marked read."
            } else if command.action == .markUnread {
                status = "Marked unread."
            }
            return nil
        } catch {
            let message = error.localizedDescription
            status = message
            return message
        }
    }
}

struct MailComposeRequest: Identifiable {
    var action: MailboxAction
    var draft: MailCompose
    var id: String { action.rawValue }
}

struct MailActionBar: View {
    var support: [MailActionSupport]
    var run: (MailboxAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(support) { item in
                    Button(item.action.title) { run(item.action) }
                        .disabled(!item.enabled)
                        .help(item.enabled ? item.action.help : item.reason)
                        .accessibilityHint(item.enabled ? item.action.help : item.reason)
                }
            }
            let disabled = support.filter { !$0.enabled && !$0.reason.isEmpty }
            if !disabled.isEmpty {
                Text(disabled.map { "\($0.action.title): \($0.reason)" }.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MailComposeSheet: View {
    var action: MailboxAction
    var onCancel: () -> Void
    var onSave: @MainActor (MailCompose) async -> String?
    var onSend: @MainActor (MailCompose) async -> String?
    @State private var draft: MailCompose
    @State private var confirmSend = false
    @State private var error: String?

    init(action: MailboxAction, initial: MailCompose, onCancel: @escaping () -> Void, onSave: @escaping @MainActor (MailCompose) async -> String?, onSend: @escaping @MainActor (MailCompose) async -> String?) {
        self.action = action
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSend = onSend
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action.title).font(.title2.bold())
            Text(action == .editDraft ? "Saving a draft does not send it." : "Nothing is sent until you confirm.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("To", text: recipients(\.to))
            TextField("Cc", text: recipients(\.cc))
            TextField("Subject", text: $draft.subject)
            TextEditor(text: $draft.body)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(action.sends ? .defaultAction : .cancelAction)
                Spacer()
                if action == .editDraft {
                    Button("Save draft") {
                        Task {
                            if let failure = await onSave(draft) { error = failure }
                            else { onCancel() }
                        }
                    }
                } else {
                    Button("Send") { confirmSend = true }
                        .disabled(draft.to.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                        .help(draft.to.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? "Add a recipient before sending." : "Send this message. Nothing is sent until you confirm.")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .confirmationDialog("Send this message?", isPresented: $confirmSend, titleVisibility: .visible) {
            ForEach(MailSendConfirmation.buttons) { button in
                sendConfirmationButton(button)
            }
        } message: {
            Text("Nothing is sent until you confirm. Cancel leaves the mailbox unchanged.")
        }
    }

    @ViewBuilder
    private func sendConfirmationButton(_ button: MailSendDialogButton) -> some View {
        switch button.kind {
        case .cancel:
            if button.isDefault {
                Button(button.title, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(button.title, role: .cancel) {}
            }
        case .send:
            if button.isDefault {
                Button(button.title) {
                    Task {
                        if let failure = await onSend(draft) { error = failure }
                        else { onCancel() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(button.title) {
                    Task {
                        if let failure = await onSend(draft) { error = failure }
                        else { onCancel() }
                    }
                }
            }
        }
    }

    private func recipients(_ keyPath: WritableKeyPath<MailCompose, [String]>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath].joined(separator: ", ")
        } set: { text in
            draft[keyPath: keyPath] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}

/// Shows the sanitized body at its full height so the detail scroll view can reach the end.
struct MailHTMLView: NSViewRepresentable {
    var html: String

    func makeNSView(context: Context) -> MailBodyTextView {
        // macOS 15 text views use TextKit 2 unless a layout manager is attached first.
        // TextKit 2 leaves layoutManager nil, so a default height would clip the body.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let text = MailBodyTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.importsGraphics = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        return text
    }

    func updateNSView(_ text: MailBodyTextView, context: Context) {
        text.textStorage?.setAttributedString(Self.attributed(html))
        text.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MailBodyTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 480, 1)
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else {
            return CGSize(width: width, height: 40)
        }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let height = max(40, ceil(used.height) + nsView.textContainerInset.height * 2 + 8)
        return CGSize(width: width, height: height)
    }

    private static func attributed(_ html: String) -> NSAttributedString {
        let data = Data(html.utf8)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: NSNumber(value: String.Encoding.utf8.rawValue),
            .timeout: NSNumber(value: 1),
        ]
        if let parsed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return parsed
        }
        return NSAttributedString(string: MailHTMLSanitizer.visibleText(html))
    }
}

final class MailBodyTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 40)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(40, ceil(used.height) + textContainerInset.height * 2 + 8))
    }
}
