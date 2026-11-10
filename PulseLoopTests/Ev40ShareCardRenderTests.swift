import XCTest
import SwiftUI
@testable import PulseLoop

/// The EV40 card actually renders at both story and square sizes with the new content (streak, stats row, heat levels,
/// perfect state) and with the QR switched on (A6/D4). A `nil` render is a blank share target, so it is asserted, not
/// assumed — same shape as `ShareCardRendererTests` for the workout card.
@MainActor
final class Ev40ShareCardRenderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func now() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 10; components.hour = 12
        return calendar.date(from: components)!
    }

    private func makeModel(mask: Int = 255, userName: String? = "Rafay") -> Ev40ShareCardModel {
        let masks = ["2026-11-06": 3, "2026-11-07": 15, "2026-11-08": 255, "2026-11-09": 0, "2026-11-10": mask]
        return Ev40ShareCardModel.make(mask: mask, userName: userName, now: now(), calendar: calendar,
                                       trackedKeys: Array(masks.keys), masksByKey: masks)
    }

    private func pixelSize(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testStoryRendersAt1080x1920() {
        let image = Ev40ShareRenderer.render(model: makeModel(), format: .story)
        XCTAssertNotNil(image, "story render should produce an image")
        XCTAssertEqual(pixelSize(image!), CGSize(width: 1080, height: 1920))
    }

    func testSquareRendersAt1080x1080() {
        let image = Ev40ShareRenderer.render(model: makeModel(mask: 3), format: .square)
        XCTAssertNotNil(image, "square render should produce an image")
        XCTAssertEqual(pixelSize(image!), CGSize(width: 1080, height: 1080))
    }

    /// The QR is off by default and drawn only when the console asks for it — but when it is on the card must still
    /// render, and the code it carries comes from the configured `qr_url`.
    func testTheCardRendersWithTheQrSwitchedOn() {
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40",
                                          qrUrl: "https://www.agaralife.com/ev40", qr: true))
        defer { ShareCardConfig.install(nil) }
        XCTAssertNotNil(Ev40ShareCardView.qrImage(ShareCardConfig.active().qrUrl!),
                        "the configured qr_url must encode to a bitmap")
        let image = Ev40ShareRenderer.render(model: makeModel(), format: .story)
        XCTAssertNotNil(image, "the card must render with the QR in its footer")
        XCTAssertEqual(pixelSize(image!), CGSize(width: 1080, height: 1920))
    }

    func testShareImageIsAPngNamedForTheDay() {
        let image = Ev40ShareRenderer.shareImage(model: makeModel(), format: .story,
                                                 date: now())
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.filename, "agara-ev40-2026-11-10.png")
        XCTAssertFalse(image?.pngData.isEmpty ?? true)
    }

    // MARK: No name → no name row (owner, 2026-11-10: "if no name, let's not use that in the image")

    func testAProfileWithNoNamePutsNoNameOnTheCard() {
        XCTAssertNil(makeModel(userName: nil).userName, "no profile name")
        XCTAssertNil(makeModel(userName: "").userName, "an empty name is no name")
        XCTAssertNil(makeModel(userName: "   ").userName, "a blank name is no name")
        XCTAssertEqual(makeModel(userName: "  Maya ").userName, "Maya", "a real name is kept, trimmed")
    }

    // MARK: Gallery — every variant written to disk for a visual check (lead review, plan ev40-share-card-v2 Phase 3)

    /// Writes PNGs only when `TEST_RUNNER_EV40_CARD_DIR` is set (xcodebuild strips the prefix): the normal suite does no
    /// file I/O. Each image is the exact `Ev40ShareRenderer` output the share sheet hands to `ShareLink`.
    func testWritesTheCardGalleryWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["EV40_CARD_DIR"], !dir.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EV40_CARD_DIR to write the gallery")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let original = ThemeStore.current
        defer { ShareCardConfig.install(nil); ThemeStore.current = original }

        func write(_ name: String, _ model: Ev40ShareCardModel, _ format: ShareCardFormat) throws {
            let image = try XCTUnwrap(Ev40ShareRenderer.render(model: model, format: format), name)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        for theme in ["light", "dark"] {
            ThemeStore.select(theme)
            ShareCardConfig.install(nil)
            try write("ios-\(theme)-story-progress", makeModel(mask: 0b0001_0111), .story)
            try write("ios-\(theme)-square-progress", makeModel(mask: 0b0001_0111), .square)
            try write("ios-\(theme)-story-perfect", makeModel(mask: 255), .story)
            try write("ios-\(theme)-story-noname", makeModel(mask: 0b0001_0111, userName: nil), .story)
        }
        ThemeStore.select("light")
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40",
                                                          qrUrl: "https://www.agaralife.com/ev40", qr: true))
        try write("ios-light-story-qr", makeModel(mask: 0b0001_0111), .story)
    }
}
