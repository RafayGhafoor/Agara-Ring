import Foundation

/// The Agara Cloud coach — the release-1.1 provider (contract `docs/ring/coach-proxy.md`).
///
/// The orchestrator is deliberately **stateless**: it hands every client one request body and, for a tool round,
/// only that round's `function_call_output` items. The proxy is **stateful**: round 1 opens a turn (trimmed context,
/// message, history, summary) and every round after it names the `turn_id` and the next round number. This type is
/// where the two meet — it holds the turn between calls, builds the contract's two request shapes out of the
/// stateless body, and maps the reply back into an `OpenAIResponse` (tool calls → `.functionCall`, the answer JSON →
/// one `.message`) so the existing tool loop, JSON repair and error bubbles run unchanged.
///
/// Turn state is per instance and cleared whenever the turn closes or a request fails: a client is built per turn
/// (`CoachClientResolver`), so a stale `turn_id` can never be replayed — the server would answer `409
/// coach_turn_expired` anyway, which is what makes replay useless (§6).
@MainActor
final class AgaraCoachProxyClient: ResponsesClient {
    /// The server's idle TTL is 120 s and its per-round upstream timeout 60 s (§13), so one round can legitimately
    /// take a minute; the client waits a little longer than that and lets the server decide when a turn has died.
    static let requestTimeout: TimeInterval = 75

    private let config: AgaraCloudConfig
    private let transport: CloudTransport
    private let auth: AgaraAuthClient
    /// The `client` block of round 1 (§6) — informational only, never trusted for authorisation.
    private let client: [String: Any]

    /// The open turn: its id and the round the last reply reported.
    private var turn: (id: String, round: Int)?
    /// Round 1 as last sent, kept for one reason only: the orchestrator's schema-repair send is a bare user message
    /// with no context, and the server has already closed the turn — so it becomes a **new** turn and reuses this
    /// context to stay grounded.
    private var opening: CoachCloudRequest.Opening?

    init(config: AgaraCloudConfig,
         auth: AgaraAuthClient,
         transport: CloudTransport = URLSessionCloudTransport(),
         appVersion: String? = nil,
         appBuild: String? = nil) {
        self.config = config
        self.auth = auth
        self.transport = transport
        self.client = [
            "app": "ios",
            "version": appVersion ?? Self.bundleInfo("CFBundleShortVersionString") ?? "1.1.0",
            "build": appBuild ?? Self.bundleInfo("CFBundleVersion") ?? "0",
        ]
    }

    // MARK: - ResponsesClient

    func send(requestBody: Data) async throws -> OpenAIResponse {
        guard let root = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let input = root["input"] as? [[String: Any]]
        else {
            clearTurn()
            throw ResponsesError.decoding("a coach request must carry an input array")
        }
        do {
            if CoachCloudRequest.isContinuation(input) {
                return try await continueTurn(input: input)
            }
            return try await openTurn(input: input)
        } catch {
            // Every failure ends the local turn: the server either closed it, dropped it, or answered an error. The
            // UI restarts the turn (a fresh client) — re-sending the same `turn_id` is a replay the server rejects.
            clearTurn()
            throw error
        }
    }

    // MARK: - The turn

    private func openTurn(input: [[String: Any]]) async throws -> OpenAIResponse {
        let opening = CoachCloudRequest.opening(from: input, fallback: opening)
        let body = try CoachCloudRequest.openingBody(opening, client: client)
        self.opening = opening
        return accept(try CoachCloudRequest.reply(try await post(body)))
    }

    private func continueTurn(input: [[String: Any]]) async throws -> OpenAIResponse {
        guard let turn else {
            // Nothing to continue: another instance, or the round before this one already failed. The tools for these
            // ids did run on the device, so the only safe answer is the contract's own `coach_turn_expired` — never a
            // silent restart (replaying a turn would re-run write tools).
            throw CoachCloudFailure(kind: .turnExpired, status: 409)
        }
        let body = try CoachCloudRequest.continuationBody(turnID: turn.id, round: turn.round, input: input)
        return accept(try CoachCloudRequest.reply(try await post(body)))
    }

    /// §7: `tool_calls` keeps the turn open at this round, `answer` / `safety` close it.
    private func accept(_ reply: CoachCloudRequest.Reply) -> OpenAIResponse {
        if reply.closed { clearTurn() } else { turn = (reply.turnID, reply.round) }
        return reply.response
    }

    private func clearTurn() {
        turn = nil
        opening = nil
    }

    // MARK: - HTTP

    private func post(_ body: Data) async throws -> [String: Any] {
        let url = try endpoint()
        var token = try await idToken()
        var refreshed = false
        while true {
            var request = CloudRequest(method: "POST", url: url)
            request.headers["Authorization"] = "Bearer " + token
            request.headers["Content-Type"] = "application/json"
            request.headers["Accept"] = "application/json"
            request.headers[CoachCloudRequest.versionHeader] = String(CoachCloudRequest.contract)
            request.body = body
            request.timeout = Self.requestTimeout

            let response = try await transport.send(request)
            if (200...299).contains(response.status) {
                if let quota = CoachQuota(response: response) { CoachQuotaStore.shared.update(quota) }
                guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
                    throw ResponsesError.decoding("the coach reply was not a JSON object")
                }
                return json
            }

            let failure = CoachCloudFailure.from(status: response.status, body: response.body, headers: response.headers)
            // `401 coach_unauthorized` (§9): the ID token expired or was rejected — refresh it and retry **once**. A
            // second 401 is a real authorisation failure (wrong audience, revoked account) and surfaces as such.
            if response.status == 401, !refreshed {
                refreshed = true
                if let renewed = try? await auth.refreshAfterUnauthorized(staleToken: token) {
                    token = renewed
                    continue
                }
            }
            throw failure
        }
    }

    private func idToken() async throws -> String {
        do { return try await auth.validIdToken() }
        catch let error as AgaraAuthError {
            switch error {
            case .notSignedIn, .sessionExpired, .userDisabled:
                throw CoachCloudFailure(kind: .unauthorized, status: 401, message: error.message)
            case .notConfigured:
                throw CoachCloudFailure(kind: .disabled, message: error.message)
            default:
                throw CoachCloudFailure(kind: .upstream, message: error.message)
            }
        }
    }

    private func endpoint() throws -> URL {
        guard let base = config.baseURL else { throw CoachCloudFailure(kind: .disabled) }
        let path = AgaraConfig.Coach.path.hasPrefix("/")
            ? String(AgaraConfig.Coach.path.dropFirst())
            : AgaraConfig.Coach.path
        return base.appendingPathComponent(path)
    }

    private static func bundleInfo(_ key: String) -> String? {
        let value = Bundle.main.infoDictionary?[key] as? String
        return (value?.isEmpty ?? true) ? nil : value
    }
}

// MARK: - Wire

/// The proxy's request and reply shapes (§6, §7), built from the stateless Responses request the orchestrator hands
/// every client. Kept dictionary-based for the same reason `OpenAIRequestBuilder` is: the context packet and the
/// tool arguments are naturally arbitrary JSON.
nonisolated enum CoachCloudRequest {
    /// `contract` in the body and the value of `X-Agara-Coach-Version` (§4).
    static let contract = 1
    static let versionHeader = "X-Agara-Coach-Version"

    /// Round 1 reduced to the contract's fields.
    struct Opening {
        var message: String
        var context: [String: Any]
        var history: [[String: Any]]
        var summary: String?
    }

    /// One decoded reply, with the pieces the client keeps apart from the `OpenAIResponse` the orchestrator wants.
    struct Reply {
        var turnID: String
        var round: Int
        /// `status: answer` / `safety`: the server closed the turn.
        var closed: Bool
        var response: OpenAIResponse
    }

    static func toolOutputs(in input: [[String: Any]]) -> [[String: Any]] {
        input.filter { $0["type"] as? String == "function_call_output" }
    }

    /// A continuation is the orchestrator's tool-loop send: only `function_call_output` items, no messages.
    static func isContinuation(_ input: [[String: Any]]) -> Bool {
        !toolOutputs(in: input).isEmpty && input.allSatisfy { $0["type"] as? String == "function_call_output" }
    }

    // MARK: Round 1

    /// Reduces the orchestrator's input array to §6's fields: `system`/`developer` are dropped (the server prepends its
    /// own system prompt and builds the tools + answer schema), the last user item is `message`, everything before it is
    /// `history`, and the developer message carries the context packet.
    ///
    /// `fallback` supplies the context for a schema-repair send, which carries a bare user sentence and no packet.
    static func opening(from input: [[String: Any]], fallback: Opening?) -> Opening {
        var conversation: [(role: String, text: String)] = []
        var context: [String: Any]?
        var summary: String?
        for item in input {
            guard let role = item["role"] as? String else { continue }
            switch role {
            case "system":
                continue                      // the server builds the system prompt (§6)
            case "developer":
                let developer = text(of: item)
                context = packet(in: developer)
                summary = conversationSummary(in: developer)
            case "user", "assistant":
                conversation.append((role, text(of: item)))
            default:
                continue
            }
        }
        // Oldest first, and the message itself is not part of the history.
        let messageIndex = conversation.lastIndex { $0.role == "user" } ?? conversation.indices.last
        let message = messageIndex.map { conversation[$0].text } ?? ""
        var prior = conversation
        if let messageIndex { prior.remove(at: messageIndex) }
        if prior.count > AgaraConfig.Coach.historyTurns {
            prior = Array(prior.suffix(AgaraConfig.Coach.historyTurns))
        }
        return Opening(
            message: message,
            context: context ?? fallback?.context ?? [:],
            history: prior.map { ["role": $0.role, "text": $0.text] },
            summary: summary ?? fallback?.summary)
    }

    static func openingBody(_ opening: Opening, client: [String: Any]) throws -> Data {
        var body: [String: Any] = [
            "contract": contract,
            "client": client,
            "message": opening.message,
            "context": opening.context,
            "history": opening.history,
        ]
        if let summary = opening.summary { body["summary"] = summary }
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    // MARK: Rounds 2…max

    /// §6: `{contract, turn_id, round, tool_results:[{call_id, output}]}`. `output` is the tool's JSON **as the app
    /// produced it** — the orchestrator carries it as the JSON string the Responses API expects, so it is parsed back
    /// into an object here (plain text, which no tool produces, is passed through unchanged).
    static func continuationBody(turnID: String, round: Int, input: [[String: Any]]) throws -> Data {
        let results: [[String: Any]] = toolOutputs(in: input).map { item in
            let output = item["output"] as? String ?? ""
            // §5 holds for tool results too: no name, notes, places or identifiers (`CloudToolOutputFilter`).
            return [
                "call_id": item["call_id"] as? String ?? "",
                "output": parsedJSON(output).map(CloudToolOutputFilter.sanitize) ?? output,
            ]
        }
        return try JSONSerialization.data(withJSONObject: [
            "contract": contract,
            "turn_id": turnID,
            "round": round + 1,
            "tool_results": results,
        ], options: [.withoutEscapingSlashes])
    }

    // MARK: Reply

    static func reply(_ json: [String: Any]) throws -> Reply {
        guard let turnID = json["turn_id"] as? String, let status = json["status"] as? String else {
            throw ResponsesError.decoding("the coach reply has no turn_id/status")
        }
        let round = json["round"] as? Int ?? 0
        switch status {
        case "tool_calls":
            let calls = json["tool_calls"] as? [[String: Any]] ?? []
            let items: [ResponseOutputItem] = calls.map { call in
                // The Responses API carries `arguments` as a JSON *string* and `ToolCallExecutor` parses it that way;
                // the proxy sends an object, so serialize it back to keep the tool loop identical.
                let arguments = parsedJSON(call["arguments"]).flatMap(stringifiedJSON) ?? "{}"
                return .functionCall(ResponseFunctionCall(
                    name: call["name"] as? String ?? "",
                    callID: call["call_id"] as? String ?? "",
                    arguments: arguments))
            }
            return Reply(turnID: turnID, round: round, closed: false,
                         response: OpenAIResponse(id: turnID, outputItems: items))
        case "answer", "safety":
            // A safety answer (§10) carries the fixed guidance object instead of an answer — accept either shape so a
            // red flag always reaches the user. Both are coach_response-shaped, which is what the parser expects.
            let payload = (json["answer"] as? [String: Any]) ?? (json["safety"] as? [String: Any])
            guard let payload,
                  payload["response_type"] != nil || payload["summary"] != nil
            else { throw ResponsesError.decoding("the coach answered without an answer object") }
            // A red-flag answer must never fail to render, so fill the two fields `CoachResponse` requires. The server's
            // schema always sends them; this is the belt to that braces (and it is what makes a minimal
            // `{"response_type":"safety_guidance","summary":…}` object — the shape a future provider change might
            // send — still reach the user).
            var complete = payload
            if complete["title"] == nil { complete["title"] = "" }
            if complete["summary"] == nil { complete["summary"] = "" }
            if complete["response_type"] == nil { complete["response_type"] = "safety_guidance" }
            guard let text = stringifiedJSON(complete) else {
                throw ResponsesError.decoding("the coach answered with an unserialisable answer object")
            }
            return Reply(turnID: turnID, round: round, closed: true,
                         response: OpenAIResponse(id: turnID, outputItems: [.message(text: text)]))
        default:
            throw ResponsesError.decoding("unknown coach status \(status)")
        }
    }

    // MARK: Item text

    /// The text of one input item: a plain `content` string, or the `input_text` parts of a multimodal content array.
    ///
    /// **Images are dropped here on purpose.** The cloud coach never receives them (§5: "images/photos (`coach_cloud`
    /// turns them off"): a photo is the most identifying thing a health app can hold, the proxy is text-only, and the
    /// on-device path is where image input belongs. `CoachFeatureFlags.imageInputEnabled` also hides the picker for
    /// this provider, so this is the belt to that braces.
    private static func text(of item: [String: Any]) -> String {
        if let content = item["content"] as? String { return content }
        guard let parts = item["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            part["type"] as? String == "input_text" ? part["text"] as? String : nil
        }.joined()
    }

    // MARK: Context packet

    private static let packetMarker = "Current context packet:"
    private static let summaryMarker = "Conversation summary:"
    private static let noSummaryMarker = "(no prior summary)"

    /// The context packet out of the developer message (`CoachPromptBuilder.developerMessage`) — the only channel
    /// between the turn's packet and a client that is handed a pre-serialized body.
    ///
    /// §5's floor is applied here: the profile's **name** is removed, because the server must never receive it. The
    /// rest of the trimming (HealthKit-sourced values, coordinates, free-text notes) belongs to the packet builder and
    /// the `CloudContextTrimmer`, which run before this.
    static func packet(in developerMessage: String) -> [String: Any]? {
        guard let start = developerMessage.range(of: packetMarker),
              let end = developerMessage.range(of: summaryMarker)
        else { return nil }
        let json = developerMessage[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the trimmer's allowlist projection ever leaves (contract §5). Until 2026-10-22 the raw packet went out
        // minus the name — the trimmer existed and was tested but nothing called it, so the environment block (city,
        // weather), raw weight, workout distance/HR and Health-imported profile values reached the server.
        // Fail CLOSED: a packet that does not decode sends an empty context (the server needs a non-null one), never
        // the raw JSON.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8),
              let packet = try? decoder.decode(CoachContextPacket.self, from: data)
        else { return [:] }
        return CloudContextTrimmer.encode(packet)
    }

    /// The rolling summary that rides beside the history (§6 `summary`).
    static func conversationSummary(in developerMessage: String) -> String? {
        guard let start = developerMessage.range(of: summaryMarker) else { return nil }
        let rest = developerMessage[start.upperBound...]
        let text = (rest.components(separatedBy: "\n\n").first ?? String(rest))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == noSummaryMarker ? nil : text
    }

    // MARK: JSON helpers

    /// The tool-call arguments as the Responses API carries them: a JSON **string**. The proxy sends a JSON object
    /// (§7), so accept both shapes — an object is serialised straight back, a string is kept if it already parses.
    private static func parsedJSON(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringifiedJSON(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
