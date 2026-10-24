import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Own-site URL checks shared by the lead pipeline and the lead-gen slice (Argus must-fix 2).
/// A business site is a public DNS name. IP literals in any spelling, internal names, non-http(s)
/// schemes, and names that resolve to loopback, private, link-local or other non-public addresses are refused.
enum HostSafety {
    static let internalSuffixes = ["local", "localhost", "internal", "lan", "home.arpa", "arpa", "localdomain", "intranet"]

    /// `nil` when the URL may be fetched. `resolvedAddresses` nil skips the DNS check (literal and name rules still apply).
    /// An empty address list fails closed: the name was not shown to be public.
    /// `admitLoopback` is a test-only seam, default off. Production never sets it, so loopback and odd ports stay refused.
    static func refusal(url: URL, resolvedAddresses: [String]? = nil, admitLoopback: Bool = false) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" { return "scheme \(scheme.isEmpty ? "none" : scheme)" }
        if url.user != nil || url.password != nil || url.absoluteString.contains("\\") { return "user info or delimiter" }
        guard let original = url.host, !original.isEmpty else { return "no host" }
        let host = canonicalHost(original)
        if host.isEmpty { return "no host" }
        if let port = url.port, port != (scheme == "https" ? 443 : 80) {
            let loopbackTarget = admitLoopback && resolvedAddresses?.isEmpty == false && resolvedAddresses?.allSatisfy(isLoopback) == true
            if !loopbackTarget { return "non-default port \(port)" }
        }
        if let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost {
            let decoded = canonicalHost(percentDecoded(encoded))
            if decoded != host, let why = nameRefusal(decoded) { return why }
        }
        if let why = nameRefusal(host) { return why }
        if let resolvedAddresses {
            if resolvedAddresses.isEmpty { return "unresolved \(host)" }
            for address in resolvedAddresses {
                if let why = addressRefusal(address) {
                    if admitLoopback && isLoopback(address) { continue }
                    return "resolved \(address) (\(why))"
                }
            }
        }
        return nil
    }

    static func canonicalHost(_ raw: String) -> String {
        var host = percentDecoded(raw).lowercased()
        for dot in ["\u{3002}", "\u{ff0e}", "\u{ff61}"] { host = host.replacingOccurrences(of: dot, with: ".") }
        for mark in ["\u{200b}", "\u{200c}", "\u{200d}", "\u{feff}"] { host = host.replacingOccurrences(of: mark, with: "") }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func percentDecoded(_ raw: String) -> String {
        var host = raw
        for _ in 0..<3 {
            guard let decoded = host.removingPercentEncoding, decoded != host else { break }
            host = decoded
        }
        return host
    }

    static func isIPLiteral(_ host: String) -> Bool { nameRefusal(canonicalHost(host))?.contains("IP") == true || nameRefusal(canonicalHost(host))?.contains("IPv6") == true }

    static func nameRefusal(_ host: String) -> String? {
        if host.contains(":") { return "IPv6 literal" }
        if ipv4Value(host) != nil { return "IP literal" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.contains(where: \.isEmpty) { return "empty label" }
        if labels.count < 2 { return "single-label host" }
        let last = labels[labels.count - 1]
        if last.allSatisfy(\.isNumber) || last.hasPrefix("0x") { return "IP literal" }
        if internalSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "internal name" }
        return nil
    }

    /// Why a resolved address is not a public unicast target, or nil when it is.
    static func addressRefusal(_ raw: String) -> String? {
        let text = canonicalHost(raw)
        if let value = ipv4Value(text) { return isNonPublicIPv4(value) ? "non-public" : nil }
        if text.contains(":"), let bytes = ipv6Bytes(text) { return isNonPublicIPv6(bytes) ? "non-public" : nil }
        return "not an address"
    }

    static func isNonPublic(_ address: String) -> Bool { addressRefusal(address) != nil }

    /// 127.0.0.0/8 and ::1. Used only by the test seam that admits a local TLS listener.
    static func isLoopback(_ raw: String) -> Bool {
        let text = canonicalHost(raw)
        if let value = ipv4Value(text) { return (value & 0xFF00_0000) == 0x7F00_0000 }
        guard text.contains(":"), let bytes = ipv6Bytes(text), bytes.count == 16 else { return false }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
    }

    static func ipv4Value(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count), !parts.contains(where: \.isEmpty) else { return nil }
        var nums: [UInt64] = []
        for part in parts {
            guard let n = ipv4Part(part) else { return nil }
            nums.append(n)
        }
        switch nums.count {
        case 1:
            guard nums[0] <= 0xFFFF_FFFF else { return nil }
            return UInt32(nums[0])
        case 2:
            guard nums[0] <= 0xFF, nums[1] <= 0xFF_FFFF else { return nil }
            return UInt32((nums[0] << 24) | nums[1])
        case 3:
            guard nums[0] <= 0xFF, nums[1] <= 0xFF, nums[2] <= 0xFFFF else { return nil }
            return UInt32((nums[0] << 24) | (nums[1] << 16) | nums[2])
        default:
            guard nums.allSatisfy({ $0 <= 0xFF }) else { return nil }
            return UInt32((nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3])
        }
    }

    private static func ipv4Part(_ text: String) -> UInt64? {
        let s = text.lowercased()
        if s.hasPrefix("0x") {
            guard s.count > 2, s.dropFirst(2).allSatisfy(\.isHexDigit), let v = UInt64(s.dropFirst(2), radix: 16) else { return nil }
            return v
        }
        if s.count > 1, s.hasPrefix("0") {
            let octal = Character("0")...Character("7")
            guard s.allSatisfy({ octal.contains($0) }), let v = UInt64(s, radix: 8) else { return nil }
            return v
        }
        guard !s.isEmpty, s.allSatisfy(\.isNumber), let v = UInt64(s, radix: 10) else { return nil }
        return v
    }

    static func isNonPublicIPv4(_ ip: UInt32) -> Bool {
        func inRange(_ net: UInt32, _ bits: UInt32) -> Bool {
            let mask: UInt32 = bits == 0 ? 0 : UInt32.max << (32 - bits)
            return (ip & mask) == (net & mask)
        }
        if inRange(0x0000_0000, 8) { return true }
        if inRange(0x0A00_0000, 8) { return true }
        if inRange(0x6440_0000, 10) { return true }
        if inRange(0x7F00_0000, 8) { return true }
        if inRange(0xA9FE_0000, 16) { return true }
        if inRange(0xAC10_0000, 12) { return true }
        if inRange(0xC0A8_0000, 16) { return true }
        if inRange(0xC000_0000, 24) { return true }
        if inRange(0xC000_0200, 24) { return true }
        if inRange(0xC612_0000, 15) { return true }
        if inRange(0xC633_6400, 24) { return true }
        if inRange(0xCB00_7100, 24) { return true }
        if ip >= 0xE000_0000 { return true }
        return false
    }

    /// 16 bytes, or nil when the text is not an IPv6 address. A dotted tail (`::ffff:127.0.0.1`) is accepted.
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var s = text.lowercased()
        if let zone = s.firstIndex(of: "%") { s = String(s[..<zone]) }
        var v4: [UInt8]?
        if s.contains("."), let colon = s.lastIndex(of: ":") {
            guard let ip = ipv4Value(String(s[s.index(after: colon)...])) else { return nil }
            v4 = [UInt8((ip >> 24) & 0xFF), UInt8((ip >> 16) & 0xFF), UInt8((ip >> 8) & 0xFF), UInt8(ip & 0xFF)]
            s = String(s[..<colon])
        }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for group in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard !group.isEmpty, group.count <= 4, group.allSatisfy(\.isHexDigit), let value = UInt16(group, radix: 16) else { return nil }
                out.append(value)
            }
            return out
        }
        guard var left = groups(halves[0]) else { return nil }
        let right = halves.count == 2 ? groups(halves[1]) : []
        guard var right else { return nil }
        let v4Groups = (v4 == nil) ? 0 : 2
        if halves.count == 1 {
            guard left.count + v4Groups == 8 else { return nil }
        } else {
            let missing = 8 - left.count - right.count - v4Groups
            guard missing >= 0 else { return nil }
            left += Array(repeating: 0, count: missing)
            left += right
            right = []
        }
        var bytes: [UInt8] = []
        for group in left {
            bytes.append(UInt8(group >> 8))
            bytes.append(UInt8(group & 0xFF))
        }
        if let v4 { bytes += v4 }
        guard bytes.count == 16 else { return nil }
        return bytes
    }

    static func isNonPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if (bytes[0] & 0xFE) == 0xFC { return true }
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
        if bytes[0] == 0xFF { return true }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 { return true }
        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        if mapped {
            let v4 = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return isNonPublicIPv4(v4)
        }
        // NAT64 well-known prefix 64:ff9b::/96.
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
            && bytes.dropFirst(4).prefix(8).allSatisfy({ $0 == 0 }) { return true }
        // IPv4-compatible ::/96 (the last 32 bits are an embedded IPv4 address).
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return true }
        // 6to4 2002::/16.
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return true }
        // Teredo 2001::/32.
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00 { return true }
        return false
    }
}

/// Connects to an address that already passed `HostSafety`, and keeps the original host for the HTTP Host header.
struct LeadgenPinnedRequest: Equatable, Sendable {
    var url: URL
    var hostHeader: String

    /// The first admitted address is the connection target. A non-public address is not pinned.
    /// `admitLoopback` is the same test-only seam as `HostSafety.refusal`. Default off.
    static func pin(url: URL, addresses: [String], admitLoopback: Bool = false) -> LeadgenPinnedRequest? {
        guard let host = url.host, !host.isEmpty, let address = addresses.first else { return nil }
        if HostSafety.addressRefusal(address) != nil, !(admitLoopback && HostSafety.isLoopback(address)) { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.host = address
        guard let pinned = components.url else { return nil }
        return LeadgenPinnedRequest(url: pinned, hostHeader: host)
    }
}

enum SystemHostLookup {
    /// Numeric addresses for `host` (IPv4 and IPv6). Empty when the name does not resolve.
    static func addresses(_ host: String) -> [String] {
        let name = HostSafety.canonicalHost(host)
        guard !name.isEmpty else { return [] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &info) == 0, let info else { return [] }
        defer { freeaddrinfo(info) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let node = cursor {
            if let addr = node.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: 1025)
                if getnameinfo(addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
                    let text = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !text.isEmpty { out.append(text) }
                }
            }
            cursor = node.pointee.ai_next
        }
        return out
    }
}

/// Measures how long one request actually waited on the network (send to answer or error), on the transport clock.
final class LeadWaitMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double?
    func record(_ value: Double) { lock.withLock { seconds = value } }
    /// Whole milliseconds, or nil when the request never reached the network (a refusal).
    var milliseconds: Int? { lock.withLock { seconds.map { Int(($0 * 1000).rounded()) } } }
}

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

/// Ephemeral session: no cookies and no URL cache, so fetched pages never land in a shared cache. Redirects are never
/// followed here: every 30x goes back to `GuardedLeadTransport`, which re-admits and robots-checks each hop (Argus must-fix 3).
struct URLSessionLeadTransport: LeadTransport {
    static let followsRedirects = false
    /// Tests pass a fake. Production uses system DNS.
    var lookup: @Sendable (String) -> [String] = { SystemHostLookup.addresses($0) }
    /// Test-only. Production leaves this false, so loopback is still refused.
    var admitLoopbackForTests = false
    /// DER trust anchors for the test CA. Production leaves this empty: system trust, no override.
    var testTrustAnchorDERs: [Data] = []

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// One ephemeral session for the process: no cookies, no cache. Creating and dropping a session per request
    /// crashes swift-corelibs-foundation on Linux (_MultiHandle over-release) and wastes connections on macOS.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Only a ceiling: each request sets its own timeoutInterval (20 s by default, Overpass query limit + 10 s for discovery).
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> LeadHTTPResponse {
        var outbound = request
        var original = request.url
        if let url = request.url {
            let resolved = lookup(url.host ?? "")
            if let why = HostSafety.refusal(url: url, resolvedAddresses: resolved, admitLoopback: admitLoopbackForTests) {
                throw LeadPipelineRefusal(code: "refused:own-site-host", detail: why)
            }
            guard let plan = LeadgenPinnedRequest.pin(url: url, addresses: resolved, admitLoopback: admitLoopbackForTests) else {
                throw LeadPipelineRefusal(code: "refused:own-site-host", detail: "unresolved \(url.host ?? "")")
            }
            outbound.url = plan.url
            outbound.setValue(plan.hostHeader, forHTTPHeaderField: "Host")
            original = url
        }
        // URLSession connects to the pinned IP. It does not set SNI to the original hostname, and it
        // cannot use `testTrustAnchorDERs`. The macOS path replaces this once the pinned TLS client lands.
        _ = testTrustAnchorDERs
        let (data, response) = try await Self.session.data(for: outbound)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { headers[String(describing: key).lowercased()] = String(describing: value) }
        return LeadHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data, url: original ?? request.url)
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
    /// When set, every own-site name is resolved and a loopback, private, link-local or other non-public address is refused
    /// before the inner transport is called. Nil keeps the literal and name checks only (tests that never resolve).
    let resolveHost: (@Sendable (String) -> [String])?
    private let lock = NSLock()
    private var lastRequest: [String: Date] = [:]
    private var robots: [String: RobotsRules] = [:]
    private var challenged: Set<String> = []
    private var sensitive: Set<String> = []
    private var records: [RequestRecord] = []

    init(config: ICPConfig, inner: any LeadTransport, audit: any CWAuditSink, clock: any LeadClock = SystemLeadClock(),
         resolveHost: (@Sendable (String) -> [String])? = nil) {
        self.config = config
        self.inner = inner
        self.audit = audit
        self.clock = clock
        self.resolveHost = resolveHost
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

    /// Per-request client timeout when the caller does not pass one.
    static let defaultTimeoutSeconds: Double = 20

    /// One audit line per Overpass attempt (Water 7:49), next to the transport's own fetch line, so a retry run reads
    /// attempt-1-of-3, attempt-2-of-3, ... per host.
    /// The receipt also carries the request's measured wait (`wait-<ms>ms`, Earth 8:20; 0 when it never reached the network).
    func auditDiscoveryAttempt(_ server: URL, attempt: Int, of total: Int, result: String, waitMilliseconds: Int?) {
        audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "discovery-attempt", register: CWAuditLine.register(for: server),
                                target: server.host?.lowercased() ?? "-", source: "discovery", result: result,
                                receipt: "attempt-\(attempt)-of-\(total),wait-\(waitMilliseconds ?? 0)ms"))
    }

    /// At most this many 30x hops are followed; each hop is admitted and robots-checked like a first request.
    static let maxRedirects = 3

    func fetch(_ url: URL, purpose: FetchPurpose, method: String = "GET", body: Data? = nil,
               headers: [String: String] = [:], maxBytes: Int? = nil, timeout: Double? = nil,
               meter: LeadWaitMeter? = nil) async throws -> LeadHTTPResponse {
        var current = url
        var hops = 0
        while true {
            var response = try await fetchOne(current, purpose: purpose, method: method, body: body, headers: headers, maxBytes: maxBytes, timeout: timeout, meter: meter)
            if (300..<400).contains(response.status), let location = response.headers["location"] {
                let next = URL(string: location, relativeTo: current)?.absoluteURL
                if let refusal = redirectRefusal(from: current, to: next, purpose: purpose) { log(current, method: method, purpose: purpose, result: refusal.code); throw refusal }
                guard hops < Self.maxRedirects else {
                    let refusal = LeadPipelineRefusal(code: "refused:redirect-limit", detail: "more than \(Self.maxRedirects) redirects")
                    log(current, method: method, purpose: purpose, result: refusal.code)
                    throw refusal
                }
                hops += 1
                current = next!
                continue
            }
            if let final = response.url, final.absoluteString != current.absoluteString,
               let refusal = redirectRefusal(from: current, to: final, purpose: purpose) {
                log(current, method: method, purpose: purpose, result: refusal.code)
                throw refusal
            }
            response.url = response.url ?? current
            return response
        }
    }

    /// A hop stays on the business's own domain (own-site) or on the same host (every other purpose).
    func redirectRefusal(from: URL, to: URL?, purpose: FetchPurpose) -> LeadPipelineRefusal? {
        let offSite = LeadPipelineRefusal(code: "refused:redirect-off-site", detail: to?.host ?? "-")
        guard let to, let host = to.host?.lowercased(), !host.isEmpty else { return offSite }
        if case .ownSite(let domain) = purpose {
            let resolved = resolveHost.map { $0(host) }
            if let unsafe = Self.ownSiteHostRefusal(to, resolvedAddresses: resolved) { return unsafe }
            return HostMatch.belongs(host, to: domain) ? nil : offSite
        }
        return host == from.host?.lowercased() ? nil : offSite
    }

    private func fetchOne(_ url: URL, purpose: FetchPurpose, method: String, body: Data?,
                          headers: [String: String], maxBytes: Int?, timeout: Double?, meter: LeadWaitMeter?) async throws -> LeadHTTPResponse {
        let host = url.host?.lowercased() ?? ""
        do {
            try admit(url, host: host, purpose: purpose, method: method, body: body)
            if case .ownSite = purpose { try await checkRobots(url, host: host) }
            await pace(host: host, purpose: purpose)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            // Callers with a server-side limit (Overpass `[timeout:N]`) pass their own; everything else keeps 20 s.
            request.timeoutInterval = timeout ?? Self.defaultTimeoutSeconds
            request.setValue(config.etiquette.userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let sentAt = clock.now
            var response: LeadHTTPResponse
            do {
                response = try await inner.send(request)
            } catch {
                meter?.record(clock.now.timeIntervalSince(sentAt))
                throw error
            }
            meter?.record(clock.now.timeIntervalSince(sentAt))
            let receivedAt = clock.now
            response.fetchedAt = receivedAt
            lock.withLock { lastRequest[host] = receivedAt }
            if Self.isBotChallenge(response) {
                lock.withLock { _ = challenged.insert(host) }
                throw LeadPipelineRefusal(code: "refused:bot-challenge", detail: host)
            }
            let limit = maxBytes ?? config.etiquette.maxResponseBytes
            if response.body.count > limit { throw LeadPipelineRefusal(code: "refused:response-too-large") }
            let result = (200..<300).contains(response.status) ? "ok" : (300..<400).contains(response.status) ? "redirect:\(response.status)" : "error:\(response.status)"
            log(url, method: method, purpose: purpose, result: result, at: receivedAt)
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

    /// Own-site host check (Argus must-fix 2, SSRF). A business website is a public DNS name on the default port, so this refuses
    /// IP literals in any spelling (dotted, decimal, octal, hex, IPv6), single-label hosts, internal suffixes, user info and
    /// non-default ports, before anything reaches the network.
    static let internalSuffixes = HostSafety.internalSuffixes

    static func ownSiteHostRefusal(_ url: URL, resolvedAddresses: [String]? = nil) -> LeadPipelineRefusal? {
        guard let why = HostSafety.refusal(url: url, resolvedAddresses: resolvedAddresses) else { return nil }
        return LeadPipelineRefusal(code: "refused:own-site-host", detail: why)
    }

    func admit(_ url: URL, host: String, purpose: FetchPurpose, method: String, body: Data?) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || (scheme == "http" && purpose != .gmail) else {
            throw LeadPipelineRefusal(code: "refused:scheme")
        }
        if case .ownSite = purpose {
            let resolved = resolveHost.map { $0(host) }
            if let refusal = Self.ownSiteHostRefusal(url, resolvedAddresses: resolved) { throw refusal }
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
                // RFC 9309: robots.txt that cannot be reached (5xx or no answer) means the whole site is disallowed;
                // 401 and 403 too. A 4xx otherwise (404) means there is no robots.txt, so the site is allowed.
                let disallowAll = RobotsRules(groups: [.init(agents: ["*"], rules: [(false, "/")], crawlDelay: nil)])
                do {
                    let response = try await inner.send(request)
                    lock.withLock { lastRequest[host] = clock.now }
                    if Self.isBotChallenge(response) {
                        lock.withLock { _ = challenged.insert(host) }
                        log(robotsURL, method: "GET", purpose: .ownSite(domain: host), result: "refused:bot-challenge")
                        throw LeadPipelineRefusal(code: "refused:bot-challenge", detail: host)
                    }
                    log(robotsURL, method: "GET", purpose: .ownSite(domain: host), result: (200..<300).contains(response.status) ? "ok" : "error:\(response.status)")
                    if (200..<300).contains(response.status) { parsed = RobotsRules.parse(String(decoding: response.body, as: UTF8.self)) }
                    // A 401 or 403 on robots.txt means the site does not want crawlers: treat everything as disallowed.
                    if response.status == 401 || response.status == 403 || response.status >= 500 { parsed = disallowAll }
                } catch let refusal as LeadPipelineRefusal {
                    throw refusal
                } catch {
                    log(robotsURL, method: "GET", purpose: .ownSite(domain: host), result: "error:network")
                    parsed = disallowAll
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
