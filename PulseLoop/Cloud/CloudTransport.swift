import CryptoKit
import Foundation
import Security
import os

// The pluggable HTTP layer of the Agara Cloud clients (release 1.1). Everything that talks to Firebase Auth's
// REST API or to the Agara server goes through `CloudTransport`, so the tests (and the debug-only fake backend)
// replace the network without touching the clients. No third-party SDK: plain `URLSession` underneath.

nonisolated struct CloudRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 20
}

nonisolated struct CloudResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    /// Case-insensitive header lookup (HTTP header names are).
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

/// A failure before any HTTP status existed: no network, or the request timed out.
nonisolated enum CloudTransportError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case other
}

nonisolated protocol CloudTransport: Sendable {
    func send(_ request: CloudRequest) async throws -> CloudResponse
    /// `send` for a request the server may answer with server-sent events (`text/event-stream`; the coach since
    /// 2026-10-23, contract §7). Every non-terminal event goes to `onEvent` as it arrives; the terminal `final` or `error`
    /// event becomes the returned response — status 200, or the error event's `status` — with the event's data as the
    /// body, so a caller handles a streamed reply exactly like a plain one. A plain reply is returned unchanged.
    func stream(_ request: CloudRequest, onEvent: @escaping @Sendable (String, Data) -> Void) async throws -> CloudResponse
}

extension CloudTransport {
    /// Transports that cannot stream (the debug fake backend, test doubles) answer the plain way.
    func stream(_ request: CloudRequest, onEvent: @escaping @Sendable (String, Data) -> Void) async throws -> CloudResponse {
        try await send(request)
    }
}

/// Server-sent events, one line at a time (the WHATWG format, as much of it as the coach server writes): `event:` names
/// the event, `data:` lines carry it, a blank line — or the next `event:` line, or the end of the stream — ends it.
nonisolated struct ServerSentEventParser {
    private var name = ""
    private var data: [String] = []

    /// Feeds one line without its line break; returns the event the line completed, if any.
    mutating func feed(line: String) -> (name: String, data: Data)? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }                       // a comment / keep-alive
        if line.hasPrefix("event:") {
            let done = flush()
            name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return done
        }
        if line.hasPrefix("data:") {
            var value = Substring(line.dropFirst(5))
            if value.hasPrefix(" ") { value = value.dropFirst() }
            data.append(String(value))
        }
        return nil
    }

    /// Ends the pending event (a blank line, or the end of the stream).
    mutating func flush() -> (name: String, data: Data)? {
        defer { name = ""; data = [] }
        guard !data.isEmpty else { return nil }
        return (name.isEmpty ? "message" : name, Data(data.joined(separator: "\n").utf8))
    }

    /// The response a terminal event stands for, or nil when the event is not terminal.
    static func terminalResponse(name: String, data: Data, headers: [String: String]) -> CloudResponse? {
        switch name {
        case "final":
            return CloudResponse(status: 200, headers: headers, body: data)
        case "error":
            let status = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["status"] as? Int ?? 502
            return CloudResponse(status: status, headers: headers, body: data)
        default:
            return nil
        }
    }
}

/// The real transport: an ephemeral `URLSession` (no cookies, no disk cache — the bodies are health data and tokens),
/// shared, with certificate pinning for the Agara host (`CloudPinning`).
nonisolated struct URLSessionCloudTransport: CloudTransport {
    /// One session for every client (a session retains its delegate; one per transport would pile up).
    static let pinnedSession = URLSession(configuration: .ephemeral, delegate: CloudPinningDelegate(), delegateQueue: nil)

    private let session: URLSession

    init(session: URLSession = URLSessionCloudTransport.pinnedSession) { self.session = session }

    func send(_ request: CloudRequest) async throws -> CloudResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw CloudTransportError.other }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
            return CloudResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as CloudTransportError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
                throw CloudTransportError.offline
            case .timedOut: throw CloudTransportError.timedOut
            default: throw CloudTransportError.other
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudTransportError.other
        }
    }

    func stream(_ request: CloudRequest, onEvent: @escaping @Sendable (String, Data) -> Void) async throws -> CloudResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw CloudTransportError.other }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.contains("text/event-stream") else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                return CloudResponse(status: http.statusCode, headers: headers, body: body)
            }
            // Byte by byte, not `bytes.lines`: that sequence drops blank lines, which end events.
            var parser = ServerSentEventParser()
            var line = Data()
            func handle(_ event: (name: String, data: Data)?) -> CloudResponse? {
                guard let event else { return nil }
                if let done = ServerSentEventParser.terminalResponse(name: event.name, data: event.data, headers: headers) {
                    return done
                }
                onEvent(event.name, event.data)
                return nil
            }
            for try await byte in bytes {
                if byte == UInt8(ascii: "\n") {
                    if line.last == UInt8(ascii: "\r") { line.removeLast() }
                    if let done = handle(parser.feed(line: String(decoding: line, as: UTF8.self))) { return done }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty, let done = handle(parser.feed(line: String(decoding: line, as: UTF8.self))) { return done }
            if let done = handle(parser.flush()) { return done }
            throw CloudTransportError.other                      // the stream ended without its final event
        } catch let error as CloudTransportError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
                throw CloudTransportError.offline
            case .timedOut: throw CloudTransportError.timedOut
            default: throw CloudTransportError.other
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudTransportError.other
        }
    }
}

// MARK: - Certificate pinning (pre-TestFlight, 2026-10-22)

/// Pins the HOST of `cloud_v2_base_url` (sync + coach) to ROOT public keys from `docs/config/shared.yaml`
/// (`cloud_tls_pins_sha256`). The system's own TLS validation runs first and must pass — the pin only ever narrows trust:
/// the validated chain must contain at least one pinned key. Roots, not the leaf or intermediates, because Let's
/// Encrypt rotates both. Past `cloud_tls_pins_expire` the pins stop being enforced, so an old install can never be
/// locked out of its own cloud by a CA change. Other hosts (Firebase's googleapis, debug overrides) are not pinned.
nonisolated enum CloudPinning {
    enum Decision: Equatable { case notPinned, accept, reject }

    static let pins: Set<String> = Set(AgaraConfig.Cloud.tlsPinsSha256.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    static let pinnedHost: String? = URL(string: AgaraConfig.Cloud.v2BaseUrl)?.host?.lowercased()
    /// The end of the expiry day, UTC.
    static let expiry: Date? = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: AgaraConfig.Cloud.tlsPinsExpire).map { $0.addingTimeInterval(86_400) }
    }()

    static func isEnforced(host: String, now: Date = Date(), pinnedHost: String? = pinnedHost,
                           pins: Set<String> = pins, expiry: Date? = expiry) -> Bool {
        guard let pinnedHost, host.lowercased() == pinnedHost, !pins.isEmpty, let expiry else { return false }
        return now < expiry
    }

    /// The whole decision for one server-trust challenge. `verifyDate` exists for the tests (fixed chains expire).
    static func evaluate(trust: SecTrust, host: String, now: Date = Date(), pins: Set<String> = pins,
                         pinnedHost: String? = pinnedHost, expiry: Date? = expiry) -> Decision {
        guard isEnforced(host: host, now: now, pinnedHost: pinnedHost, pins: pins, expiry: expiry) else { return .notPinned }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        guard SecTrustEvaluateWithError(trust, nil) else { return .reject }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return chainMatches(chain, pins: pins) ? .accept : .reject
    }

    static func chainMatches(_ chain: [SecCertificate], pins: Set<String>) -> Bool {
        chain.contains { certificate in spkiSHA256(of: certificate).map(pins.contains) ?? false }
    }

    /// base64 SHA-256 of the certificate's SubjectPublicKeyInfo — the value `openssl x509 -pubkey | openssl pkey -pubin
    /// -outform der | openssl dgst -sha256 -binary | base64` prints. Security.framework hands out the bare key (PKCS#1
    /// for RSA, X9.63 for EC), so the SPKI header for its algorithm and size is prepended.
    static func spkiSHA256(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String,
              let bits = (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let header = spkiHeader(keyType: type, bits: bits)
        else { return nil }
        return Data(SHA256.hash(data: header + raw)).base64EncodedString()
    }

    static func spkiHeader(keyType: String, bits: Int) -> Data? {
        let rsa = keyType == (kSecAttrKeyTypeRSA as String)
        let ec = keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)
        let hex: String
        switch (rsa, ec, bits) {
        case (true, _, 2048): hex = "30820122300d06092a864886f70d01010105000382010f00"
        case (true, _, 3072): hex = "308201a2300d06092a864886f70d01010105000382018f00"
        case (true, _, 4096): hex = "30820222300d06092a864886f70d01010105000382020f00"
        case (_, true, 256): hex = "3059301306072a8648ce3d020106082a8648ce3d030107034200"
        case (_, true, 384): hex = "3076301006072a8648ce3d020106052b81040022036200"
        default: return nil
        }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

/// Answers the server-trust challenge with `CloudPinning`. A rejected chain cancels the connection (the request fails
/// as `CloudTransportError.other`, never as "offline", so the app does not quietly retry into a MITM).
nonisolated final class CloudPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.agara.ring", category: "cloud.pinning")

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        switch CloudPinning.evaluate(trust: trust, host: host) {
        case .notPinned: return (.performDefaultHandling, nil)
        case .accept: return (.useCredential, URLCredential(trust: trust))
        case .reject:
            Self.log.error("certificate pinning rejected the chain for \(host, privacy: .public)")
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}
