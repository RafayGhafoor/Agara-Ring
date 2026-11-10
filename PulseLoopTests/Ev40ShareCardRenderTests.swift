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

    /// The Android render test's fixture, mask for mask (`Ev40ShareCardRenderTest.history`): 13 days from 28 Oct with two
    /// gaps and every shade, today 10 Nov — so the two platforms' galleries can be compared value for value (Rule 2).
    private func galleryModel(mask: Int, userName: String? = "Maya") -> Ev40ShareCardModel {
        var masks: [String: Int] = [:]
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        for offset in 0..<13 {
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = Ev40Challenge.key(date, calendar: calendar)
            switch offset {
            case 3, 7: masks[key] = 0
            case 2, 9: masks[key] = 255
            default: masks[key] = (1 << (offset % 8 + 1)) - 1
            }
        }
        masks["2026-11-10"] = mask
        return Ev40ShareCardModel.make(mask: mask, userName: userName, now: now(), calendar: calendar,
                                       trackedKeys: Array(masks.keys), masksByKey: masks)
    }

    /// Counts pixels within `tolerance` of `rgb` inside `rect` (pixel coordinates) of a rendered card.
    private func count(_ image: UIImage, rgb: (Int, Int, Int), in rect: CGRect, tolerance: Int = 14) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hits = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * width + x) * 4
                if abs(Int(data[i]) - rgb.0) < tolerance, abs(Int(data[i + 1]) - rgb.1) < tolerance,
                   abs(Int(data[i + 2]) - rgb.2) < tolerance { hits += 1 }
            }
        }
        return hits
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

    // MARK: The EV40 wordmark (v3, owner 2026-11-10)

    /// The header is the owner's EV40 wordmark. Its "EV" is the mark's own orange #F3682F, a colour nothing else on the
    /// card uses, so the header band holding a few thousand pixels of it proves the mark was drawn — on both themes and
    /// both formats. Mirror of Android `theHeaderCarriesTheEv40Wordmark`.
    func testTheHeaderCarriesTheEv40Wordmark() throws {
        let original = ThemeStore.current
        defer { ThemeStore.current = original }
        XCTAssertNotNil(UIImage(named: "ev40-mark-ev"), "the EV layer ships in the app's asset catalog")
        XCTAssertNotNil(UIImage(named: "ev40-mark-forty"), "the 40 layer ships in the app's asset catalog")
        for theme in ["light", "dark"] {
            ThemeStore.select(theme)
            for format in [ShareCardFormat.story, .square] {
                let image = try XCTUnwrap(Ev40ShareRenderer.render(model: galleryModel(mask: 0b0011_1111), format: format))
                let orange = count(image, rgb: (0xF3, 0x68, 0x2F), in: CGRect(x: 72, y: 92, width: 360, height: 62))
                XCTAssertGreaterThan(orange, 2_000, "\(theme) \(format): the EV40 mark's orange in the header")
            }
        }
    }

    // MARK: No name → no name row (owner, 2026-11-10: "if no name, let's not use that in the image")

    func testAProfileWithNoNamePutsNoNameOnTheCard() throws {
        XCTAssertNil(makeModel(userName: nil).userName, "no profile name")
        XCTAssertNil(makeModel(userName: "").userName, "an empty name is no name")
        XCTAssertNil(makeModel(userName: "   ").userName, "a blank name is no name")
        XCTAssertEqual(makeModel(userName: "  Maya ").userName, "Maya", "a real name is kept, trimmed")
        // On the card, not just in the model (review finding 3, mirror of Android): removing the name changes the
        // pixels, and a blank name renders exactly like no name.
        func png(_ name: String?) throws -> Data {
            try XCTUnwrap(Ev40ShareRenderer.render(model: galleryModel(mask: 0b0011_1111, userName: name),
                                                   format: .story)?.pngData())
        }
        let named = try png("Maya"), unnamed = try png(nil), blank = try png("   ")
        XCTAssertNotEqual(named, unnamed, "removing the name must change the card")
        XCTAssertEqual(unnamed, blank, "a blank name is no name")
    }

    /// The QR replaces the printed address when the console turns it on — the card must actually change (review finding
    /// 4: the old test only checked the generator and the card's size, which hold with the QR off too).
    func testTurningTheQrOnChangesTheCardsFooter() throws {
        let original = ThemeStore.current
        defer { ShareCardConfig.install(nil); ThemeStore.current = original }
        ThemeStore.select("light")          // on the dark ground the background itself is near-black
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40", qrUrl: "https://www.agaralife.com/ev40",
                                          qr: false))
        let off = try XCTUnwrap(Ev40ShareRenderer.render(model: galleryModel(mask: 0b0011_1111), format: .story))
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40", qrUrl: "https://www.agaralife.com/ev40",
                                          qr: true))
        let on = try XCTUnwrap(Ev40ShareRenderer.render(model: galleryModel(mask: 0b0011_1111), format: .story))
        XCTAssertNotEqual(off.pngData(), on.pngData(), "the QR must change the footer")
        // The QR's black modules: nothing else on the card is near-black in this slot (the address is orange, the
        // ground pale or warm-dark), so with the QR off this count is ~0.
        let slot = CGRect(x: 1080 - 72 - 108, y: 1920 - 150 + 14, width: 108, height: 108)
        XCTAssertLessThan(count(off, rgb: (0, 0, 0), in: slot, tolerance: 30), 200, "no QR modules when the QR is off")
        XCTAssertGreaterThan(count(on, rgb: (0, 0, 0), in: slot, tolerance: 30), 2_000, "the QR's modules fill the slot")
    }

    /// A long name and a long cloud address are shrunk and then truncated, never drawn past the right margin: the
    /// 70-px strip right of the margin is pixel-identical to the same card with short texts (it holds the faint
    /// watermark, so "plain background" would be the wrong baseline).
    func testALongNameAndALongAddressStayInsideTheMargin() throws {
        defer { ShareCardConfig.install(nil) }
        ShareCardConfig.install(nil)
        let short = try XCTUnwrap(Ev40ShareRenderer.render(model: galleryModel(mask: 0b0011_1111, userName: "Maya"),
                                                           format: .story))
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40/challenge/day", qrUrl: nil, qr: false))
        let long = try XCTUnwrap(Ev40ShareRenderer.render(
            model: galleryModel(mask: 0b0011_1111, userName: "Muhammad Rafay Ghafoor Abdullah"), format: .story))
        for x in (1080 - 70)..<1080 {
            for y in stride(from: 230, to: 340, by: 3) {
                XCTAssertEqual(pixel(long, x: x, y: y), pixel(short, x: x, y: y), "name row x=\(x) y=\(y)")
            }
            for y in stride(from: 1795, to: 1845, by: 2) {
                XCTAssertEqual(pixel(long, x: x, y: y), pixel(short, x: x, y: y), "footer x=\(x) y=\(y)")
            }
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return data
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
            try write("ios-\(theme)-story-progress", galleryModel(mask: 0b0011_1111), .story)
            try write("ios-\(theme)-square-progress", galleryModel(mask: 0b0011_1111), .square)
            try write("ios-\(theme)-story-perfect", galleryModel(mask: 255), .story)
            try write("ios-\(theme)-story-noname", galleryModel(mask: 0b0011_1111, userName: nil), .story)
        }
        ThemeStore.select("light")
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40",
                                                          qrUrl: "https://www.agaralife.com/ev40", qr: true))
        try write("ios-light-story-qr", galleryModel(mask: 0b0011_1111), .story)
    }
}
