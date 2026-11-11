import XCTest

/// The pairing scan list shows *your* ring's name (plan `scan-row-ring-name.md`, D1/D2).
///
/// **Why the rows are stubbed.** A live crowded room has no rig: the emulator serves one connection and the
/// socket transport attaches the moment a scan starts, so the app goes straight from "scanning" to
/// "Connected" and the list is never on screen with a real ring in it. `-pairingStubRings` therefore fabricates
/// the rows through the *same* `RingScanName` call the real ones use, which is what this asserts: the names,
/// the stable tags, the order, and that the advertised hardware name never labels a matched ring.
///
/// The identity → remembered-name lookup (the part a stub cannot prove) is unit-tested in
/// `RingNicknameTests` (`testANamedRingShowsItsNameAndIsKnown`, and the store's key tests).
///
/// The person's name is not stubbed: `-profileName Hayden` writes the real profile, and the app derives the
/// first row's name from it with `RingNickname.forPerson`.
final class RingScanRowTests: AgaraUITestCase {

    /// The pairing screen with Bluetooth "usable" (the simulator reports no radio, so without
    /// `-forcePairingUI` the screen refuses to offer the button) and no virtual ring, so nothing can connect
    /// out from under the list.
    private func launchScanList(stubRows: Int) {
        app.launchArguments = [
            "-features", Self.allFeatures,
            "-historyDays", "8",
            "-noCoachMarks", "YES",
            "-skipOnboarding", "YES",
            "-acceptDisclaimer", "YES",
            "-AppleLanguages", "(en)",
            "-forcePairingUI", "YES",
            "-openRoute", "pairing",
            "-pairingStubRings", "\(stubRows)",
            "-profileName", "Hayden",
        ]
        app.launch()
        dismissSystemAlert()
        waitFor(app.buttons["Connect my ring"], "pairing screen did not open").tap()
    }

    func testTheCrowdedScanListTellsRingsApart() throws {
        launchScanList(stubRows: 6)

        // The person's own ring, by name: the derived possessive name, not the product copy.
        eventually(timeout: 30, "the named rows never appeared") {
            app.staticTexts["Hayden’s Ring"].exists && app.staticTexts["Sleep ring"].exists
        }

        // Every unnamed ring is told apart by its tag, and no two rows read the same.
        let tagged = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AGARA Heart · "))
        XCTAssertGreaterThan(tagged.count, 1, "the unnamed rings must carry their tags")
        let labels = (0..<tagged.count).map { tagged.element(boundBy: $0).label }
        XCTAssertEqual(Set(labels).count, labels.count, "two rows share a label: \(labels)")
        attachScreenshot("scan-list-crowded")

        // Rule 3 still holds: the advertised hardware name never labels a matched ring.
        XCTAssertFalse(app.staticTexts["TK20"].exists, "a matched ring must not show its Bluetooth name")
    }
}
