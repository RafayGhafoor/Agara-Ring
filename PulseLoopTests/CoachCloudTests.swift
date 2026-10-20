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
        latestSleep: .init(date: "2026-10-19", totalMin: 431, deepMin: 78, lightMin: 320, awakeMin: 33,
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
        XCTAssertEqual(opening.context["timezone"] as? String, "Europe/Berlin")

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
        XCTAssertEqual(repaired.context["timezone"] as? String, "Europe/Berlin")
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
