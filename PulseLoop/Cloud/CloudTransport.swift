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
