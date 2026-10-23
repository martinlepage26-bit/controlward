import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LeadHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    /// Set by `GuardedLeadTransport` when the response arrives; the same instant is the audit line's `ts`.
    var fetchedAt = Date(timeIntervalSince1970: 0)
    /// The URL the body actually came from, when the transport knows it (after a redirect it differs from the request).
    var url: URL?
}

/// The only network seam of the lead pipeline. Foundation-only so it builds and tests on Linux too.
protocol LeadTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LeadHTTPResponse
}

/// Ephemeral session: no cookies and no URL cache, so fetched pages never land in a shared cache.
struct URLSessionLeadTransport: LeadTransport {
    /// Red stub: the default session follows redirects on its own.
    static let followsRedirects = true

    /// One ephemeral session for the process: no cookies, no cache. Creating and dropping a session per request
    /// crashes swift-corelibs-foundation on Linux (_MultiHandle over-release) and wastes connections on macOS.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> LeadHTTPResponse {
        let (data, response) = try await Self.session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { headers[String(describing: key).lowercased()] = String(describing: value) }
        return LeadHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

protocol LeadClock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async
}

struct SystemLeadClock: LeadClock {
    var now: Date { Date() }
    func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Why a request is made. Each purpose has its own hosts in icp.json (S3-R11).
enum FetchPurpose: Equatable, Sendable {
    case discovery
    case ownSite(domain: String)
    case watch
    case gmail
    case openData(id: String)

    var label: String {
        switch self {
        case .discovery: "discovery"
        case .ownSite: "own-site"
        case .watch: "watch"
        case .gmail: "gmail"
        case .openData(let id): "open-data:\(id)"
        }
    }
}

/// Every lead-pipeline request goes through here: allowlist, deny list, robots.txt, per-host rate limit,
/// the Loi 25 payload check, bot-challenge stop, and one CW-AUDIT line per request.
final class GuardedLeadTransport: @unchecked Sendable {
    struct RequestRecord: Equatable, Sendable {
        var url: String
        var host: String
        var method: String
        var purpose: String
        var result: String
        var isSend: Bool
    }

    let config: ICPConfig
    private let inner: any LeadTransport
    private let audit: any CWAuditSink
    private let clock: any LeadClock
    private let lock = NSLock()
    private var lastRequest: [String: Date] = [:]
    private var robots: [String: RobotsRules] = [:]
    private var challenged: Set<String> = []
    private var sensitive: Set<String> = []
    private var records: [RequestRecord] = []

    init(config: ICPConfig, inner: any LeadTransport, audit: any CWAuditSink, clock: any LeadClock = SystemLeadClock()) {
        self.config = config
        self.inner = inner
        self.audit = audit
        self.clock = clock
    }

    /// Backoff between retries uses the same clock as the per-host pacing, so tests see every wait.
    func backoff(seconds: Double) async { await clock.sleep(seconds: seconds) }

    /// Everything attempted, including refusals (which never reached the network).
    var requestLog: [RequestRecord] { lock.withLock { records } }
    var sendCount: Int { requestLog.filter { $0.isSend && $0.result == "ok" }.count }

    /// Values from fetched sites (names, emails, addresses, page text) that must never leave for a discovery host.
    func registerSensitive(_ values: [String]) {
        lock.withLock {
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.count >= 4 { sensitive.insert(trimmed) }
            }
        }
    }

    func fetch(_ url: URL, purpose: FetchPurpose, method: String = "GET", body: Data? = nil,
               headers: [String: String] = [:], maxBytes: Int? = nil) async throws -> LeadHTTPResponse {
        let host = url.host?.lowercased() ?? ""
        do {
            try admit(url, host: host, purpose: purpose, method: method, body: body)
            if case .ownSite = purpose { try await checkRobots(url, host: host) }
            await pace(host: host, purpose: purpose)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 20
            request.setValue(config.etiquette.userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            var response = try await inner.send(request)
            let receivedAt = clock.now
            response.fetchedAt = receivedAt
            lock.withLock { lastRequest[host] = receivedAt }
            if Self.isBotChallenge(response) {
                lock.withLock { _ = challenged.insert(host) }
                throw LeadPipelineRefusal(code: "refused:bot-challenge", detail: host)
            }
            let limit = maxBytes ?? config.etiquette.maxResponseBytes
            if response.body.count > limit { throw LeadPipelineRefusal(code: "refused:response-too-large") }
            log(url, method: method, purpose: purpose, result: (200..<300).contains(response.status) ? "ok" : "error:\(response.status)", at: receivedAt)
            return response
        } catch let refusal as LeadPipelineRefusal {
            log(url, method: method, purpose: purpose, result: refusal.code)
            throw refusal
        } catch {
            log(url, method: method, purpose: purpose, result: "error:network")
            throw error
        }
    }

    // MARK: - Admission

    /// Own-site host check (SSRF). Red stub: admits everything.
    static func ownSiteHostRefusal(_ url: URL) -> LeadPipelineRefusal? { nil }

    func admit(_ url: URL, host: String, purpose: FetchPurpose, method: String, body: Data?) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || (scheme == "http" && purpose != .gmail) else {
            throw LeadPipelineRefusal(code: "refused:scheme")
        }
        if config.isNeverFetch(host: host) { throw LeadPipelineRefusal(code: "refused:crawl-linkedin", detail: config.etiquette.linkedinNote) }
        if let denied = config.deniedHost(host) { throw LeadPipelineRefusal(code: "refused:denied-host", detail: denied.reason) }
        if lock.withLock({ challenged.contains(host) }) { throw LeadPipelineRefusal(code: "refused:bot-challenge", detail: "earlier challenge on \(host)") }
        if let disabled = config.disabledSource(forHost: host), !disabled.enabled {
            throw LeadPipelineRefusal(code: "refused:source-disabled:\(disabled.id)", detail: disabled.reason)
        }
        let allowed: Bool
        switch purpose {
        case .discovery: allowed = config.allowlist.discoveryHosts.contains(host)
        case .watch: allowed = config.allowlist.watchHosts.contains(host)
        case .gmail: allowed = config.allowlist.gmailHosts.contains(host)
        case .ownSite(let domain):
            let listed = config.allowlist.discoveryHosts + config.allowlist.watchHosts + config.allowlist.gmailHosts
            allowed = !domain.isEmpty && HostMatch.belongs(host, to: domain) && !listed.contains(host) && config.openDataSource(forHost: host) == nil
        case .openData(let id):
            guard let source = config.allowlist.openDataSources.first(where: { $0.id == id }), source.enabled, source.host == host else {
                throw LeadPipelineRefusal(code: "refused:open-data-source")
            }
            if url.query != nil || url.fragment != nil || source.deniedPathPrefixes.contains(where: { url.path.hasPrefix($0) })
                || !source.downloadUrls.contains(url.absoluteString) || method != "GET" {
                throw LeadPipelineRefusal(code: "refused:open-data-path", detail: "only the fixed download URLs")
            }
            allowed = true
        }
        guard allowed else { throw LeadPipelineRefusal(code: "refused:loi25-host", detail: host) }
        if purpose == .discovery { try scanDiscoveryPayload(url: url, body: body) }
    }

    /// Discovery hosts get category tags and coordinates only: no site content, names, emails, phones or postal codes.
    func scanDiscoveryPayload(url: URL, body: Data?) throws {
        let payload = ((url.query ?? "") + " " + (body.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
        let decoded = (payload.removingPercentEncoding ?? payload).replacingOccurrences(of: "+", with: " ").lowercased()
        let patterns = [
            "[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}",
            "\\b[abceghjklmnprstvxy][0-9][abceghjk-nprstv-z][ -]?[0-9][abceghjk-nprstv-z][0-9]\\b",
            "\\(?\\b[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}\\b"
        ]
        if patterns.contains(where: { decoded.range(of: $0, options: .regularExpression) != nil }) {
            throw LeadPipelineRefusal(code: "refused:loi25-payload", detail: "contact data in a discovery request")
        }
        let leaked = lock.withLock { sensitive.first { decoded.contains($0) } }
        if leaked != nil { throw LeadPipelineRefusal(code: "refused:loi25-payload", detail: "fetched-site content in a discovery request") }
    }

    // MARK: - robots.txt and pacing

    private func checkRobots(_ url: URL, host: String) async throws {
        var rules = lock.withLock { robots[host] }
        if rules == nil {
            var components = URLComponents()
            components.scheme = url.scheme
            components.host = url.host
            components.port = url.port
            components.path = "/robots.txt"
            var parsed = RobotsRules(groups: [])
            if let robotsURL = components.url {
                await pace(host: host, purpose: .ownSite(domain: host))
                var request = URLRequest(url: robotsURL)
                request.setValue(config.etiquette.userAgent, forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                if let response = try? await inner.send(request) {
                    lock.withLock { lastRequest[host] = clock.now }
                    if Self.isBotChallenge(response) {
                        lock.withLock { _ = challenged.insert(host) }
                        log(robotsURL, method: "GET", purpose: .ownSite(domain: host), result: "refused:bot-challenge")
                        throw LeadPipelineRefusal(code: "refused:bot-challenge", detail: host)
                    }
                    log(robotsURL, method: "GET", purpose: .ownSite(domain: host), result: (200..<300).contains(response.status) ? "ok" : "error:\(response.status)")
                    if (200..<300).contains(response.status) { parsed = RobotsRules.parse(String(decoding: response.body, as: UTF8.self)) }
                    // A 401 or 403 on robots.txt means the site does not want crawlers: treat everything as disallowed.
                    if response.status == 401 || response.status == 403 { parsed = RobotsRules(groups: [.init(agents: ["*"], rules: [(false, "/")], crawlDelay: nil)]) }
                }
            }
            rules = parsed
            lock.withLock { robots[host] = parsed }
        }
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")
        if rules?.allows(path: path, agent: "ControlWard") == false { throw LeadPipelineRefusal(code: "refused:robots", detail: url.path) }
    }

    private func pace(host: String, purpose: FetchPurpose) async {
        var interval = config.etiquette.minSecondsBetweenRequestsPerHost
        if case .openData(let id) = purpose, let source = config.allowlist.openDataSources.first(where: { $0.id == id }) {
            interval = max(interval, source.minSecondsBetweenRequests)
        }
        let (last, delay) = lock.withLock { (lastRequest[host], robots[host]?.crawlDelay(agent: "ControlWard")) }
        interval = max(interval, delay ?? 0)
        if let last {
            let wait = interval - clock.now.timeIntervalSince(last)
            if wait > 0 { await clock.sleep(seconds: wait) }
        }
    }

    static func isBotChallenge(_ response: LeadHTTPResponse) -> Bool {
        if response.headers["cf-mitigated"]?.lowercased() == "challenge" { return true }
        guard [403, 429, 503].contains(response.status) else { return false }
        let head = String(decoding: response.body.prefix(20_000), as: UTF8.self).lowercased()
        return ["challenge-platform", "cf-chl", "just a moment...", "attention required! | cloudflare", "captcha"].contains { head.contains($0) }
    }

    private func log(_ url: URL, method: String, purpose: FetchPurpose, result: String, at: Date? = nil) {
        let host = url.host?.lowercased() ?? "-"
        let isSend = purpose == .gmail && method == "POST" && (url.path.hasSuffix("/messages/send") || url.path.hasSuffix("/drafts/send"))
        lock.withLock {
            records.append(RequestRecord(url: CWAuditLine.register(for: url), host: host, method: method, purpose: purpose.label, result: result, isSend: isSend))
        }
        audit.write(CWAuditLine(ts: at ?? clock.now, surface: "leads", action: isSend ? "send" : "fetch", register: CWAuditLine.register(for: url),
                                target: host, source: purpose.label, result: result))
    }
}

/// A small robots.txt reader: user-agent groups, Allow/Disallow with `*` and `$`, longest match wins, Crawl-delay.
struct RobotsRules: Sendable {
    struct Group: Sendable {
        var agents: [String]
        var rules: [(allow: Bool, pattern: String)]
        var crawlDelay: Double?
    }
    var groups: [Group]

    static func parse(_ text: String) -> RobotsRules {
        var groups: [Group] = []
        var current: Group?
        var lastWasAgent = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            switch key {
            case "user-agent":
                if !lastWasAgent { if let current { groups.append(current) }; current = Group(agents: [], rules: [], crawlDelay: nil) }
                current?.agents.append(value.lowercased())
                lastWasAgent = true
            case "allow", "disallow":
                lastWasAgent = false
                if !value.isEmpty { current?.rules.append((key == "allow", value)) }
            case "crawl-delay":
                lastWasAgent = false
                current?.crawlDelay = Double(value)
            default:
                lastWasAgent = false
            }
        }
        if let current { groups.append(current) }
        return RobotsRules(groups: groups)
    }

    private func group(for agent: String) -> Group? {
        let agent = agent.lowercased()
        return groups.first { $0.agents.contains { $0 != "*" && agent.hasPrefix($0) } } ?? groups.first { $0.agents.contains("*") }
    }

    func crawlDelay(agent: String) -> Double? { group(for: agent)?.crawlDelay }

    func allows(path: String, agent: String) -> Bool {
        guard let group = group(for: agent) else { return true }
        var best: (length: Int, allow: Bool)?
        for rule in group.rules where Self.matches(rule.pattern, path) {
            let length = rule.pattern.count
            if best == nil || length > best!.length || (length == best!.length && rule.allow) { best = (length, rule.allow) }
        }
        return best?.allow ?? true
    }

    static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "$": regex += "$"
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
