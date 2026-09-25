import XCTest
@testable import PulseLoop

/// The header pill and the Settings chart share these bands (shared.yaml `ring_battery_*`). Same cases as Android.
final class BatteryTierTests: XCTestCase {
    func testBandsFollowTheSharedThresholds() {
        XCTAssertEqual(BatteryTier(percent: 5), .low)
        XCTAssertEqual(BatteryTier(percent: 20), .low)
        XCTAssertEqual(BatteryTier(percent: 21), .mid)
        XCTAssertEqual(BatteryTier(percent: 50), .mid)
        XCTAssertEqual(BatteryTier(percent: 51), .ok)
        XCTAssertEqual(BatteryTier(percent: 100), .ok)
    }
}
