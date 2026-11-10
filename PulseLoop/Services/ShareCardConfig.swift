import Foundation

/// The address the EV40 share card prints, as the **server** may set it (plan `ev40-share-card-v2`, decision D1).
///
/// The compiled fallback is the catalog (`AgaraCopy.ev40ShareUrlFallback` / `ev40ShareQrFallback`) — never a literal in
/// a renderer. A record under `app_config` key `share_card` can replace it without a release, and it is treated with the
/// same suspicion as the sleep model: the card is printed for other people to read, so a bad value must cost a reverted
/// record, never a wrong address on every user's image.
///
/// Rules (identical on both platforms, `docs/ring/cloud-v2.md` → `share_card`):
///  * **`model` must equal `implementedModel`**, so a future payload shape never reaches this build.
///  * **`display_url`** — required, 3…40 characters of `a-z 0-9 . - /`, at least one dot. The character set has no `:`
///    and no whitespace, so a scheme or a space cannot get through; the app only ever *prints* this text.
///  * **`qr_url`** — optional. When present it must be `https://`, ≤ 120 characters, whitespace-free, and share
///    `display_url`'s host (leading `www.` ignored), so the QR can never point somewhere the printed address does not
///    name. A malformed one rejects the **whole** record, never half of it.
///  * **`qr`** — optional boolean, default `false`: the console decides whether the QR is drawn at all.
///  * Any rejection, a wrong model, a disabled or a missing record → the catalog fallback, QR off.
///
/// Mirror of Android's `ShareCardConfig` (Rule 2); parsing/validation is pure so the whole rule table can be tested.
struct ShareCard: Equatable, Sendable {
    /// Printed in the card's footer exactly as given (no scheme, no trailing slash added).
    let displayUrl: String
    /// The full URL the QR encodes; nil when the record named none (the address is printed instead).
    let qrUrl: String?
    /// Whether the QR is drawn — off unless the console switches it on.
    let qr: Bool
}

enum ShareCardConfig {
    /// The `app_config` key (`docs/ring/cloud-v2.md`).
    nonisolated static let key = "share_card"
    /// The payload shape this build implements.
    nonisolated static let implementedModel = 1

    nonisolated static let displayUrlRange = 3...40
    nonisolated static let qrUrlMaxLength = 120
    /// Every character `display_url` may contain — no scheme, no space, no uppercase.
    private nonisolated static let displayUrlCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-/")

    struct Accepted { let card: ShareCard; let version: Int; let appliedAt: Date }
    struct Rejected { let reason: String }

    /// The catalog value: what the card prints when the cloud has no accepted record (no sign-in, a rejection, a
    /// disabled record). The QR is off here, so a card never carries one the console did not ask for.
    static var fallback: ShareCard {
        ShareCard(displayUrl: AgaraCopy.ev40ShareUrlFallback, qrUrl: AgaraCopy.ev40ShareQrFallback, qr: false)
    }

    /// Parse and validate one `app_config` record's `value` object. Recognised keys are the contract's own; anything else
    /// is ignored by name.
    static func parse(value: [String: Any]?, model: Int, version: Int, now: Date = Date()) -> Any {
        guard model == implementedModel else { return Rejected(reason: "model \(model) is not implemented by this build") }
        guard let value else { return Rejected(reason: "no value object") }

        guard let display = value["display_url"] as? String else { return Rejected(reason: "display_url is missing") }
        guard displayUrlRange.contains(display.count) else {
            return Rejected(reason: "display_url is \(display.count) characters, outside \(displayUrlRange)")
        }
        guard display.allSatisfy({ displayUrlCharacters.contains($0) }) else {
            return Rejected(reason: "display_url has a character outside a-z 0-9 . - /")
        }
        guard display.contains(".") else { return Rejected(reason: "display_url has no dot") }

        var qrUrl: String?
        if let raw = value["qr_url"], !(raw is NSNull) {
            guard let qr = raw as? String else { return Rejected(reason: "qr_url is not a string") }
            guard qr.hasPrefix("https://") else { return Rejected(reason: "qr_url is not https") }
            guard qr.count <= qrUrlMaxLength else {
                return Rejected(reason: "qr_url is \(qr.count) characters, over \(qrUrlMaxLength)")
            }
            guard !qr.contains(where: { $0.isWhitespace }) else { return Rejected(reason: "qr_url contains whitespace") }
            guard host(qr, droppingScheme: true) == host(display, droppingScheme: false) else {
                return Rejected(reason: "qr_url host \(host(qr, droppingScheme: true)) does not match display_url host \(host(display, droppingScheme: false))")
            }
            qrUrl = qr
        }

        return Accepted(card: ShareCard(displayUrl: display, qrUrl: qrUrl, qr: flag(value["qr"])),
                        version: version, appliedAt: now)
    }

    /// The address's host: the text before the first `/`, with a leading `www.` ignored, so `www.agaralife.com/x` and
    /// `agaralife.com` compare equal (the contract's own example).
    private static func host(_ address: String, droppingScheme: Bool) -> String {
        let scheme = "https://"
        let rest = droppingScheme && address.hasPrefix(scheme) ? String(address.dropFirst(scheme.count)) : address
        // Hosts are case-insensitive — lowercase before comparing, exactly as Android's `hostOf` does (a divergence here
        // meant the same payload produced a QR on one platform and the fallback on the other).
        let host = String(rest.prefix(while: { $0 != "/" })).lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// `true` only for a JSON **boolean** `true`. A number (`1`) or a string (`"true"`) reads as `false` — strict on both
    /// platforms, because `NSNumber` bridges `1` to `true` here while Android's `optBoolean` accepts the string `"true"`,
    /// and the same payload must draw the same card everywhere.
    private static func flag(_ raw: Any?) -> Bool {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// Where an accepted card is cached, so a launch does not depend on the network.
    enum Cache {
        static let key = "agara.shareCardConfig"
        /// Re-fetch at most once per 12 h — the same cadence as the sleep model, so a rollback stays quick.
        static let ttl: TimeInterval = 12 * 60 * 60

        static func isFresh(appliedAt: Date, now: Date) -> Bool {
            let age = now.timeIntervalSince(appliedAt)
            return age >= 0 && age < ttl
        }

        /// The cached card, or the fallback — never a second hardcoded address.
        static func card(raw: String?, now: Date = Date()) -> ShareCard {
            guard let raw, let data = raw.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fallback }
            let accepted = parse(value: o["value"] as? [String: Any],
                                 model: o["model"] as? Int ?? -1,
                                 version: o["version"] as? Int ?? -1,
                                 now: now)
            return (accepted as? Accepted)?.card ?? fallback
        }

        static func encode(value: [String: Any], model: Int, version: Int, appliedAt: Date) -> String {
            let o: [String: Any] = ["model": model, "version": version,
                                    "appliedAt": appliedAt.timeIntervalSince1970, "value": value]
            guard let data = try? JSONSerialization.data(withJSONObject: o) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    /// The card in force: the installed record if any, else the catalog fallback.
    private static var installed: ShareCard?

    static func install(_ card: ShareCard?) { installed = card }
    static func active() -> ShareCard { installed ?? fallback }

    /// One refresh step: `fetch` returns the record (or nil when the server has none / the call failed), `raw` is the
    /// cache as it stands. Returns the new cache string when it changed, nil when nothing should be written.
    static func refresh(fetch: (String) async -> [String: Any]?, raw: String?, now: Date = Date(),
                        key: String = ShareCardConfig.key) async -> String? {
        let cached = raw.flatMap { $0.data(using: .utf8) }
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        if let appliedAt = (cached?["appliedAt"] as? NSNumber)?.doubleValue,
           isFresh(epoch: appliedAt, now: now) {
            return nil                                    // at most one fetch per 12 h
        }
        guard let record = await fetch(key) else { return nil }   // offline / no record: keep what we have

        let model = record["model"] as? Int ?? -1
        let version = record["version"] as? Int ?? -1
        if record["enabled"] as? Bool == false {
            // The console switched the key off: back to the catalog address, and that answer holds for the 12 h window.
            install(nil)
            return Cache.encode(value: [:], model: model, version: version, appliedAt: now)
        }
        let value = record["value"] as? [String: Any] ?? [:]
        let accepted = parse(value: value, model: model, version: version, now: now)
        install((accepted as? Accepted)?.card)            // a rejection falls back to the catalog, never to a blank footer
        return Cache.encode(value: (accepted as? Accepted) != nil ? value : [:],
                            model: model, version: version, appliedAt: now)
    }

    private static func isFresh(epoch: Double, now: Date) -> Bool {
        Cache.isFresh(appliedAt: Date(timeIntervalSince1970: epoch), now: now)
    }
}
