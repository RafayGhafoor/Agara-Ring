import XCTest
@testable import PulseLoop

/// The Coach tab's decision logic: when can the coach answer, and what does each blocked state say. The resolver is a
/// pure function on purpose — the cloud states need an account, a used-up quota and a running turn, so testing them
/// through the UI alone would mean faking all three.
@MainActor
final class CoachTabStateTests: XCTestCase {

    private func input(_ change: (inout CoachTabStateInput) -> Void = { _ in }) -> CoachTabStateInput {
        var value = CoachTabStateInput(coachFlagOn: true, masterEnabled: true, cloudInUse: true)
        change(&value)
        return value
    }

    // MARK: - The switches come first

    func testTheFlagOrTheUserSwitchTurnsEverythingOffFirst() {
        XCTAssertEqual(CoachTabState.resolve(input { $0.coachFlagOn = false }), .coachOff)
        XCTAssertEqual(CoachTabState.resolve(input { $0.masterEnabled = false }), .coachOff)
        // Even with everything else blocked: "off" is the honest reason when nothing can run.
        XCTAssertEqual(CoachTabState.resolve(input {
            $0.masterEnabled = false; $0.account = .signedOut
        }), .coachOff)
    }

    func testTheOnDeviceCoachNeedsNoAccountConsentOrQuota() {
        let state = CoachTabState.resolve(input { value in
            value.cloudInUse = false
            value.account = .signedOut
            value.consentGiven = false
            value.remainingTurnsToday = 0
        })
        XCTAssertEqual(state, .ready)
    }

    // MARK: - The cloud preconditions, in the server's order

    func testSignedOutComesBeforeVerificationAndConsent() {
        XCTAssertEqual(CoachTabState.resolve(input { $0.account = .signedOut }), .signedOut)
    }

    func testUnverifiedAccountIsItsOwnState() {
        XCTAssertEqual(CoachTabState.resolve(input { $0.account = .unverified }), .emailUnverified)
    }

    func testConsentIsRequiredOnceTheAccountIsVerified() {
        XCTAssertEqual(CoachTabState.resolve(input { $0.account = .verified }), .consentRequired)
        XCTAssertEqual(CoachTabState.resolve(input {
            $0.account = .verified; $0.consentGiven = true
        }), .ready)
    }

    // MARK: - The transient limits

    func testARunningTurnShowsBusy() {
        XCTAssertEqual(CoachTabState.resolve(input {
            $0.account = .verified; $0.consentGiven = true; $0.busy = true
        }), .busy)
    }

    func testAnExhaustedQuotaCarriesTheResetTime() {
        let resets = Date(timeIntervalSince1970: 1_800_000_000)
        let state = CoachTabState.resolve(input {
            $0.account = .verified; $0.consentGiven = true
            $0.remainingTurnsToday = 0; $0.dayResetsAt = resets
        })
        XCTAssertEqual(state, .outOfQuota(resetsAt: resets))
    }

    func testAnUnknownQuotaNeverBlocksTheCoach() {
        // Nil means "the server has not said yet" — a first turn must not be refused on a guess.
        XCTAssertEqual(CoachTabState.resolve(input {
            $0.account = .verified; $0.consentGiven = true; $0.remainingTurnsToday = nil
        }), .ready)
        XCTAssertEqual(CoachTabState.resolve(input {
            $0.account = .verified; $0.consentGiven = true; $0.remainingTurnsToday = 1
        }), .ready)
    }

    func testPositiveRemainingTurnsAreReady() {
        XCTAssertEqual(CoachTabState.resolve(input {
            $0.account = .verified; $0.consentGiven = true; $0.remainingTurnsToday = 24
        }), .ready)
    }

    // MARK: - Every state is distinct and identified

    func testEveryStateHasItsOwnIdentifierTitleAndBody() {
        let states: [CoachTabState] = [.coachOff, .signedOut, .emailUnverified, .consentRequired, .busy,
                                       .outOfQuota(resetsAt: nil), .ready]
        XCTAssertEqual(Set(states.map(\.id)).count, states.count, "identifiers must be unique")
        for state in states where state != .ready {
            XCTAssertFalse(state.id.isEmpty)
            XCTAssertFalse(state.title.isEmpty, "\(state.id) has no title")
            XCTAssertFalse(state.body().isEmpty, "\(state.id) has no body")
        }
        XCTAssertEqual(CoachTabState.ready.id, "ready")
    }

    func testOnlyCloudBlockersOfferTheOnDeviceWayOut() {
        XCTAssertTrue(CoachTabState.signedOut.offersOnDevice)
        XCTAssertTrue(CoachTabState.emailUnverified.offersOnDevice)
        XCTAssertTrue(CoachTabState.consentRequired.offersOnDevice)
        XCTAssertTrue(CoachTabState.outOfQuota(resetsAt: nil).offersOnDevice)
        // Nothing to fix, and nothing to switch away from, in these two.
        XCTAssertFalse(CoachTabState.coachOff.offersOnDevice)
        XCTAssertFalse(CoachTabState.busy.offersOnDevice)
    }

    // MARK: - Quota presentation (the pill and the out-of-quota card)

    func testQuotaPillReadsAsQuestionsLeftToday() {
        let store = CoachQuotaStore(remainingTurnsToday: 24)
        XCTAssertEqual(store.pillText, "24 left today")
        XCTAssertEqual(store.pillSpokenText, "24 cloud questions left today")
        XCTAssertFalse(store.quotaBody.isEmpty)
    }

    func testQuotaPillSingularAndUnknown() {
        XCTAssertEqual(CoachQuotaStore(remainingTurnsToday: 1).pillText, "1 left today")
        XCTAssertNil(CoachQuotaStore().pillText, "nothing reported yet — no pill")
        XCTAssertFalse(CoachQuotaStore().hasQuota)
    }

    func testOutOfQuotaBodyNamesTheResetWhenKnown() {
        let resets = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 0))!
        let store = CoachQuotaStore(remainingTurnsToday: 0, dayResetsAt: resets)
        XCTAssertTrue(store.quotaBody.contains("reset"), "got: \(store.quotaBody)")
        XCTAssertTrue(store.quotaBody.contains(CoachQuotaStore.resetFormatter.string(from: resets)))
        XCTAssertEqual(CoachQuotaStore(remainingTurnsToday: 0).quotaBody, CoachCopy.quotaUnknownReset)
    }

    // MARK: - The consent record

    func testConsentIsRecordedWithItsVersionAndWithdrawnCleanly() {
        let suite = "CoachTabStateTests-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = CoachConsentStore(defaults: defaults)

        XCTAssertFalse(store.hasConsent)
        store.give()
        XCTAssertTrue(store.hasConsent)
        XCTAssertNotNil(store.consentedAt)
        // A new store over the same defaults agrees: the record is persisted, not in-memory.
        XCTAssertTrue(CoachConsentStore(defaults: defaults).hasConsent)
        store.withdraw()
        XCTAssertFalse(store.hasConsent)
        XCTAssertNil(store.consentedAt)
        defaults.removePersistentDomain(forName: suite)
    }
}
