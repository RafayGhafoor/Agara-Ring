import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

private struct SummaryStubKeyStore: APIKeyStore {
    let key: String?
    func readKey() throws -> String? { key }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

private func summaryJSON(title: String = "Strong morning", body: String = "8,200 steps already.", chips: [String] = ["Why?"]) -> String {
    let chipsJSON = (try? String(data: JSONEncoder().encode(chips), encoding: .utf8)!) ?? "[]"
    return "{\"title\":\"\(title)\",\"body\":\"\(body)\",\"chips\":\(chipsJSON)}"
}

final class CoachSummaryContentTests: XCTestCase {
    func testSchemaAndDecode() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(CoachSummarySchema.jsonSchema))
        let c = CoachSummaryContent.decode(fromJSON: "noise \(summaryJSON()) tail")
        XCTAssertEqual(c?.title, "Strong morning")
        XCTAssertEqual(c?.chips, ["Why?"])
    }

    func testAsCoachResponseCarriesChips() {
        let c = CoachSummaryContent(title: "T", body: "B", chips: ["a", "b"])
        XCTAssertEqual(c.asCoachResponse().followUpChips, ["a", "b"])
    }
}

@MainActor
final class CoachSummaryServiceTests: XCTestCase {
    private func service(_ c: ModelContext, key: String? = "sk-test", json: String = summaryJSON()) -> CoachSummaryService {
        let store = CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        // The coach is opt-out by default; turn the master switch on so summaries actually generate.
        store.settings.coachMasterEnabled = true
        // Pin the keyed provider (paired with the stub key) so `coachEnabled` resolves via `hasAPIKey`
        // rather than the product default `.appleOnDevice`, which is unavailable in CI.
        store.settings.providerMode = .userOpenAIKey
        return CoachSummaryService(
            modelContext: c,
            keyStore: SummaryStubKeyStore(key: key),
            settingsStore: store,
            clientFactory: { _ in StubResponsesClient([OpenAIResponse(id: "s", outputItems: [.message(text: json)])]) }
        )
    }

    private func seedToday(_ c: ModelContext, steps: Int) {
        TestSupport.insertActivity(date: Date(), steps: steps, calories: 300, into: c)
    }

    func testTodayGeneratesThenRespectsSignatureAndRateLimit() async throws {
        let c = try TestSupport.makeContext()
        seedToday(c, steps: 8200)
        let svc = service(c)

        await svc.refreshTodayIfNeeded()
        var todays = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "today" }
        XCTAssertEqual(todays.count, 1)
        XCTAssertEqual(todays.first?.title, "Strong morning")
        let sig1 = todays.first!.dataSignature
        let firstUpdated = todays.first!.updatedAt

        // Same data → no regeneration (signature unchanged).
        await svc.refreshTodayIfNeeded()
        todays = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "today" }
        XCTAssertEqual(todays.count, 1)
        XCTAssertEqual(todays.first!.updatedAt, firstUpdated)

        // New data but <2h since last → still skipped.
        seedToday(c, steps: 12000)
        await svc.refreshTodayIfNeeded()
        let after = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "today" }.first!
        XCTAssertEqual(after.updatedAt, firstUpdated)         // rate-limited
        XCTAssertEqual(after.dataSignature, sig1)             // unchanged
    }

    func testSleepDayGeneratesOncePerNight() async throws {
        let c = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: Calendar.current.startOfDay(for: Date()),
                                stages: Array(repeating: .light, count: 60) + Array(repeating: .deep, count: 30), into: c)
        let svc = service(c, json: summaryJSON(title: "Solid night", body: "1h30m tracked.", chips: ["Deep sleep?"]))
        // Pin `now` past the 4 AM day-reference flip so today's night is in the Day window
        // regardless of when the suite runs.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: TestSupport.day(0)) ?? Date()

        await svc.refreshSleepDayIfNeeded(now: now)
        var sleeps = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps.first?.title, "Solid night")
        let updated = sleeps.first!.updatedAt

        // Second call same night → no new summary, no update (once per night).
        await svc.refreshSleepDayIfNeeded(now: now)
        sleeps = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps.first!.updatedAt, updated)
    }

    func testNoKeyUsesScriptedFallbackGroundedInData() async throws {
        let c = try TestSupport.makeContext()
        seedToday(c, steps: 9100)
        let svc = service(c, key: nil)  // disabled → scripted fallback (TodayInsights.deriveHero)
        await svc.refreshTodayIfNeeded()
        let today = (try c.fetch(FetchDescriptor<CoachSummary>())).first { $0.kind == "today" }
        XCTAssertNotNil(today)
        XCTAssertFalse(today!.title.isEmpty)
        XCTAssertFalse(today!.body.isEmpty)
    }

    func testOpenInChatSeedsConversationAndIsIdempotent() async throws {
        let c = try TestSupport.makeContext()
        seedToday(c, steps: 8200)
        let svc = service(c)
        await svc.refreshTodayIfNeeded()
        let summary = try XCTUnwrap((try c.fetch(FetchDescriptor<CoachSummary>())).first { $0.kind == "today" })

        svc.openInChat(summary)
        let convoId = try XCTUnwrap(summary.conversationId)
        // First message decodes to a CoachResponse carrying the chips.
        let messages = (try c.fetch(FetchDescriptor<CoachMessage>())).filter { $0.conversationId == convoId }
        XCTAssertEqual(messages.count, 1)
        let response = try XCTUnwrap(CoachResponse.decode(fromJSON: messages.first?.cardsJSON))
        XCTAssertEqual(response.followUpChips, ["Why?"])
        XCTAssertEqual(CoachNavigation.shared.requestedConversationId, convoId)

        // Re-tap reuses the same conversation (idempotent).
        svc.openInChat(summary)
        XCTAssertEqual(summary.conversationId, convoId)
        let convos = (try c.fetch(FetchDescriptor<CoachConversation>())).filter { $0.title == "Today recap" }
        XCTAssertEqual(convos.count, 1)
    }
}

/// The sleep card must be grounded in **that night's date** (plan `coach-summary-vs-data-2026-11-11.md`, H1/H3).
/// Jimmy's report: a card about 14 Oct said "Nightly steps for that day aren't available" while the store held
/// other days' steps, and a store-wide coverage warning ("only N days of activity data exist for that period")
/// travelled into a claim about a three-week-old night.
@MainActor
final class CoachSummarySleepDayContextTests: XCTestCase {

    /// A 12-minute deep-sleep night that belongs to **today** (so it is the main sleep the card describes). Steps
    /// sync lags behind sleep in the real app, so the interesting case is "today has no activity row yet".
    private func seedLastNight(into context: ModelContext) {
        // A night that starts at 23:00 yesterday and ends after midnight belongs to today.
        let nightStart = Calendar.current.date(byAdding: .hour, value: -1, to: TestSupport.day(0))!
        TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: .deep, count: 12), into: context)
    }

    func testTodaysCardDoesNotBorrowAnotherDaysSteps() throws {
        let context = try TestSupport.makeContext()
        seedLastNight(into: context)
        // No activity row for today (the sync has not brought one yet), one for yesterday.
        TestSupport.insertActivity(date: TestSupport.day(-1), steps: 9280, into: context)

        let built = try XCTUnwrap(CoachSummaryContextBuilder.sleepDay(context: context))
        XCTAssertFalse(built.json.contains("9280"),
                       "yesterday's steps must not ride along with today's night: \(built.json)")
        // The key is absent rather than null (JSONEncoder omits nils), which is the cleanest signal for the model:
        // there is no step field to talk about (D2 — say nothing rather than apologise).
        XCTAssertFalse(built.json.contains("steps_that_day"), "expected no step field at all: \(built.json)")
    }

    func testTodaysCardQuotesTodaysSteps() throws {
        let context = try TestSupport.makeContext()
        seedLastNight(into: context)
        TestSupport.insertActivity(date: TestSupport.day(0), steps: 4123, into: context)
        TestSupport.insertActivity(date: TestSupport.day(-1), steps: 9280, into: context)

        let built = try XCTUnwrap(CoachSummaryContextBuilder.sleepDay(context: context))
        XCTAssertTrue(built.json.contains("\"steps_that_day\":4123"), "got: \(built.json)")
        XCTAssertFalse(built.json.contains("9280"), "got: \(built.json)")
    }

    func testTheStoreWideCoverageWarningNamesItsOwnWindow() throws {
        // The chat still reports coverage — but the sentence must say what it is about, because the model used to
        // attach the count to whatever date it was discussing (Jimmy's "for that period").
        let warnings = DataQualityAnalyzer.warnings(.init(profileCompleteness: "complete", daysAvailable: 2,
                                                          hasSleep: true, lastSyncAt: Date(), isDemo: false))
        let line = try XCTUnwrap(warnings.first { $0.contains("activity data") })
        XCTAssertTrue(line.contains("in total"), "the warning must name the store's window, got: \(line)")
    }

    func testADatedPacketCanLeaveTheStoreWideWarningOut() throws {
        let context = try TestSupport.makeContext()
        seedLastNight(into: context)
        TestSupport.insertActivity(date: TestSupport.day(0), steps: 4123, into: context)

        let scoped = CoachContextBuilder.build(context: context, reportsActivityCoverage: false)
        XCTAssertFalse(scoped.dataQualityWarnings.contains { $0.contains("activity data") },
                       "a dated packet must not carry the store-wide coverage claim")
        let whole = CoachContextBuilder.build(context: context)
        XCTAssertTrue(whole.dataQualityWarnings.contains { $0.contains("activity data") },
                      "the chat's packet keeps it")
    }
}
