import Foundation
import XCTest
@testable import PulseLoop

// MARK: - Helpers

/// A `ResponsesClient` that only needs to exist: the routing tests assert which client was built, never run one.
private struct InertClient: ResponsesClient {
    func send(requestBody: Data) async throws -> OpenAIResponse {
        OpenAIResponse(id: "inert", outputItems: [])
    }
}

private struct StubKeyStore: APIKeyStore {
    var key: String?
    func readKey() throws -> String? { key }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

/// A minimal but complete context packet, so the tests exercise the real `CoachPromptBuilder.developerMessage` text
/// the proxy client has to read the packet back out of.
@MainActor
private func samplePacket(summary: String? = nil) -> CoachContextPacket {
    CoachContextPacket(
        generatedAt: "2026-10-20T07:12:00Z",
        timezone: "Europe/Berlin",
        profile: .init(name: "Rafay", age: 34, sex: "male", heightCm: 180, weightKg: 78.5,
                       units: "metric", completeness: "complete"),
        device: .init(name: "Agara Ring", batteryPercent: 62, state: "connected",
                      lastConnectedAt: "2026-10-20T06:55:00Z", lastSyncAt: "2026-10-20T06:58:00Z"),
        goals: .init(stepsDaily: 8000, activeMinutesDaily: 30, sleepHours: 7.5, exerciseDaysWeekly: 4),
        today: .init(localDate: "2026-10-20", steps: 2400, calories: 910, distanceKm: 1.9,
                     activeMinutes: 12, dataConfidence: "medium"),
        lastSevenDays: .init(daysAvailable: 7, avgSteps: 8100, totalSteps: 56_700, activeMinutesTotal: 210,
                             exerciseDays: 4, mostActiveDay: "2026-10-18"),
        latestVitals: .init(latestHr: 58, latestHrAt: "2026-10-20T06:57:00Z", latestSpo2: 97,
                            latestSpo2At: "2026-10-20T06:57:00Z", restingHrEstimate: 54, peakHrToday: 96),
        latestSleep: .init(date: "2026-10-19", dayTotalMin: 431, deepMin: 78, lightMin: 320, awakeMin: 33,
                           score: 82, confidence: "high", decoderNote: "REM not decoded", napMin: nil),
        recentWorkouts: [],
        memories: [.init(type: "preference", key: "training", value: "prefers morning runs", importance: 2)],
        conversationSummary: summary,
        dataQualityWarnings: [],
        environment: nil,
        nutrition: nil)
}

/// The request body the orchestrator builds for a turn — the input the proxy client adapts.
@MainActor
private func orchestratorBody(
    packet: CoachContextPacket,
    userText: String,
    history: [(role: String, text: String)] = [],
    images: [CoachImagePayload] = [],
    previousResponseId: String? = nil
) throws -> Data {
    var input: [[String: Any]] = [
        OpenAIRequestBuilder.message(role: "system", content: CoachPromptBuilder.systemPrompt),
        OpenAIRequestBuilder.message(role: "developer", content: CoachPromptBuilder.developerMessage(packet: packet)),
    ]
    for message in history {
        input.append(OpenAIRequestBuilder.message(role: message.role, content: message.text))
    }
    input.append(OpenAIRequestBuilder.message(role: "user", content: userText, images: images))
    return try OpenAIRequestBuilder.data(
        model: "gpt-5.4", input: input, tools: [], textFormat: nil,
        previousResponseId: previousResponseId, reasoningEffort: nil)
}

/// One tool round of the orchestrator's loop: only `function_call_output` items.
@MainActor
private func continuationBody(_ outputs: [(callID: String, output: String)]) throws -> Data {
    let input = outputs.map { OpenAIRequestBuilder.functionCallOutput(callID: $0.callID, output: $0.output) }
    return try OpenAIRequestBuilder.data(
        model: "gpt-5.4", input: input, tools: [], textFormat: nil,
        previousResponseId: "01JCH0A2T9W6V3K4R5M8N7P0QB", reasoningEffort: nil)
}

private func json(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
}

private func answerJSON(title: String = "Sleep") -> String {
    """
    {"response_type":"insight","title":"\(title)","summary":"You slept 7h11m.","bullets":["Deep sleep 78m"],\
    "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
    "follow_up_chips":["Why?","Tonight?","Trend?"],"actions_taken":[],"confidence":"high"}
    """
}

/// A `CloudTransport` for the coach proxy: scripted coach replies plus Firebase's token refresh endpoint. Every
/// request is recorded, so the tests can assert on headers and bodies — including that no body carries key material.
private final class CoachProxyTransport: CloudTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
        /// Server-sent `delta` payloads delivered before the reply (a streamed answer, 2026-10-23).
        var deltas: [String] = []
    }

    /// Streams a reply's deltas through `onEvent`, then answers like `send` (the terminal event's response).
    func stream(_ request: CloudRequest, onEvent: @escaping @Sendable (String, Data) -> Void) async throws -> CloudResponse {
        let deltas: [String] = lock.withLock {
            (request.url.host ?? "").contains("securetoken") ? [] : (replies.first?.deltas ?? [])
        }
        for d in deltas { onEvent("delta", Data(d.utf8)) }
        return try await send(request)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [CloudRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [CloudRequest] { lock.withLock { recorded } }
    var coachRequests: [CloudRequest] { requests.filter { $0.url.path.contains("coach") } }
    var refreshCount: Int { requests.filter { ($0.url.host ?? "").contains("securetoken") }.count }

    func send(_ request: CloudRequest) async throws -> CloudResponse {
        try lock.withLock {
            if (request.url.host ?? "").contains("securetoken") {
                recorded.append(request)
                return CloudResponse(status: 200, headers: [:], body: Data("""
                {"id_token":"refreshed-id-token","refresh_token":"refresh-2","expires_in":"3600","user_id":"uid-1"}
                """.utf8))
            }
            recorded.append(request)
            guard !replies.isEmpty else {
                return CloudResponse(status: 500, headers: [:], body: Data(#"{"code":"coach_upstream"}"#.utf8))
            }
            let reply = replies.removeFirst()
            return CloudResponse(status: reply.status, headers: reply.headers, body: Data(reply.body.utf8))
        }
    }
}

private let coachConfig = AgaraCloudConfig(
    firebaseApiKey: "test-api-key", firebaseProjectId: "test-project",
    baseURL: URL(string: "https://coach.test")!, syncIntervalMinutes: 60,
    retryBackoffSeconds: [30], verifyPollSeconds: 1)

/// A signed-in session whose token is still valid, so `validIdToken()` never touches the network by itself.
private func signedInAuth(_ transport: CoachProxyTransport) -> AgaraAuthClient {
    let session = AgaraAuthSession(
        uid: "uid-1", email: "user@example.com", idToken: "stored-id-token", refreshToken: "refresh-1",
        expiresAt: Date().addingTimeInterval(3600), emailVerified: true)
    return AgaraAuthClient(config: coachConfig, transport: transport, store: AgaraMemoryAuthStore(session), bundleId: nil)
}

// MARK: - CoachGate

final class CoachGateTests: XCTestCase {
    private func ready(flag: Bool = true, user: Bool = true,
                       signedIn: Bool = true, verified: Bool = true, consented: Bool = true) -> Bool {
        CoachGate.cloudReady(
            flagOn: flag, userOn: user,
            account: .init(signedIn: signedIn, emailVerified: verified, consented: consented))
    }

    func testCloudCoachNeedsEveryCondition() {
        XCTAssertTrue(ready())
        XCTAssertFalse(ready(flag: false), "coach_cloud flag off")
        XCTAssertFalse(ready(user: false), "the user's master switch off")
        XCTAssertFalse(ready(signedIn: false), "signed out")
        XCTAssertFalse(ready(verified: false), "e-mail not verified")
        XCTAssertFalse(ready(consented: false), "no cloud consent")
    }
}

// MARK: - Routing

@MainActor
final class CoachProviderRoutingTests: XCTestCase {
    private func resolve(_ mode: CoachProviderMode, channel: CoachBuildChannel, ready: Bool)
        -> (key: String?, client: ResponsesClient) {
        var settings = CoachSettings.default
        settings.providerMode = mode
        return CoachClientResolver.resolve(
            settings: settings,
            openAIKeyStore: StubKeyStore(key: "stub-openai"),
            geminiKeyStore: StubKeyStore(key: "stub-gemini"),
            openRouterKeyStore: StubKeyStore(key: "stub-openrouter"),
            minimaxKeyStore: StubKeyStore(key: "stub-minimax"),
            localKeyStore: StubKeyStore(key: nil),
            openAIClientFactory: { _ in InertClient() },
            channel: channel,
            cloud: CoachCloudWiring(isReady: ready, makeClient: { InertClient() }))
    }

    func testReleaseOffersOnlyTheCloudCoachAndOnDevice() {
        XCTAssertEqual(CoachBuildChannel.release.offeredModes, [.agaraCloud, .appleOnDevice])
        XCTAssertEqual(CoachBuildChannel.debug.offeredModes, CoachProviderMode.allCases)
    }

    func testReleaseSendsABringYourOwnKeySettingToTheCloudCoach() {
        for mode: CoachProviderMode in [.userOpenAIKey, .userGeminiKey, .userOpenRouterKey, .userMiniMaxKey,
                                        .localOpenAICompat, .backendProxy] {
            let routed = resolve(mode, channel: .release, ready: true)
            XCTAssertEqual(routed.key, "agara-cloud", "\(mode) with the gate open")
            XCTAssertTrue(routed.client is InertClient, "\(mode) must not reach a bring-your-own-key client")
        }
    }

    func testReleaseFallsBackToOnDeviceWhenTheCloudGateIsClosed() {
        for mode: CoachProviderMode in [.agaraCloud, .userOpenAIKey, .userGeminiKey, .userOpenRouterKey,
                                        .userMiniMaxKey, .localOpenAICompat] {
            let routed = resolve(mode, channel: .release, ready: false)
            XCTAssertTrue(routed.client is AppleFoundationModelsClient, "\(mode) with the gate closed")
        }
    }

    func testReleaseKeepsAnExplicitOnDeviceChoice() {
        let routed = resolve(.appleOnDevice, channel: .release, ready: true)
        XCTAssertTrue(routed.client is AppleFoundationModelsClient)
        XCTAssertNotEqual(routed.key, "agara-cloud")
    }

    func testDebugHonoursEveryStoredProvider() {
        // Debug builds keep every bring-your-own-key / self-hosted choice: only the keyed client is built from the
        // injected factory, the others build their own client — what must hold for all of them is that a debug turn is
        // neither the cloud coach nor the on-device model.
        for mode: CoachProviderMode in [.userOpenAIKey, .userGeminiKey, .userOpenRouterKey, .userMiniMaxKey,
                                        .localOpenAICompat, .backendProxy] {
            let routed = resolve(mode, channel: .debug, ready: true)
            XCTAssertFalse(routed.client is AppleFoundationModelsClient, "\(mode) stays a bring-your-own-key turn")
            XCTAssertNotEqual(routed.key, "agara-cloud", "\(mode) must not be routed to the cloud coach")
        }
        XCTAssertTrue(resolve(.userOpenAIKey, channel: .debug, ready: true).client is InertClient)
        XCTAssertTrue(resolve(.backendProxy, channel: .debug, ready: true).client is InertClient)
    }

    func testDebugCloudCoachStillNeedsTheGate() {
        XCTAssertEqual(resolve(.agaraCloud, channel: .debug, ready: true).key, "agara-cloud")
        // With the gate closed the rule falls back to the on-device model — the same rule release uses — so the
        // sentinel is "on-device" (or nil when that model is unavailable here), never the cloud one.
        let blocked = resolve(.agaraCloud, channel: .debug, ready: false)
        XCTAssertNotEqual(blocked.key, "agara-cloud")
        XCTAssertTrue(blocked.client is AppleFoundationModelsClient)
    }

    /// The live wiring builds the real proxy client, so the release default really is the Agara cloud coach.
    func testLiveWiringBuildsTheProxyClientWhenTheGatePasses() {
        let live = CoachCloudWiring(isReady: true, makeClient: {
            AgaraCoachProxyClient(config: coachConfig, auth: signedInAuth(CoachProxyTransport([])))
        })
        var settings = CoachSettings.default
        settings.providerMode = .agaraCloud
        let routed = CoachClientResolver.resolve(
            settings: settings, openAIKeyStore: StubKeyStore(key: nil), geminiKeyStore: StubKeyStore(key: nil),
            openRouterKeyStore: StubKeyStore(key: nil), minimaxKeyStore: StubKeyStore(key: nil),
            localKeyStore: StubKeyStore(key: nil), openAIClientFactory: { _ in InertClient() },
            channel: .release, cloud: live)
        XCTAssertEqual(routed.key, "agara-cloud")
        XCTAssertTrue(routed.client is AgaraCoachProxyClient)
    }

    func testTheCloudCoachDoesNotOfferImageInput() {
        // Keyed off the EFFECTIVE provider: the cloud coach never gets an image, and with the gate open there is no
        // camera for it; when the gate is closed a release build is on the on-device model, where images are allowed.
        var settings = CoachSettings.default
        settings.providerMode = .agaraCloud
        settings.enableImageInput = true
        XCTAssertFalse(CoachFeatureFlags(settings: settings, hasAPIKey: true, cloudReadyOverride: true).imageInputEnabled)
        XCTAssertTrue(CoachFeatureFlags(settings: settings, hasAPIKey: true, cloudReadyOverride: false).imageInputEnabled)
        // A stored bring-your-own-key mode in a debug build is NOT the cloud coach, so the camera stays.
        settings.providerMode = .userOpenAIKey
        XCTAssertTrue(CoachFeatureFlags(settings: settings, hasAPIKey: true, cloudReadyOverride: false).imageInputEnabled)
    }
}

// MARK: - Errors

final class CoachCloudFailureTests: XCTestCase {
    private let table: [(status: Int, code: String, kind: CoachTurnError.Kind)] = [
        (400, "coach_bad_request", .badRequest),
        (400, "coach_version", .version),
        (401, "coach_unauthorized", .unauthorized),
        (403, "email_not_verified", .emailNotVerified),
        (403, "coach_disabled", .disabled),
        (409, "coach_busy", .busy),
        (409, "coach_turn_expired", .turnExpired),
        (413, "coach_too_large", .tooLarge),
        (429, "coach_quota_minute", .quotaMinute),
        (429, "coach_quota_day", .quotaDay),
        (429, "coach_quota_month", .quotaMonth),
        (429, "coach_cost_cap", .costCap),
        (429, "coach_ip_limit", .ipLimit),
        (503, "coach_breaker", .breaker),
        (502, "coach_upstream", .upstream),
        (502, "coach_bad_answer", .badAnswer),
    ]

    func testEveryContractErrorCodeMapsToItsOwnKind() throws {
        var kinds: Set<CoachTurnError.Kind> = []
        for row in table {
            let body = Data(#"{"code":"\#(row.code)","message":"server sentence"}"#.utf8)
            let failure = CoachCloudFailure.from(status: row.status, body: body)
            XCTAssertEqual(failure.kind, row.kind, "\(row.status) \(row.code)")
            XCTAssertEqual(failure.code, row.code)
            kinds.insert(failure.kind)
        }
        XCTAssertEqual(kinds.count, table.count, "each code keeps its own typed case")
        XCTAssertEqual(CoachTurnError.Kind.allCodesForTesting.count, table.count)
    }

    func testUnknownCodeFallsBackToItsStatus() {
        let cases: [(Int, CoachTurnError.Kind)] = [
            (400, .badRequest), (401, .unauthorized), (403, .disabled), (409, .busy), (413, .tooLarge),
            (429, .quotaDay), (502, .upstream), (503, .breaker), (500, .upstream),
        ]
        for (status, kind) in cases {
            let failure = CoachCloudFailure.from(status: status, body: Data(#"{"code":"something_new"}"#.utf8))
            XCTAssertEqual(failure.kind, kind, "HTTP \(status)")
            XCTAssertTrue(CoachTurnError(failure).kind == kind)
        }
    }

    func testTheServersUserSafeSentenceWins() {
        let failure = CoachCloudFailure.from(
            status: 429, body: Data(#"{"code":"coach_quota_day","message":"You have 0 of 30 coach turns left today."}"#.utf8))
        let error = CoachTurnError(failure)
        XCTAssertEqual(error.kind, .quotaDay)
        XCTAssertEqual(error.code, "Daily limit")
        XCTAssertEqual(error.reason, "You have 0 of 30 coach turns left today.")
    }

    func testResetAndRetryHintsAreAppended() {
        let quota = CoachCloudFailure.from(
            status: 429,
            body: Data(#"{"code":"coach_quota_day","message":"No turns left.","reset_at":"2026-10-21T00:00:00Z"}"#.utf8))
        XCTAssertNotNil(quota.resetAt)
        XCTAssertTrue(CoachTurnError(quota).reason.hasPrefix("No turns left. Resets "), CoachTurnError(quota).reason)

        let minute = CoachCloudFailure.from(
            status: 429, body: Data(#"{"code":"coach_quota_minute","retry_after_seconds":42}"#.utf8))
        XCTAssertEqual(minute.retryAfter, 42)
        XCTAssertTrue(CoachTurnError(minute).reason.hasSuffix("Try again in 42 seconds."), CoachTurnError(minute).reason)

        let header = CoachCloudFailure.from(status: 429, body: Data(#"{"code":"coach_cost_cap"}"#.utf8),
                                            headers: ["Retry-After": "120"])
        XCTAssertEqual(header.retryAfter, 120)
        XCTAssertTrue(CoachTurnError(header).reason.hasSuffix("Try again in 2 minutes."), CoachTurnError(header).reason)
    }

    func testStoredCloudErrorsStillDecodeWithoutAKind() throws {
        // A bubble stored before `kind` existed must keep rendering.
        let legacy = #"{"code":"HTTP 429","reason":"Rate limited"}"#
        let decoded = try XCTUnwrap(CoachTurnError.decode(fromJSON: legacy))
        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.code, "HTTP 429")
        XCTAssertEqual(decoded.reason, "Rate limited")
    }
}

// MARK: - Quota

final class CoachQuotaTests: XCTestCase {
    func testReadsEveryQuotaHeader() throws {
        let quota = try XCTUnwrap(CoachQuota(headers: [
            "X-Coach-Remaining-Day": "24",
            "X-Coach-Remaining-Minute": "2",
            "x-coach-remaining-month": "371",       // header names are case-insensitive
            "X-Coach-Day-Resets-At": "2026-10-21T00:00:00Z",
        ]))
        XCTAssertEqual(quota.remainingDay, 24)
        XCTAssertEqual(quota.remainingMinute, 2)
        XCTAssertEqual(quota.remainingMonth, 371)
        XCTAssertNotNil(quota.dayResetsAt)
    }

    func testWithoutTheDayHeaderThereIsNoQuota() {
        // Never fabricate a zero: the UI keeps the last quota it knew.
        XCTAssertNil(CoachQuota(headers: ["X-Coach-Remaining-Minute": "2"]))
        XCTAssertNil(CoachQuota(headers: [:]))
    }

    func testDayHeaderAloneIsEnough() throws {
        let quota = try XCTUnwrap(CoachQuota(headers: ["X-Coach-Remaining-Day": "3"]))
        XCTAssertEqual(quota.remainingDay, 3)
        XCTAssertNil(quota.remainingMinute)
        XCTAssertNil(quota.dayResetsAt)
    }
}

// MARK: - Request bodies

@MainActor
final class CoachCloudRequestTests: XCTestCase {
    func testRoundOneCarriesTheContractsFields() throws {
        let body = try orchestratorBody(
            packet: samplePacket(),
            userText: "how did I sleep last night?",
            history: [("user", "hi"), ("assistant", "hello")])
        let input = try XCTUnwrap((try json(body))["input"] as? [[String: Any]])
        let opening = CoachCloudRequest.opening(from: input, fallback: nil)

        XCTAssertEqual(opening.message, "how did I sleep last night?")
        XCTAssertEqual(opening.history.count, 2, "the system/developer items never become history")
        XCTAssertEqual(opening.history.first?["role"] as? String, "user")
        XCTAssertEqual(opening.history.last?["role"] as? String, "assistant")
        XCTAssertEqual(opening.history.last?["text"] as? String, "hello")
        XCTAssertNil(opening.summary)
        // The trimmer's projection (§5): today's local date, and no timezone (a coarse location proxy §5 does not list).
        XCTAssertEqual((opening.context["today"] as? [String: Any])?["local_date"] as? String, "2026-10-20")
        XCTAssertNil(opening.context["timezone"])

        let sent = try json(try CoachCloudRequest.openingBody(
            opening, client: ["app": "ios", "version": "1.1.0", "build": "1010001"]))
        XCTAssertEqual(sent["contract"] as? Int, 1)
        XCTAssertEqual(sent["message"] as? String, "how did I sleep last night?")
        let client = try XCTUnwrap(sent["client"] as? [String: Any])
        XCTAssertEqual(client["app"] as? String, "ios")
        XCTAssertEqual(client["version"] as? String, "1.1.0")
        XCTAssertNotNil(sent["context"] as? [String: Any])
        XCTAssertEqual((sent["history"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(sent["summary"])
        // The server builds the prompt and the schemas (§6): nothing of the orchestrator's own gets sent.
        for ignored in ["messages", "system", "tools", "tool_choice", "response_format", "model", "input"] {
            XCTAssertNil(sent[ignored], "\(ignored) must not reach the proxy")
        }
    }

    func testRoundOneDropsTheProfileNameAndEveryImage() throws {
        let image = CoachImagePayload(dataURL: "data:image/jpeg;base64,AAAA", rawBase64: "AAAA", mimeType: "image/jpeg")
        let body = try orchestratorBody(packet: samplePacket(), userText: "what is this?", images: [image])
        let input = try XCTUnwrap((try json(body))["input"] as? [[String: Any]])
        let opening = CoachCloudRequest.opening(from: input, fallback: nil)

        XCTAssertEqual(opening.message, "what is this?", "only the text part of an image message is kept")
        let profile = try XCTUnwrap(opening.context["profile"] as? [String: Any])
        XCTAssertNil(profile["name"], "the profile name never leaves the device (§5)")
        XCTAssertEqual(profile["age"] as? Int, 34)

        let contextText = String(decoding: try JSONSerialization.data(withJSONObject: opening.context), as: UTF8.self)
        XCTAssertFalse(contextText.contains("Rafay"))
        XCTAssertFalse(contextText.contains("base64"))
        XCTAssertFalse(contextText.contains("input_image"))
    }

    func testRoundOneKeepsTheContractsHistoryWindow() throws {
        let long = (0..<14).map { ("user" as String, "message \($0)" as String) }
        let body = try orchestratorBody(packet: samplePacket(), userText: "and now?", history: long)
        let input = try XCTUnwrap((try json(body))["input"] as? [[String: Any]])
        let opening = CoachCloudRequest.opening(from: input, fallback: nil)
        XCTAssertEqual(opening.history.count, AgaraConfig.Coach.historyTurns)
        XCTAssertEqual(opening.history.last?["text"] as? String, "message 13", "the tail is kept")
    }

    func testRoundOneCarriesTheConversationSummary() throws {
        let body = try orchestratorBody(packet: samplePacket(summary: "Two weeks of improving sleep."),
                                        userText: "and today?")
        let input = try XCTUnwrap((try json(body))["input"] as? [[String: Any]])
        let opening = CoachCloudRequest.opening(from: input, fallback: nil)
        XCTAssertEqual(opening.summary, "Two weeks of improving sleep.")

        let plain = try orchestratorBody(packet: samplePacket(), userText: "and today?")
        let plainInput = try XCTUnwrap((try json(plain))["input"] as? [[String: Any]])
        XCTAssertNil(CoachCloudRequest.opening(from: plainInput, fallback: nil).summary)
    }

    func testARepairSendReusesTheTurnsContext() throws {
        let first = try orchestratorBody(packet: samplePacket(), userText: "how did I sleep?")
        let firstInput = try XCTUnwrap((try json(first))["input"] as? [[String: Any]])
        let opening = CoachCloudRequest.opening(from: firstInput, fallback: nil)

        // The orchestrator's schema-repair send: one bare user message, no packet.
        let repair = try orchestratorBody(packet: samplePacket(), userText: "Return only valid JSON now.")
        let repairInput = try XCTUnwrap((try json(repair))["input"] as? [[String: Any]])
        let repaired = CoachCloudRequest.opening(from: repairInput, fallback: opening)
        XCTAssertEqual(repaired.message, "Return only valid JSON now.")
        XCTAssertEqual((repaired.context["today"] as? [String: Any])?["local_date"] as? String, "2026-10-20",
                       "the repair send reuses the turn's (trimmed) context")
        XCTAssertTrue(repaired.history.isEmpty)
    }

    func testContinuationCarriesTheTurnAndTheNextRound() throws {
        let body = try CoachCloudRequest.continuationBody(
            turnID: "01JCH0A2T9W6V3K4R5M8N7P0QB", round: 1,
            input: [
                OpenAIRequestBuilder.functionCallOutput(
                    callID: "call_a1", output: #"{"date":"2026-10-19","steps":10432}"#),
                OpenAIRequestBuilder.functionCallOutput(
                    callID: "call_a2", output: #"{"error":"no_data"}"#),
            ])
        let sent = try json(body)
        XCTAssertEqual(sent["contract"] as? Int, 1)
        XCTAssertEqual(sent["turn_id"] as? String, "01JCH0A2T9W6V3K4R5M8N7P0QB")
        XCTAssertEqual(sent["round"] as? Int, 2, "the contract's round is the next one")
        let results = try XCTUnwrap(sent["tool_results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0]["call_id"] as? String, "call_a1")
        let output = try XCTUnwrap(results[0]["output"] as? [String: Any])
        XCTAssertEqual(output["steps"] as? Int, 10432, "the tool's JSON rides as an object, not a string")
        XCTAssertEqual((results[1]["output"] as? [String: Any])?["error"] as? String, "no_data")
    }

    func testReplyMapsToolCallsIntoFunctionCalls() throws {
        let reply = try CoachCloudRequest.reply([
            "turn_id": "t1", "round": 1, "status": "tool_calls", "remaining_rounds": 3,
            "tool_calls": [["call_id": "call_a1", "name": "get_daily_summary", "arguments": ["date": "2026-10-19"]]],
            "answer": NSNull(),
        ])
        XCTAssertFalse(reply.closed)
        XCTAssertEqual(reply.response.id, "t1")
        XCTAssertEqual(reply.response.functionCalls.count, 1)
        let call = try XCTUnwrap(reply.response.functionCalls.first)
        XCTAssertEqual(call.name, "get_daily_summary")
        XCTAssertEqual(call.callID, "call_a1")
        let arguments = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any])
        XCTAssertEqual(arguments["date"] as? String, "2026-10-19")
    }

    func testReplyMapsTheAnswerIntoOneMessage() throws {
        let answer = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(answerJSON().utf8))) as? [String: Any])
        let reply = try CoachCloudRequest.reply([
            "turn_id": "t2", "round": 3, "status": "answer", "tool_calls": [], "answer": answer,
        ])
        XCTAssertTrue(reply.closed)
        XCTAssertEqual(reply.response.functionCalls.count, 0)
        let parsed = try XCTUnwrap(CoachResponseParser.parse(reply.response.outputText))
        XCTAssertEqual(parsed.title, "Sleep")
    }

    func testSafetyGuidanceIsDeliveredAsAnAnswer() throws {
        let guidance = ["response_type": "safety_guidance", "summary": "Call your local emergency number now."]
        let reply = try CoachCloudRequest.reply(["turn_id": "t3", "round": 1, "status": "safety", "safety": guidance])
        XCTAssertTrue(reply.closed)
        XCTAssertFalse(reply.response.outputText.isEmpty)
        XCTAssertNotNil(CoachResponseParser.parse(reply.response.outputText))
    }
}

// MARK: - The client

@MainActor
final class AgaraCoachProxyClientTests: XCTestCase {
    private func client(_ transport: CoachProxyTransport) -> AgaraCoachProxyClient {
        AgaraCoachProxyClient(config: coachConfig, auth: signedInAuth(transport),
                              transport: transport, appVersion: "1.1.0", appBuild: "1010001")
    }

    func testATurnRunsItsToolCallsAndThenTheAnswer() async throws {
        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t1","round":1,"status":"tool_calls","remaining_rounds":3,\
            "tool_calls":[{"call_id":"call_a1","name":"get_daily_summary","arguments":{"date":"2026-10-19"}}],\
            "answer":null}
            """, headers: ["X-Coach-Remaining-Day": "24"]),
            .init(status: 200, body: """
            {"turn_id":"t1","round":2,"status":"answer","remaining_rounds":2,"tool_calls":[],\
            "answer":\(answerJSON())}
            """, headers: ["X-Coach-Remaining-Day": "23"]),
        ])
        let client = client(transport)

        let first = try await client.send(requestBody: try orchestratorBody(
            packet: samplePacket(), userText: "how did I sleep last night?"))
        XCTAssertEqual(first.functionCalls.count, 1, "the existing tool loop sees a normal function call")
        XCTAssertEqual(first.functionCalls.first?.name, "get_daily_summary")
        XCTAssertEqual(first.id, "t1")

        let second = try await client.send(requestBody: try continuationBody([
            ("call_a1", #"{"date":"2026-10-19","steps":10432}"#),
        ]))
        XCTAssertEqual(second.functionCalls.count, 0)
        XCTAssertNotNil(CoachResponseParser.parse(second.outputText))
        XCTAssertEqual(try XCTUnwrap(CoachQuotaStore.shared.quota).remainingDay, 23)

        // Round 1 opens the turn; round 2 names it and the next round.
        XCTAssertEqual(transport.coachRequests.count, 2)
        let opening = try json(try XCTUnwrap(transport.coachRequests[0].body))
        XCTAssertEqual(opening["contract"] as? Int, 1)
        XCTAssertTrue(opening["turn_id"] == nil)
        XCTAssertEqual(transport.coachRequests[0].headers["X-Agara-Coach-Version"], "1")
        XCTAssertEqual(transport.coachRequests[0].headers["Authorization"], "Bearer stored-id-token")
        XCTAssertTrue(transport.coachRequests[0].url.path.hasSuffix(AgaraConfig.Coach.path))

        let following = try json(try XCTUnwrap(transport.coachRequests[1].body))
        XCTAssertEqual(following["turn_id"] as? String, "t1")
        XCTAssertEqual(following["round"] as? Int, 2)
        XCTAssertEqual((following["tool_results"] as? [[String: Any]])?.count, 1)
    }

    func test401RefreshesTheTokenAndRetriesExactlyOnce() async throws {
        let transport = CoachProxyTransport([
            .init(status: 401, body: #"{"code":"coach_unauthorized","message":"Your session expired."}"#),
            .init(status: 200, body: """
            {"turn_id":"t1","round":1,"status":"answer","tool_calls":[],"answer":\(answerJSON())}
            """),
        ])
        let client = client(transport)
        _ = try await client.send(requestBody: try orchestratorBody(packet: samplePacket(), userText: "hi"))

        XCTAssertEqual(transport.refreshCount, 1, "one refresh")
        XCTAssertEqual(transport.coachRequests.count, 2, "and exactly one retry")
        XCTAssertEqual(transport.coachRequests[1].headers["Authorization"], "Bearer refreshed-id-token")
    }

    func testASecond401IsTheAuthorizationFailure() async throws {
        let unauthorized = #"{"code":"coach_unauthorized","message":"Your session expired."}"#
        let transport = CoachProxyTransport([
            .init(status: 401, body: unauthorized),
            .init(status: 401, body: unauthorized),
        ])
        let client = client(transport)
        do {
            _ = try await client.send(requestBody: try orchestratorBody(packet: samplePacket(), userText: "hi"))
            XCTFail("expected a failure")
        } catch {
            let error = CoachTurnError(error)
            XCTAssertEqual(error.kind, .unauthorized)
            XCTAssertEqual(error.reason, "Your session expired.")
        }
        XCTAssertEqual(transport.coachRequests.count, 2, "no third attempt")
        XCTAssertEqual(transport.refreshCount, 1)
    }

    func testAnExpiredTurnMapsToCoachTurnExpired() async throws {
        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t1","round":1,"status":"tool_calls","tool_calls":\
            [{"call_id":"call_a1","name":"get_daily_summary","arguments":{}}],"answer":null}
            """),
            .init(status: 409, body: #"{"code":"coach_turn_expired","message":"That turn expired. Ask again."}"#),
        ])
        let client = client(transport)
        _ = try await client.send(requestBody: try orchestratorBody(packet: samplePacket(), userText: "hi"))
        do {
            _ = try await client.send(requestBody: try continuationBody([("call_a1", #"{"steps":1}"#)]))
            XCTFail("expected a failure")
        } catch {
            let error = CoachTurnError(error)
            XCTAssertEqual(error.kind, .turnExpired)
            XCTAssertEqual(error.code, "Answer expired")
        }
    }

    func testAContinuationWithoutALocalTurnIsCoachTurnExpired() async throws {
        let transport = CoachProxyTransport([])
        let client = client(transport)
        do {
            _ = try await client.send(requestBody: try continuationBody([("call_a1", #"{"steps":1}"#)]))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(CoachTurnError(error).kind, .turnExpired)
        }
        XCTAssertTrue(transport.coachRequests.isEmpty, "nothing is replayed to the server")
    }

    /// The Today/Sleep card summaries and the coach notifications send system + developer only. The proxy refused each
    /// with coach_bad_request (two in production, 2026-10-23); the client now fails before the network and the card
    /// keeps its scripted copy.
    func testARequestWithoutAUserMessageNeverReachesTheServer() async throws {
        let transport = CoachProxyTransport([])
        let client = client(transport)
        let body = try OpenAIRequestBuilder.data(
            model: "agara-cloud",
            input: [OpenAIRequestBuilder.message(role: "system", content: "Write a card."),
                    OpenAIRequestBuilder.message(role: "developer", content: "{\"steps\":8214}")],
            tools: [], textFormat: [:], previousResponseId: nil, reasoningEffort: nil)
        do {
            _ = try await client.send(requestBody: body)
            XCTFail("expected a local failure")
        } catch {
            XCTAssertEqual(CoachTurnError(error).kind, .badRequest)
        }
        XCTAssertTrue(transport.coachRequests.isEmpty, "no request without a user message reaches the proxy")
    }

    /// Streaming (2026-10-23): the request asks for server-sent events, each `delta` grows the Coach tab's preview, and
    /// the final event's answer is what the orchestrator gets.
    @MainActor
    func testAStreamedAnswerFeedsThePreviewAndStillAnswers() async throws {
        CoachStreamStore.shared.reset()
        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t1","round":1,"status":"answer","remaining_rounds":3,"tool_calls":[],"answer":\(answerJSON())}
            """, deltas: [#"{"field":"title","text":"Your "}"#, #"{"field":"title","text":"sleep"}"#,
                          #"{"field":"summary","text":"6 h 42 m, "}"#, #"{"field":"summary","text":"steady."}"#]),
        ])
        let client = client(transport)
        let reply = try await client.send(requestBody: try orchestratorBody(
            packet: samplePacket(), userText: "how did I sleep last night?"))
        XCTAssertNotNil(CoachResponseParser.parse(reply.outputText), "the final event is the answer")
        XCTAssertEqual(transport.coachRequests.first?.headers["Accept"], "text/event-stream, application/json")
        for _ in 0..<20 where CoachStreamStore.shared.summary != "6 h 42 m, steady." { await Task.yield() }
        XCTAssertEqual(CoachStreamStore.shared.title, "Your sleep")
        XCTAssertEqual(CoachStreamStore.shared.summary, "6 h 42 m, steady.")
        CoachStreamStore.shared.reset()
        XCTAssertFalse(CoachStreamStore.shared.hasPreview)
    }

    func testTheTurnIsClosedWhenTheAnswerArrives() async throws {
        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t1","round":1,"status":"answer","tool_calls":[],"answer":\(answerJSON())}
            """),
        ])
        let client = client(transport)
        _ = try await client.send(requestBody: try orchestratorBody(packet: samplePacket(), userText: "hi"))
        // The turn is closed: a stray continuation cannot reuse its id.
        do {
            _ = try await client.send(requestBody: try continuationBody([("call_a1", "{}")]))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(CoachTurnError(error).kind, .turnExpired)
        }
        XCTAssertEqual(transport.coachRequests.count, 1)
    }

    func testEveryErrorCodeSurfacesAsItsOwnBubble() async throws {
        let rows: [(status: Int, code: String, kind: CoachTurnError.Kind)] = [
            (400, "coach_bad_request", .badRequest), (400, "coach_version", .version),
            (403, "email_not_verified", .emailNotVerified), (403, "coach_disabled", .disabled),
            (409, "coach_busy", .busy), (413, "coach_too_large", .tooLarge),
            (429, "coach_quota_minute", .quotaMinute), (429, "coach_quota_day", .quotaDay),
            (429, "coach_quota_month", .quotaMonth), (429, "coach_cost_cap", .costCap),
            (429, "coach_ip_limit", .ipLimit), (503, "coach_breaker", .breaker),
            (502, "coach_upstream", .upstream), (502, "coach_bad_answer", .badAnswer),
        ]
        for row in rows {
            let transport = CoachProxyTransport([
                .init(status: row.status, body: #"{"code":"\#(row.code)","message":"Server says: \#(row.code)."}"#),
            ])
            do {
                _ = try await client(transport).send(
                    requestBody: try orchestratorBody(packet: samplePacket(), userText: "hi"))
                XCTFail("expected \(row.code) to throw")
            } catch {
                let bubble = CoachTurnError(error)
                XCTAssertEqual(bubble.kind, row.kind, row.code)
                XCTAssertEqual(bubble.reason, "Server says: \(row.code).", "the server's user-safe sentence is used")
            }
        }
    }

    func testNoRequestBodyCarriesKeyMaterial() async throws {
        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t1","round":1,"status":"tool_calls","tool_calls":\
            [{"call_id":"c","name":"get_daily_summary","arguments":{}}],"answer":null}
            """),
            .init(status: 200, body: """
            {"turn_id":"t1","round":2,"status":"answer","tool_calls":[],"answer":\(answerJSON())}
            """),
            .init(status: 429, body: #"{"code":"coach_quota_day","message":"No turns left."}"#),
        ])
        let client = client(transport)
        _ = try await client.send(requestBody: try orchestratorBody(packet: samplePacket(), userText: "hi"))
        _ = try await client.send(requestBody: try continuationBody([("c", #"{"steps":1}"#)]))
        _ = try? await client.send(requestBody: try orchestratorBody(packet: samplePacket(), userText: "again"))

        XCTAssertGreaterThanOrEqual(transport.requests.count, 3)
        let forbidden = ["sk-", "sk_", "oc_sk_", "opencode.ai", "api.openai.com", "api.anthropic.com", "AIza"]
        for request in transport.requests {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            for token in forbidden {
                XCTAssertFalse(body.localizedCaseInsensitiveContains(token),
                               "\(token) appeared in a request body: \(body.prefix(200))")
            }
            // The only credential is the bearer header, never the body.
            XCTAssertFalse(body.contains("stored-id-token"))
            XCTAssertFalse(body.contains("refreshed-id-token"))
        }
    }
}

// MARK: - Test support

extension CoachTurnError.Kind {
    /// Every case, for the mapping test to prove the table is complete.
    static var allCodesForTesting: [CoachTurnError.Kind] {
        [.badRequest, .version, .unauthorized, .emailNotVerified, .disabled, .busy, .turnExpired, .tooLarge,
         .quotaMinute, .quotaDay, .quotaMonth, .costCap, .ipLimit, .breaker, .upstream, .badAnswer]
    }
}

// MARK: - What leaves the phone (contract §5), measured on the wire

/// §5 lists what the server must never receive. The context packet was trimmed and tested, but tool RESULTS went out
/// as the tools produced them — and `get_profile_context` returns the profile **name**, `get_activity_sessions` /
/// `summarize_activity_session` the user's free-text workout **notes** (found 2026-10-22, pre-TestFlight audit).
/// `CloudToolOutputFilter` is the one choke point every tool result passes on the way to the proxy.
final class CloudToolOutputFilterTests: XCTestCase {
    private func filtered(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(CloudToolOutputFilter.sanitize(object) as? [String: Any])
    }

    func testTheProfileLosesItsNameAndKeepsAHalfKiloWeight() throws {
        let out = try filtered(#"{"profile":{"name":"Zebulon","age":34,"weight_kg":72.3,"height_cm":180},"timezone":"Europe/Berlin"}"#)
        let profile = try XCTUnwrap(out["profile"] as? [String: Any])
        XCTAssertNil(profile["name"])
        XCTAssertEqual(profile["weight_kg"] as? Double, 72.5)
        XCTAssertEqual(profile["age"] as? Int, 34)
        XCTAssertEqual(profile["height_cm"] as? Int, 180)
        XCTAssertEqual(out["timezone"] as? String, "Europe/Berlin")
    }

    func testUserNotesAreDroppedAtAnyDepthButSystemNotesStay() throws {
        let out = try filtered(#"""
        {"sessions":[{"id":"s1","type":"run","notes":"met Zebulon at Hyde Park","duration_min":31}],
         "sleep":{"confidence":"medium","note":"Stages are experimental estimates; REM is decoded and included in night_min."}}
        """#)
        let session = try XCTUnwrap((out["sessions"] as? [[String: Any]])?.first)
        XCTAssertNil(session["notes"], "free text the user typed (§5)")
        XCTAssertEqual(session["duration_min"] as? Int, 31)
        XCTAssertEqual((out["sleep"] as? [String: Any])?["note"] as? String,
                       "Stages are experimental estimates; REM is decoded and included in night_min.",
                       "a system remark the coach needs is not user text")
    }

    func testOtherNamesStay_onlyThePersonsNameIsPrivate() throws {
        let out = try filtered(#"{"ok":true,"name":"Oat porridge","device":{"name":"Agara Ring"}}"#)
        XCTAssertEqual(out["name"] as? String, "Oat porridge", "a meal's name is what the coach talks about")
        XCTAssertEqual((out["device"] as? [String: Any])?["name"] as? String, "Agara Ring", "§5 sends the device name")
    }

    func testIdentifiersAndPlacesNeverLeave() throws {
        let out = try filtered(#"""
        {"email":"z@example.com","city":"London","region":"England","latitude":51.5,"longitude":-0.1,
         "coordinates":[[51.5,-0.1]],"uid":"u","user_id":"u","firebase_uid":"u","steps":10432}
        """#)
        XCTAssertEqual(Set(out.keys), ["steps"])
    }

    func testPlainTextAndScalarsPassThrough() {
        XCTAssertEqual(CloudToolOutputFilter.sanitize("plain") as? String, "plain")
        XCTAssertEqual(CloudToolOutputFilter.sanitize(3) as? Int, 3)
    }
}

@MainActor
final class CoachCloudWirePrivacyTests: XCTestCase {
    /// The whole chain, nothing hand-built: a store holding a named profile and a workout with a note → the real
    /// context builder → the real orchestrator and tools → `AgaraCoachProxyClient` → the transport. Every byte and
    /// header that would reach the server is searched for the planted strings.
    func testNoNameNoteOrPlaceReachesTheServerInAnyRound() async throws {
        let c = try TestSupport.makeContext()
        c.insert(UserProfile(name: "Zebulon Quartz", age: 34, sex: "male", heightCm: 180, weightKg: 72.3))
        let start = Date().addingTimeInterval(-3 * 3600)
        let session = ActivitySession(type: "run", status: .finished, startedAt: start,
                                      endedAt: start.addingTimeInterval(1860), distanceMeters: 5200,
                                      notes: "CANARY-NOTE met Zebulon at Hyde Park", useGps: false)
        c.insert(session)
        try c.save()
        let today = CoachDataAccess.localDateString(Date())

        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t9","round":1,"status":"tool_calls","remaining_rounds":3,"answer":null,"tool_calls":[\
            {"call_id":"c1","name":"get_profile_context","arguments":{}},\
            {"call_id":"c2","name":"get_activity_sessions","arguments":{"start_date":"\(today)","end_date":"\(today)",\
            "include_samples":true,"include_gps":true}},\
            {"call_id":"c3","name":"summarize_activity_session","arguments":{"activity_id":"\(session.id.uuidString)"}}]}
            """),
            .init(status: 200, body: """
            {"turn_id":"t9","round":2,"status":"answer","remaining_rounds":2,"tool_calls":[],"answer":\(answerJSON())}
            """),
        ])
        let client = AgaraCoachProxyClient(config: coachConfig, auth: signedInAuth(transport),
                                           transport: transport, appVersion: "1.1.0", appBuild: "1010010")
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        let orchestrator = CoachOrchestrator(client: client, registry: ToolRegistry(flags: flags), flags: flags,
                                             toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await orchestrator.runTurn(userText: "how was my run?",
                                                packet: CoachContextBuilder.build(context: c), recentMessages: [])
        XCTAssertNil(result.error, "the turn completed")

        let sent = transport.coachRequests
        XCTAssertEqual(sent.count, 2, "round 1 (context) + round 2 (tool results)")
        let wire = sent.map { request -> String in
            let headers = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return headers + "\n" + request.url.absoluteString + "\n" + String(decoding: request.body ?? Data(), as: UTF8.self)
        }.joined(separator: "\n----\n")

        for canary in ["Zebulon", "Quartz", "CANARY-NOTE", "Hyde Park"] {
            XCTAssertFalse(wire.contains(canary), "'\(canary)' reached the server")
        }
        // Structural, not a substring: JSON may spell 72.3 as 72.299999999999997 (the substring check passed while the
        // raw weight was in fact being sent — found 2026-10-22).
        let openingProfile = try XCTUnwrap((try json(try XCTUnwrap(sent[0].body))["context"] as? [String: Any])?["profile"] as? [String: Any])
        XCTAssertEqual(openingProfile["weight_kg"] as? Double, 72.5, "round 1: the scale reading leaves at half-kilo resolution")

        // Not vacuous: the three tools really ran and their data went out.
        let round2 = try json(try XCTUnwrap(sent[1].body))
        let results = try XCTUnwrap(round2["tool_results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["call_id"] as? String }, ["c1", "c2", "c3"])
        let profile = try XCTUnwrap((results[0]["output"] as? [String: Any])?["profile"] as? [String: Any])
        XCTAssertEqual(profile["weight_kg"] as? Double, 72.5)
        XCTAssertEqual(profile["age"] as? Int, 34)
        let summary = try XCTUnwrap(results[2]["output"] as? [String: Any])
        XCTAssertEqual(summary["type"] as? String, "run")
        XCTAssertEqual(summary["distance_km"] as? Double, 5.2)
        XCTAssertNil(summary["error"])

        // Headers: only what the contract needs — no device or account identifiers beyond the bearer token.
        for request in sent {
            let names = Set(request.headers.keys.map { $0.lowercased() })
            let allowed: Set<String> = ["authorization", "content-type", "accept", CoachCloudRequest.versionHeader.lowercased()]
            XCTAssertTrue(names.isSubset(of: allowed), "unexpected header(s): \(names.subtracting(allowed))")
        }
    }
}

// MARK: - What comes back from the server (data in), hostile cases

@MainActor
final class CoachHostileAnswerTests: XCTestCase {
    func testOnlyHttpsLinksToARealHostAreTappable() {
        XCTAssertNotNil(CoachLinkPolicy.safeURL("https://www.nhs.uk/conditions/insomnia/"))
        for unsafe in ["http://example.com", "tel:+441234567", "sms:123", "shortcuts://run-shortcut?name=x",
                       "javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "mailto:a@b.c",
                       "https://user:pass@evil.example", "https://localhost/x", "https:///nohost", "agara://open"] {
            XCTAssertNil(CoachLinkPolicy.safeURL(unsafe), unsafe)
        }
    }

    func testUnsafeMarkdownLinksKeepTheirWordsButLoseTheTap() throws {
        let text = "Read [the guide](https://www.nhs.uk/x) or [call now](tel:+44123) or [verify](https://u:p@evil.example/)."
        let attributed = try XCTUnwrap(CoachLinkPolicy.markdown(text))
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://www.nhs.uk/x")!])
        XCTAssertEqual(String(attributed.characters), "Read the guide or call now or verify.")
    }

    func testAChartWithAbsurdValuesDecodesWithoutThemAndRendersSafely() throws {
        let points = (0..<2_000).map { #"{"x":"2026-10-\#($0 % 28 + 1)","y":\#(7000 + $0)}"# }.joined(separator: ",")
        let json = """
        {"chart_type":"bar","title":"Steps","metric":"steps","range":{"start":"2026-10-01","end":"2026-10-28"},\
        "data":[{"x":"a","y":1e308},{"x":"b","y":-1e308},{"x":"c","y":9.3e18},\(points)],"annotations":[]}
        """
        let chart = try JSONDecoder().decode(CoachChart.self, from: Data(json.utf8))
        XCTAssertEqual(chart.data.count, CoachChart.maxPoints)
        XCTAssertTrue(chart.data.allSatisfy { abs($0.y) <= CoachChart.maxAbsValue })
        XCTAssertFalse(chart.data.contains { ["a", "b", "c"].contains($0.x) })
        // The label code that used to trap now only ever sees plausible values: exercise its extremes.
        for metric in [CoachChartMetric.steps, .hr, .spo2, .sleep, .activeMinutes, .calories, .distance] {
            _ = CoachChartView.valueLabel(CoachChart.maxAbsValue, metric: metric)
            _ = CoachChartView.yAxisLabel(-CoachChart.maxAbsValue, metric: metric)
        }
    }

    /// A broken or hostile body with status 200 (a captive portal's HTML, a truncated proxy reply, wrong types, an
    /// unknown status) must end the turn with an error the user can see — never a crash, never a hang.
    func testHostileProxyRepliesEndTheTurnWithAnError() async throws {
        let bodies = [
            "<html><body>Hotel Wi-Fi login</body></html>",
            "",
            "null",
            "[]",
            #"{"turn_id":"t1","round":1,"status":"answer""#,
            #"{"turn_id":5,"status":"answer"}"#,
            #"{"turn_id":"t1","round":1,"status":"answer","answer":"not an object"}"#,
            #"{"turn_id":"t1","round":1,"status":"tool_calls","tool_calls":"nope"}"#,
            #"{"turn_id":"t1","round":1,"status":"launch_missiles"}"#,
        ]
        let c = try TestSupport.makeContext()
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        for body in bodies {
            // Each body is served for every attempt the client makes (retries included).
            let transport = CoachProxyTransport(Array(repeating: .init(status: 200, body: body), count: 8))
            let client = AgaraCoachProxyClient(config: coachConfig, auth: signedInAuth(transport),
                                               transport: transport, appVersion: "1.1.0", appBuild: "1010010")
            let orchestrator = CoachOrchestrator(client: client, registry: ToolRegistry(flags: flags), flags: flags,
                                                 toolContext: ToolExecutionContext(modelContext: c, flags: flags))
            let result = await orchestrator.runTurn(userText: "hi", packet: CoachContextBuilder.build(context: c),
                                                    recentMessages: [])
            XCTAssertNotNil(result.error, "no error surfaced for body: \(body.prefix(60))")
            XCTAssertLessThanOrEqual(transport.coachRequests.count, 8, "no retry storm for: \(body.prefix(60))")
        }
    }

    /// A server that asks for far more tool calls than the budget, or for a tool the app does not have.
    func testAFloodOfToolCallsIsCappedAndUnknownToolsAreRefused() async throws {
        let c = try TestSupport.makeContext()
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        let calls = (0..<200).map { #"{"call_id":"c\#($0)","name":"\#($0 == 0 ? "rm_rf_everything" : "get_sync_status")","arguments":{}}"# }
        let transport = CoachProxyTransport([
            .init(status: 200, body: #"{"turn_id":"t1","round":1,"status":"tool_calls","remaining_rounds":3,"answer":null,"tool_calls":[\#(calls.joined(separator: ","))]}"#),
            .init(status: 200, body: #"{"turn_id":"t1","round":2,"status":"answer","remaining_rounds":2,"tool_calls":[],"answer":\#(answerJSON())}"#),
        ])
        let client = AgaraCoachProxyClient(config: coachConfig, auth: signedInAuth(transport),
                                           transport: transport, appVersion: "1.1.0", appBuild: "1010010")
        let orchestrator = CoachOrchestrator(client: client, registry: ToolRegistry(flags: flags), flags: flags,
                                             toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await orchestrator.runTurn(userText: "hi", packet: CoachContextBuilder.build(context: c),
                                                recentMessages: [])
        XCTAssertNil(result.error)
        let round2 = try json(try XCTUnwrap(transport.coachRequests.last?.body))
        let outputs = try XCTUnwrap(round2["tool_results"] as? [[String: Any]]).map { $0["output"] as? [String: Any] ?? [:] }
        XCTAssertEqual(outputs.count, 200, "every call is answered, so the turn can close")
        XCTAssertNotNil(outputs[0]["error"], "an unknown tool is refused, not run")
        let ran = outputs.filter { $0["error"] == nil }.count
        XCTAssertLessThanOrEqual(ran, flags.maxToolCalls, "the budget caps real executions")
    }
}

// MARK: - Profile values imported from Apple Health stay off the cloud (owner decision 2026-10-22)

final class HealthImportedProfileTests: XCTestCase {
    func testImportMarksTheFieldsItFilledAndAnEditMakesAValueTheUsersOwn() {
        var draft = ProfileDraft(locale: Locale(identifier: "en_GB"))
        let count = draft.importFromHealth(age: 41, sex: "female", heightCm: nil, weightKg: 81.3)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(draft.healthImported, ["age", "sex", "weight_kg"])
        draft.setWeight(displayValue: 80)          // the user types their own weight
        XCTAssertEqual(draft.healthImported, ["age", "sex"])
        draft.heightCm = 170                       // a field Health never filled
        XCTAssertEqual(draft.healthImported, ["age", "sex"])
    }

    @MainActor
    func testTheMarksSurviveSavingAndReopening() throws {
        let c = try TestSupport.makeContext()
        let profile = UserProfile()
        c.insert(profile)
        var draft = ProfileDraft(profile: profile)
        _ = draft.importFromHealth(age: 41, sex: nil, heightCm: 172, weightKg: nil)
        draft.apply(to: profile)
        try c.save()
        XCTAssertEqual(ProfileDraft(profile: profile).healthImported, ["age", "height_cm"], "reopening the screen keeps them")
    }

    func testTheToolFilterDropsMarkedFieldsAndTheListItself() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"""
        {"profile":{"age":41,"sex":"female","height_cm":172,"weight_kg":81.3,"health_imported":["age","weight_kg"]}}
        """#.utf8))
        let profile = try XCTUnwrap((CloudToolOutputFilter.sanitize(object) as? [String: Any])?["profile"] as? [String: Any])
        XCTAssertEqual(Set(profile.keys), ["sex", "height_cm"])
    }
}

@MainActor
final class HealthImportedWireTests: XCTestCase {
    /// Real chain again: a profile whose age and weight came from Health → neither leaves, in round 1 (context) or in
    /// round 2 (`get_profile_context`); the user's own height does; the marker list itself never leaves.
    func testImportedAgeAndWeightNeverReachTheServer() async throws {
        let c = try TestSupport.makeContext()
        let profile = UserProfile(age: 41, sex: "female", heightCm: 172, weightKg: 81.3)
        profile.healthImported = ["age", "weight_kg"]
        c.insert(profile)
        try c.save()
        let transport = CoachProxyTransport([
            .init(status: 200, body: """
            {"turn_id":"t8","round":1,"status":"tool_calls","remaining_rounds":3,"answer":null,"tool_calls":[\
            {"call_id":"c1","name":"get_profile_context","arguments":{}}]}
            """),
            .init(status: 200, body: """
            {"turn_id":"t8","round":2,"status":"answer","remaining_rounds":2,"tool_calls":[],"answer":\(answerJSON())}
            """),
        ])
        let client = AgaraCoachProxyClient(config: coachConfig, auth: signedInAuth(transport),
                                           transport: transport, appVersion: "1.1.0", appBuild: "3")
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        let orchestrator = CoachOrchestrator(client: client, registry: ToolRegistry(flags: flags), flags: flags,
                                             toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await orchestrator.runTurn(userText: "am I a healthy weight?",
                                                packet: CoachContextBuilder.build(context: c), recentMessages: [])
        XCTAssertNil(result.error)
        let sent = transport.coachRequests
        XCTAssertEqual(sent.count, 2)

        let opening = try json(try XCTUnwrap(sent[0].body))
        let contextProfile = try XCTUnwrap((opening["context"] as? [String: Any])?["profile"] as? [String: Any])
        XCTAssertNil(contextProfile["age"]); XCTAssertNil(contextProfile["weight_kg"])
        XCTAssertNotNil(contextProfile["height_cm"], "the user's own value still goes")

        let round2 = try json(try XCTUnwrap(sent[1].body))
        let output = try XCTUnwrap((round2["tool_results"] as? [[String: Any]])?.first?["output"] as? [String: Any])
        let toolProfile = try XCTUnwrap(output["profile"] as? [String: Any])
        XCTAssertNil(toolProfile["age"]); XCTAssertNil(toolProfile["weight_kg"])
        XCTAssertEqual(toolProfile["height_cm"] as? Double, 172)

        let wire = sent.map { String(decoding: $0.body ?? Data(), as: UTF8.self) }.joined()
        for leak in ["81.3", "81.5", "health_imported", "healthImported"] {
            XCTAssertFalse(wire.contains(leak), "'\(leak)' reached the server")
        }
    }
}

// MARK: - Round 1 sends the trimmer's projection, never the raw packet (found 2026-10-22)

/// `CloudContextTrimmer` was written and tested but never called: the proxy client sent the developer message's raw
/// packet minus the name. These pin that the client's context IS the trimmer's output.
@MainActor
final class CloudContextIsTheTrimmedPacketTests: XCTestCase {
    private func fullPacket() -> CoachContextPacket {
        var packet = samplePacket(summary: "Two good weeks.")
        packet.profile.weightKg = 78.3
        packet.profile.healthImported = ["age"]
        packet.environment = .init(city: "Canaryville", region: "Canary Region", tempC: 14, condition: "rain",
                                   highC: 16, lowC: 9, precipitationChancePct: 80, sunrise: "07:31", sunset: "17:52",
                                   asOf: "2026-10-20T07:00:00Z")
        packet.recentWorkouts = [.init(id: "w-secret-id", type: "run", startTime: "2026-10-19T17:00:00Z",
                                       durationMin: 31, distanceKm: 5.27, avgHr: 151, status: "finished")]
        packet.nutrition = .init(caloriesConsumed: 1450, proteinG: 80, carbsG: 160, fatG: 50, mealsLoggedToday: 2,
                                 mealsToday: [.init(mealId: "m1", name: "Oat porridge", mealType: "breakfast",
                                                    time: "08:10", kcal: 380, source: "manual")],
                                 yesterdayCalories: 1900)
        return packet
    }

    func testTheContextSentEqualsTheTrimmersProjection() throws {
        let packet = fullPacket()
        let sent = try XCTUnwrap(CoachCloudRequest.packet(in: CoachPromptBuilder.developerMessage(packet: packet)))
        let expected = CloudContextTrimmer.encode(packet)
        XCTAssertFalse(expected.isEmpty)
        let canonical = { (o: [String: Any]) in
            String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(canonical(sent), canonical(expected), "the client must send exactly the allowlist projection")

        let text = canonical(sent)
        for leak in ["Canaryville", "Canary Region", "Rafay", "w-secret-id", "5.27", "\"timezone\"", "health_imported"] {
            XCTAssertFalse(text.contains(leak), "'\(leak)' reached the server")
        }
        let profile = try XCTUnwrap(sent["profile"] as? [String: Any])
        XCTAssertEqual(profile["weight_kg"] as? Double, 78.5, "0.5 kg resolution")
        XCTAssertNil(profile["age"], "imported from Apple Health")
        XCTAssertNil(sent["environment"])
    }

    func testAPacketThatDoesNotDecodeSendsAnEmptyContextNotTheRawJSON() {
        let message = "Current context packet:\n{\"profile\":{\"name\":\"Zebulon\"},\"secret\":1}\n\nConversation summary:\n(no prior summary)"
        XCTAssertEqual(CoachCloudRequest.packet(in: message)?.isEmpty, true)
    }
}

// MARK: - Testers updating from 1.0 stayed on the on-device coach (found 2026-10-22, Jimmy's 1.1.0 (3))

final class CoachProviderMigrationTests: XCTestCase {
    func testA1_0DefaultFollowsTheBuildButAChoiceIsKept() {
        let m = CoachSettings.migratedProvider
        XCTAssertEqual(m(.appleOnDevice, false, .agaraCloud), .agaraCloud, "1.0 stored on-device as a default, not a choice")
        XCTAssertEqual(m(.appleOnDevice, true, .agaraCloud), .appleOnDevice, "a 1.1 user who picked 'On this phone' keeps it")
        XCTAssertEqual(m(.agaraCloud, false, .agaraCloud), .agaraCloud)
        XCTAssertEqual(m(nil, false, .agaraCloud), .agaraCloud, "no stored value → the build's default")
        XCTAssertEqual(m(.offlineStub, false, .agaraCloud), .offlineStub, "only the old default is lifted")
        XCTAssertEqual(m(.appleOnDevice, false, .appleOnDevice), .appleOnDevice, "debug builds default to on-device")
    }

    func testDecodingA1_0SettingsBlobMarksNothingChosen() throws {
        // The shape 1.0 wrote: no `providerChosen` key.
        let old = try JSONDecoder().decode(CoachSettings.self, from: Data(#"{"providerMode":"appleOnDevice","coachMasterEnabled":true}"#.utf8))
        XCTAssertFalse(old.providerChosen)
        XCTAssertEqual(old.providerMode, CoachProviderMode.defaultForThisBuild)
        let chosen = try JSONDecoder().decode(CoachSettings.self, from: Data(#"{"providerMode":"appleOnDevice","providerChosen":true}"#.utf8))
        XCTAssertEqual(chosen.providerMode, .appleOnDevice)
        // And the flag survives a save/load round trip.
        let again = try JSONDecoder().decode(CoachSettings.self, from: try JSONEncoder().encode(chosen))
        XCTAssertTrue(again.providerChosen)
        XCTAssertEqual(again.providerMode, .appleOnDevice)
    }
}

/// Jimmy's on-device answer called 4,078 steps "imperial miles": the units rule read as "attach the unit to every
/// number". Both prompts now scope units to measurements and pin steps as a count.
final class CoachPromptUnitsTests: XCTestCase {
    func testBothPromptsScopeUnitsAndPinStepsAsACount() {
        for prompt in [CoachPromptBuilder.systemPromptCompact, CoachPromptBuilder.systemPrompt] {
            XCTAssertTrue(prompt.contains("steps") && prompt.lowercased().contains("never"), prompt.prefix(80).description)
            XCTAssertTrue(prompt.contains("ONLY"), "units are scoped to distance/weight/height/temperature")
            XCTAssertTrue(prompt.contains("city only when"), "the city is not small talk")
        }
    }
}

/// The consent step was unreachable in Release (2026-10-22): the tab only counted the debug `backendProxy` as "cloud in
/// use", and the cloud gate checked only the sync consent — so a synced account could reach the cloud coach without
/// the AI disclosure, and the consent card never showed.
final class CoachConsentGateTests: XCTestCase {
    func testTheCloudIsInUseWhenSelectedAndAnAccountExists() {
        let f = CoachTabStateInput.cloudInUse
        XCTAssertTrue(f(true, .agaraCloud, true), "the Release default with an account — the case that was missed")
        XCTAssertTrue(f(true, .backendProxy, true))
        XCTAssertFalse(f(true, .agaraCloud, false), "no account → the on-device coach answers; the coach is not behind sign-in")
        XCTAssertFalse(f(true, .appleOnDevice, true), "an on-device choice is respected")
        XCTAssertFalse(f(false, .agaraCloud, true), "coach_cloud off")
    }

    func testASignedInAccountWithoutTheAIDisclosureGetsTheConsentCard() {
        let input = CoachTabStateInput(coachFlagOn: true, masterEnabled: true,
                                       cloudInUse: CoachTabStateInput.cloudInUse(flagOn: true, provider: .agaraCloud, signedIn: true),
                                       account: .verified, consentGiven: false, busy: false,
                                       remainingTurnsToday: 24, dayResetsAt: nil)
        XCTAssertEqual(CoachTabState.resolve(input), .consentRequired)
        var agreed = input
        agreed.consentGiven = true
        XCTAssertEqual(CoachTabState.resolve(agreed), .ready)
    }

    func testTheCloudGateNeedsAnAccountThatAgreed() {
        let ready = CoachGate.Account(signedIn: true, emailVerified: true, consented: true)
        XCTAssertTrue(CoachGate.cloudReady(flagOn: true, userOn: true, account: ready))
        var notAgreed = ready
        notAgreed.consented = false     // `CoachGate.account` sets this only when BOTH consents are given
        XCTAssertFalse(CoachGate.cloudReady(flagOn: true, userOn: true, account: notAgreed))
    }
}

// MARK: - Server-sent events (2026-10-23)

final class ServerSentEventParserTests: XCTestCase {
    func testEventsEndOnABlankLineOrTheNextEventLine() {
        var parser = ServerSentEventParser()
        var events: [(String, String)] = []
        let lines = ["event: delta", #"data: {"field":"title","text":"Hi"}"#, "",
                     ": keep-alive", "event: delta", #"data: {"field":"summary","text":"A"}"#,
                     "event: final", #"data: {"status":"answer"}"#]
        for line in lines {
            if let e = parser.feed(line: line) { events.append((e.name, String(decoding: e.data, as: UTF8.self))) }
        }
        if let e = parser.flush() { events.append((e.name, String(decoding: e.data, as: UTF8.self))) }
        XCTAssertEqual(events.map(\.0), ["delta", "delta", "final"])
        XCTAssertEqual(events.last?.1, #"{"status":"answer"}"#)
    }

    func testTerminalEventsBecomeResponses() {
        let final = ServerSentEventParser.terminalResponse(name: "final", data: Data(#"{"status":"answer"}"#.utf8), headers: [:])
        XCTAssertEqual(final?.status, 200)
        let error = ServerSentEventParser.terminalResponse(
            name: "error", data: Data(#"{"status":502,"code":"coach_bad_answer"}"#.utf8), headers: [:])
        XCTAssertEqual(error?.status, 502)
        XCTAssertEqual(CoachCloudFailure.from(status: 502, body: error!.body).kind, .badAnswer)
        XCTAssertNil(ServerSentEventParser.terminalResponse(name: "delta", data: Data(), headers: [:]))
    }
}
