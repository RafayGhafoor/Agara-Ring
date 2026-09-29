import XCTest
@testable import PulseLoop

/// The shared scheduling cases (the Android `CloudScheduleTest` has the same eleven, same names).
final class AgaraCloudScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(consent: Bool = true, signedIn: Bool = true, verified: Bool = true, grace: Date? = nil, blocked: Bool = false,
                       lastSync: TimeInterval? = nil, interval: Int = 120, retry: TimeInterval? = nil) -> AgaraCloudSchedule.Input {
        AgaraCloudSchedule.Input(consent: consent, signedIn: signedIn, verified: verified, graceEndsAt: grace, blocked: blocked, now: now,
                                 lastSync: lastSync.map { now.addingTimeInterval(-$0) }, intervalMinutes: interval,
                                 retryNextAt: retry.map { now.addingTimeInterval($0) })
    }

    func testCase01NoConsentCancels() { XCTAssertEqual(AgaraCloudSchedule.decide(input(consent: false)), .cancel) }
    func testCase02SignedOutCancels() { XCTAssertEqual(AgaraCloudSchedule.decide(input(signedIn: false)), .cancel) }
    func testCase03VerifiedNeverSyncedSchedulesNow() { XCTAssertEqual(AgaraCloudSchedule.decide(input()), .schedule(delaySeconds: 0)) }
    func testCase04VerifiedSyncedTenMinutesAgoWaitsForTheInterval() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(lastSync: 600)), .schedule(delaySeconds: 6600))
    }
    func testCase05VerifiedSyncedTwoHoursAgoSchedulesNow() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(lastSync: 10800)), .schedule(delaySeconds: 0))
    }
    func testCase06RetryPendingWaitsForTheRetry() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(lastSync: 10800, retry: 600)), .schedule(delaySeconds: 600))
    }
    func testCase07UnverifiedInsideGraceSchedules() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(verified: false, grace: now.addingTimeInterval(3600))), .schedule(delaySeconds: 0))
    }
    func testCase08UnverifiedGraceEndedCancels() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(verified: false, grace: now.addingTimeInterval(-1))), .cancel)
    }
    func testCase09UnverifiedGraceUnknownSchedulesAndTheServerDecides() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(verified: false, grace: nil)), .schedule(delaySeconds: 0))
    }
    func testCase10BlockedCancels() { XCTAssertEqual(AgaraCloudSchedule.decide(input(blocked: true)), .cancel) }
    func testCase11TheLaterOfIntervalAndRetryWins() {
        XCTAssertEqual(AgaraCloudSchedule.decide(input(lastSync: 600, retry: 300)), .schedule(delaySeconds: 6600))
    }

    // Open-gap decision (shared cases, gap 5 min).
    func testOpenGapNeverSyncedSyncs() { XCTAssertTrue(AgaraCloudSchedule.shouldSyncOnOpen(lastSync: nil, now: now, minGapMinutes: 5)) }
    func testOpenGapFourMinutesAgoSkips() { XCTAssertFalse(AgaraCloudSchedule.shouldSyncOnOpen(lastSync: now.addingTimeInterval(-240), now: now, minGapMinutes: 5)) }
    func testOpenGapSixMinutesAgoSyncs() { XCTAssertTrue(AgaraCloudSchedule.shouldSyncOnOpen(lastSync: now.addingTimeInterval(-360), now: now, minGapMinutes: 5)) }
}
