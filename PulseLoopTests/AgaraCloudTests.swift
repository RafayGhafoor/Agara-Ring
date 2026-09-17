import XCTest
@testable import PulseLoop

/// Agara cloud contract, mirroring the Android suite (`AgaraCloudSyncTest` / `AgaraCloudClientTest`):
/// the key formats that make push idempotent, the row → event mapping that *is* the pull, and — via a
/// stubbed `URLSession` — the paging loop and error surfacing the app depends on.
///
/// Pure: no server, no SwiftData, no account.
final class AgaraCloudTests: XCTestCase {

    // MARK: Session double

    @MainActor
    private final class MemorySession: AgaraCloudSession {
        var token: String?
        var userID: String?
        var email: String?
        init(token: String? = nil, userID: String? = nil, email: String? = nil) {
            self.token = token; self.userID = userID; self.email = email
        }
        var isSignedIn: Bool { token != nil }
        func saveSession(token: String, userID: String, email: String) {
            self.token = token; self.userID = userID; self.email = email
        }
        func rememberIdentity(userID: String, email: String) {
            self.userID = userID; self.email = email
        }
        func clear() { token = nil; userID = nil; email = nil }
    }

    // MARK: URLProtocol stub

    /// Serves canned responses per path and records what was requested.
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [(match: String, status: Int, body: String)] = []
        nonisolated(unsafe) static var requestedPaths: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            let full = query.isEmpty ? path : "\(path)?\(query)"
            Self.requestedPaths.append(full)

            guard let stub = Self.responses.first(where: { full.contains($0.match) }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: stub.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset() { responses = []; requestedPaths = [] }
    }

    @MainActor
    private func makeClient(base: String = "https://cloud.test") -> (AgaraCloudClient, MemorySession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = MemorySession()
        let client = AgaraCloudClient(
            store: session,
            baseURL: URL(string: base)!,
            session: URLSession(configuration: configuration)
        )
        return (client, session)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Keys and dates

    func testClientKeyIsStableAndSourceScoped() {
        let stamp = Date(timeIntervalSince1970: 1_789_603_200)
        XCTAssertEqual(
            AgaraCloudSync.mapping.clientKey(kind: "hr", timestamp: stamp, source: "history"),
            "hr-1789603200-history"
        )
        // Sub-second differences must not change the key: the server stores seconds.
        XCTAssertEqual(
            AgaraCloudSync.mapping.clientKey(kind: "spo2", timestamp: stamp, source: "live"),
            AgaraCloudSync.mapping.clientKey(kind: "spo2", timestamp: stamp.addingTimeInterval(0.999), source: "live")
        )
        XCTAssertNotEqual(
            AgaraCloudSync.mapping.clientKey(kind: "spo2", timestamp: stamp, source: "live"),
            AgaraCloudSync.mapping.clientKey(kind: "spo2", timestamp: stamp, source: "history")
        )
    }

    func testDayStringIsTheCalendarDateInTheGivenZone() {
        var karachi = Calendar(identifier: .gregorian)
        karachi.timeZone = TimeZone(identifier: "Asia/Karachi")!
        // 2026-09-16 23:30 UTC is already the 17th in Karachi.
        let stamp = Date(timeIntervalSince1970: 1_789_601_400)
        XCTAssertEqual(AgaraCloudSync.mapping.dayString(stamp, calendar: karachi), "2026-09-17")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(AgaraCloudSync.mapping.dayString(stamp, calendar: utc), "2026-09-16")
    }

    // MARK: Row → event mapping (the pull's semantics)

    func testCloudDayMapsToActivityAndSleep() {
        let day: [String: Any] = [
            "date": "2026-09-16", "steps": 11_556, "distance_km": 8.666, "calories": 389.5,
            "sleep_start": 1_789_500_000, "sleep_end": 1_789_520_000,
            "deep": 70, "light": 250, "awake": 5, "other": 60,
        ]
        let events = AgaraCloudSync.mapping.events(days: [day], measurements: [])

        guard case let .activityUpdate(_, steps, distanceMeters, calories)? = events.first else {
            return XCTFail("expected an activity update first")
        }
        XCTAssertEqual(steps, 11_556)
        XCTAssertEqual(Int(distanceMeters), 8_666)
        XCTAssertEqual(calories, 389.5, accuracy: 0.01)

        guard case let .sleepTimeline(_, stages)? = events.last else {
            return XCTFail("expected a sleep timeline")
        }
        XCTAssertEqual(stages.count, 385)                              // 70 + 250 + 5 + 60
        XCTAssertEqual(stages.filter { $0 == .deep }.count, 70)
        XCTAssertEqual(stages.filter { $0 == .light }.count, 250)
        XCTAssertEqual(stages.filter { $0 == .awake }.count, 5)
        XCTAssertEqual(stages.filter { $0 == .unknown }.count, 60)
    }

    func testDayWithoutANightStillYieldsActivityAndBadDatesAreSkipped() {
        let events = AgaraCloudSync.mapping.events(
            days: [["date": "2026-09-16", "steps": 100, "sleep_start": 0, "sleep_end": 0],
                   ["date": "not-a-date"]],
            measurements: []
        )
        XCTAssertEqual(events.count, 1)
        if case .activityUpdate = events[0] {} else { XCTFail("expected only the activity update") }
    }

    func testMeasurementsMapByKindAndUnknownKindsAreDropped() {
        let events = AgaraCloudSync.mapping.events(days: [], measurements: [
            ["kind": "hr", "value": 72.0, "timestamp": 1_789_600_000],
            ["kind": "spo2", "value": 98.0, "timestamp": 1_789_600_060],
            ["kind": "not_a_kind", "value": 1.0, "timestamp": 1_789_600_000],
            ["kind": "hrv", "timestamp": 1_789_600_000],                 // no value
        ])
        XCTAssertEqual(events.count, 2)
        guard case let .historyMeasurement(kind, value, _)? = events.first else {
            return XCTFail("expected a history measurement")
        }
        XCTAssertEqual(kind, .heartRate)
        XCTAssertEqual(value, 72)
    }

    // MARK: Client contract against a stub server

    @MainActor
    func testSignInStoresTheSessionFromTheAuthReply() async throws {
        StubURLProtocol.responses = [(
            "auth-with-password", 200,
            #"{"token":"tok123","record":{"id":"user1","email":"a@agara.io"}}"#
        )]
        let (client, session) = makeClient()

        try await client.signIn(email: "a@agara.io", password: "password123")

        XCTAssertTrue(client.isSignedIn)
        XCTAssertEqual(client.userID, "user1")
        XCTAssertEqual(session.email, "a@agara.io")
        XCTAssertEqual(StubURLProtocol.requestedPaths.first, "/api/collections/users/auth-with-password")
    }

    @MainActor
    func testListPagesThroughEveryRecord() async throws {
        // The bug this guards: perPage=500 in one request silently truncated, so a push re-created
        // thousands of "unknown" keys and died on the server's unique index.
        StubURLProtocol.responses = [
            ("page=1", 200, #"{"page":1,"perPage":2,"totalItems":3,"totalPages":2,"items":[{"id":"a","client_key":"hr-1-live"},{"id":"b","client_key":"hr-2-live"}]}"#),
            ("page=2", 200, #"{"page":2,"perPage":2,"totalItems":3,"totalPages":2,"items":[{"id":"c","client_key":"hr-3-live"}]}"#),
        ]
        let (client, session) = makeClient()
        session.saveSession(token: "tok123", userID: "user1", email: "a@agara.io")

        let items = try await client.list(AgaraConfig.Cloud.measurementsCollection,
                                          filter: "user='user1'", perPage: 2)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["a", "b", "c"])
        XCTAssertEqual(StubURLProtocol.requestedPaths.count, 2)
    }

    @MainActor
    func testEmptyPageEndsThePagingLoopEvenWhenMorePagesAreClaimed() async throws {
        StubURLProtocol.responses = [
            ("page=1", 200, #"{"page":1,"perPage":2,"totalItems":9,"totalPages":5,"items":[]}"#),
        ]
        let (client, _) = makeClient()
        let items = try await client.list(AgaraConfig.Cloud.measurementsCollection, perPage: 2)
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(StubURLProtocol.requestedPaths.count, 1)
    }

    @MainActor
    func testFieldErrorSurfacesTheServersOwnSentence() async throws {
        StubURLProtocol.responses = [(
            "users/records", 400,
            #"{"message":"Failed to create record.","data":{"password":{"code":"validation_min_text_constraint","message":"Must be at least 8 character(s)"}}}"#
        )]
        let (client, _) = makeClient()

        do {
            try await client.register(email: "a@agara.io", password: "short")
            XCTFail("expected a CloudError")
        } catch let error as AgaraCloudClient.CloudError {
            XCTAssertEqual(error.errorDescription, "Must be at least 8 character(s)")
        }
    }

    @MainActor
    func testPlainMessageErrorAndSignOutClearsTheSession() async throws {
        StubURLProtocol.responses = [("auth-with-password", 400, #"{"message":"Failed to authenticate."}"#)]
        let (client, session) = makeClient()

        do {
            try await client.signIn(email: "a@agara.io", password: "wrongpassword")
            XCTFail("expected a CloudError")
        } catch let error as AgaraCloudClient.CloudError {
            XCTAssertEqual(error.errorDescription, "Failed to authenticate.")
        }

        session.saveSession(token: "t", userID: "u", email: "e")
        client.signOut()
        XCTAssertFalse(client.isSignedIn)
        XCTAssertNil(session.userID)
    }

    @MainActor
    func testTheDefaultEndpointComesFromTheSharedConfigCatalog() {
        let client = AgaraCloudClient(store: MemorySession())
        XCTAssertEqual(client.baseURL.absoluteString, AgaraConfig.Cloud.baseUrl)
        XCTAssertTrue(client.baseURL.absoluteString.hasPrefix("https://"))
    }
}
