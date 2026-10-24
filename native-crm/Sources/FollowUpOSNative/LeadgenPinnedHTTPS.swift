import Foundation
#if os(macOS)
import Network
import Security

/// HTTPS to an address that already passed the pin, with the original hostname as the TLS server name.
/// Production sets no verify block: the system evaluates the certificate against that hostname.
/// A non-empty `trustAnchorDERs` is the test seam for a local CA. It is empty in production.
enum LeadgenPinnedHTTPS {
    static func exchange(request: URLRequest, trustAnchorDERs: [Data]) async throws -> (Int, [String: String], Data) {
        guard let url = request.url, let ip = url.host, !ip.isEmpty else {
            throw LeadPipelineRefusal(code: "refused:own-site-host", detail: "pinned request has no host")
        }
        let serverName = (request.value(forHTTPHeaderField: "Host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverName.isEmpty, serverName != ip else {
            throw LeadPipelineRefusal(code: "refused:own-site-host", detail: "TLS server name missing")
        }
        let port = UInt16(url.port ?? 443)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LeadPipelineRefusal(code: "refused:own-site-host", detail: "bad port")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        if !trustAnchorDERs.isEmpty {
            let ders = trustAnchorDERs
            let name = serverName
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let certs = ders.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                guard !certs.isEmpty else { complete(false); return }
                SecTrustSetAnchorCertificates(secTrust, certs as CFArray)
                SecTrustSetAnchorCertificatesOnly(secTrust, true)
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, name as CFString))
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            }, DispatchQueue(label: "leadgen.tls.verify"))
        }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: endpointPort, using: NWParameters(tls: tls, tcp: tcp))
        let queue = DispatchQueue(label: "leadgen.tls.connection")
        do {
            try await ready(connection, queue: queue)
            try await send(connection, request: request, url: url, serverName: serverName)
            let data = try await read(connection)
            connection.cancel()
            guard let parsed = parse(data, complete: true) else {
                throw LeadPipelineRefusal(code: "refused:own-site-host", detail: "truncated HTTP response")
            }
            return parsed
        } catch {
            connection.cancel()
            throw error
        }
    }

    private static func ready(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.run { cont.resume() }
                case .failed(let error): gate.run { cont.resume(throwing: error) }
                case .cancelled: gate.run { cont.resume(throwing: LeadPipelineRefusal(code: "refused:own-site-host", detail: "connection cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func send(_ connection: NWConnection, request: URLRequest, url: URL, serverName: String) async throws {
        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        var headers: [String] = ["\(method) \(path)\(query) HTTP/1.1", "Host: \(serverName)", "Connection: close"]
        if let fields = request.allHTTPHeaderFields {
            for (key, value) in fields where key.lowercased() != "host" && key.lowercased() != "connection" {
                headers.append("\(key): \(value)")
            }
        }
        var bytes = Data(headers.joined(separator: "\r\n").utf8)
        bytes.append(contentsOf: "\r\n\r\n".utf8)
        if let body = request.httpBody, !body.isEmpty {
            if !headers.contains(where: { $0.lowercased().hasPrefix("content-length:") }) {
                bytes = Data((headers + ["Content-Length: \(body.count)"]).joined(separator: "\r\n").utf8)
                bytes.append(contentsOf: "\r\n\r\n".utf8)
            }
            bytes.append(body)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = Once()
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { gate.run { cont.resume(throwing: error) } }
                else { gate.run { cont.resume() } }
            })
        }
    }

    private static func read(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let gate = Once()
            let box = Buffer()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data { box.append(data) }
                    if let error {
                        gate.run { cont.resume(throwing: error) }
                        return
                    }
                    if parse(box.bytes, complete: isComplete) != nil || isComplete {
                        gate.run { cont.resume(returning: box.bytes) }
                        return
                    }
                    receive()
                }
            }
            receive()
        }
    }

    /// nil while the headers, or a declared Content-Length, are still incomplete.
    static func parse(_ data: Data, complete: Bool) -> (Int, [String: String], Data)? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let body = data[split.upperBound...]
        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            guard body.count >= length else { return nil }
            return (status, headers, Data(body.prefix(length)))
        }
        guard complete else { return nil }
        return (status, headers, Data(body))
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
}
#endif
