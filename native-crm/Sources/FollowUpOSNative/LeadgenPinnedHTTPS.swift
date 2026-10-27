import Foundation
#if os(macOS)
import Network
import Security
#endif

/// HTTPS to an address that already passed the pin, with the original hostname as the TLS server name.
/// Production sets no verify block: the system evaluates the certificate against that hostname.
/// A non-empty `trustAnchorDERs` is the test seam for a local CA. It is empty in production.
enum LeadgenPinnedHTTPS {
    #if os(macOS)
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
            let data = try await read(connection, queue: queue)
            connection.cancel()
            guard let parsed = try parse(data, complete: true) else {
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
            queue.asyncAfter(deadline: .now() + 20) {
                gate.run { cont.resume(throwing: LeadPipelineRefusal(code: "refused:own-site-host", detail: "connection timed out")) }
            }
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                gate.run { cont.resume(throwing: LeadPipelineRefusal(code: "refused:own-site-host", detail: "send timed out")) }
            }
        }
    }

    private static func read(_ connection: NWConnection, queue: DispatchQueue) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let reader = LeadgenHTTPReader(queue: queue, box: LeadgenContinuationBox(cont))
            reader.start(connection)
        }
    }

    #endif

    /// nil while the headers, or a declared body length, are still incomplete.
    /// A chunked body is returned without its framing. A malformed chunk size throws.
    static func parse(_ data: Data, complete: Bool) throws -> (Int, [String: String], Data)? {
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
        if isChunked(headers) {
            guard let decoded = try decodeChunked(Data(body)) else { return nil }
            return (status, headers, decoded)
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            guard body.count >= length else { return nil }
            return (status, headers, Data(body.prefix(length)))
        }
        guard complete else { return nil }
        return (status, headers, Data(body))
    }

    private static func isChunked(_ headers: [String: String]) -> Bool {
        guard let raw = headers["transfer-encoding"] else { return false }
        return raw.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chunked"
        }
    }

    /// nil when the chunk stream still needs bytes. The decoded body excludes extensions and trailers.
    private static func decodeChunked(_ body: Data) throws -> Data? {
        let crlf = Data("\r\n".utf8)
        var index = body.startIndex
        var output = Data()
        while true {
            guard let lineEnd = body[index...].range(of: crlf) else { return nil }
            let size = try chunkSize(body[index..<lineEnd.lowerBound])
            index = lineEnd.upperBound
            if size == 0 {
                guard trailersFinished(body, from: &index) else { return nil }
                return output
            }
            guard let dataEnd = body.index(index, offsetBy: size, limitedBy: body.endIndex),
                  let after = body.index(dataEnd, offsetBy: 2, limitedBy: body.endIndex) else { return nil }
            guard body[dataEnd..<after] == crlf else { throw malformedChunk() }
            output.append(body[index..<dataEnd])
            index = after
        }
    }

    private static func chunkSize(_ line: Data) throws -> Int {
        guard let text = String(data: line, encoding: .utf8) else { throw malformedChunk() }
        var hex = ""
        var rest = text[...]
        while let character = rest.first, character.isHexDigit {
            hex.append(character)
            rest.removeFirst()
        }
        guard !hex.isEmpty, let size = Int(hex, radix: 16), size >= 0 else { throw malformedChunk() }
        let remainder = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard remainder.isEmpty || remainder.first == ";" else { throw malformedChunk() }
        return size
    }

    /// false when the trailer block is still incomplete. A finished block ends with a blank line.
    private static func trailersFinished(_ body: Data, from index: inout Data.Index) -> Bool {
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = body[index...].range(of: crlf) else { return false }
            let blank = lineEnd.lowerBound == index
            index = lineEnd.upperBound
            if blank { return true }
        }
    }

    private static func malformedChunk() -> LeadPipelineRefusal {
        LeadPipelineRefusal(code: "refused:own-site-host", detail: "malformed chunk size")
    }
}

#if os(macOS)
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

/// Holds the continuation so the connection queue can resume it without capturing a non-Sendable value.
private final class LeadgenContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(returning value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// Buffer, completion flag, and continuation live on the connection queue. The receive callback only hops back onto that queue.
private final class LeadgenHTTPReader: @unchecked Sendable {
    private let queue: DispatchQueue
    private let box: LeadgenContinuationBox<Data>
    private var buffer = Data()
    private var settled = false

    init(queue: DispatchQueue, box: LeadgenContinuationBox<Data>) {
        self.queue = queue
        self.box = box
    }

    func start(_ connection: NWConnection) {
        queue.async { [self] in
            self.queue.asyncAfter(deadline: .now() + 20) { [self] in
                self.fail(LeadPipelineRefusal(code: "refused:own-site-host", detail: "read timed out"))
            }
            self.pump(connection)
        }
    }

    private func pump(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            self.queue.async { [self] in
                self.consume(data, isComplete: isComplete, error: error, connection: connection)
            }
        }
    }

    private func consume(_ data: Data?, isComplete: Bool, error: NWError?, connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !settled else { return }
        if let data { buffer.append(data) }
        if let error {
            fail(error)
            return
        }
        do {
            if try LeadgenPinnedHTTPS.parse(buffer, complete: isComplete) != nil || isComplete {
                succeed(buffer)
                return
            }
        } catch {
            fail(error)
            return
        }
        pump(connection)
    }

    private func succeed(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !settled else { return }
        settled = true
        box.resume(returning: data)
    }

    private func fail(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !settled else { return }
        settled = true
        box.resume(throwing: error)
    }
}
#endif
