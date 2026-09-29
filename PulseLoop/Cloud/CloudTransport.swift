import Foundation

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

/// The real transport: an ephemeral `URLSession` (no cookies, no disk cache — the bodies are health data and tokens).
nonisolated struct URLSessionCloudTransport: CloudTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

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
