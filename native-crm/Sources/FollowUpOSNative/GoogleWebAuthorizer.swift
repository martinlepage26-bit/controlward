import AppKit
import AuthenticationServices

/// System-browser Google sign-in. ControlWard never sees the password; only the code returns.
@MainActor
final class GoogleWebAuthorizer: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Builds the web sign-in session. Production uses ASWebAuthenticationSession; tests inject a fake
    /// that fires the completion from a background queue, exactly like AuthenticationServices does.
    /// The completion is @Sendable on purpose: a closure written inline in authorize() that touches
    /// main-actor state no longer compiles, which is the regression that trapped at runtime.
    typealias SessionFactory = @MainActor (URL, String, @escaping @Sendable (URL?, Error?) -> Void) -> any WebAuthSession

    private var session: (any WebAuthSession)?
    private let makeSession: SessionFactory

    init(makeSession: @escaping SessionFactory = GoogleWebAuthorizer.systemSession) {
        self.makeSession = makeSession
        super.init()
    }

    static let systemSession: SessionFactory = { url, scheme, completion in
        ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
    }

    var hasActiveSession: Bool { session != nil }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let gate = GoogleWebAuthorizer.ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            // The completion handler is built outside main-actor isolation: AuthenticationServices
            // calls it on an XPC queue, and a main-actor closure there traps at runtime (Swift 6).
            let session = makeSession(
                url, callbackScheme,
                GoogleWebAuthorizer.makeCompletion(gate) { [weak self] in
                    Task { @MainActor in self?.session = nil }
                })
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                gate.resume(.failure(MailIntakeError.signInFailed))
            }
        }
    }

    /// Resumes a continuation exactly once, from any thread.
    final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        func set(_ c: CheckedContinuation<URL, Error>) { lock.lock(); continuation = c; lock.unlock() }
        func resume(_ result: Result<URL, Error>) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(with: result)
        }
    }

    nonisolated static func result(callback: URL?, error: Error?) -> Result<URL, Error> {
        if let callback { return .success(callback) }
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return .failure(MailIntakeError.cancelled) }
        return .failure(MailIntakeError.signInFailed)
    }

    nonisolated static func makeCompletion(_ gate: ResumeOnce, onDone: @escaping @Sendable () -> Void) -> @Sendable (URL?, Error?) -> Void {
        { callback, error in
            gate.resume(result(callback: callback, error: error))
            onDone()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let pick: @MainActor () -> ASPresentationAnchor = { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? ASPresentationAnchor() }
        if Thread.isMainThread { return MainActor.assumeIsolated { pick() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { pick() } }
    }
}

/// The parts of ASWebAuthenticationSession that GoogleWebAuthorizer uses.
@MainActor
protocol WebAuthSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
}

extension ASWebAuthenticationSession: WebAuthSession {}
