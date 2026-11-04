import Foundation

/// The sleep-score model as the **server** may override it (plan `asana-heart-bugs-2026-11-01`, item F3).
///
/// The compiled default is `SleepScore.Model()` — generated from `docs/config/shared.yaml`. This is the only other way
/// a weight can reach the scorer, and it is deliberately suspicious of everything it is handed:
///
///  * **`model` must match** the model this build implements, so a future v3 weight set cannot reach a v2 app.
///  * **Every number is bounded** and the gates must stay ordered (`under-5 h` before `under-6 h`, both below the floor
///    duration). A payload that could make a 3-hour night read "Excellent" is rejected whole — never partially applied.
///  * **Rejection is silent and safe:** the app keeps the compiled default. A bad server value costs a tuning change,
///    not a broken score.
///
/// Mirror of Android's `SleepScoreConfig` (Rule 2); parsing/validation is pure so the whole table can be tested.
enum SleepScoreConfig {
    /// The model this build implements (the v2 score).
    static let implementedModel = 2
    private static let weightSumRange = 20.0...200.0

    struct Accepted { let model: SleepScore.Model; let version: Int; let appliedAt: Date }
    struct Rejected { let reason: String }

    /// Parse and validate one `app_config` record's `value` object. Recognised keys are the catalog's own; anything
    /// else is ignored by name, so a payload cannot silently move weights it does not list.
    static func parse(value: [String: Any]?, model: Int, version: Int, now: Date = Date()) -> Any {
        guard model == implementedModel else { return Rejected(reason: "model \(model) is not implemented by this build") }
        guard version > 0 else { return Rejected(reason: "version must be positive") }
        guard let value else { return Rejected(reason: "no value object") }

        let base = SleepScore.Model()
        func d(_ key: String, _ fallback: Double) -> Double {
            guard let raw = value[key] else { return fallback }
            if let n = raw as? NSNumber { return n.doubleValue }
            if let s = raw as? String, let n = Double(s) { return n }
            return .nan
        }
        func i(_ key: String, _ fallback: Int) -> Int {
            guard let raw = value[key] else { return fallback }
            if let n = raw as? NSNumber { return n.intValue }
            if let s = raw as? String, let n = Int(s) { return n }
            return .min
        }

        let weights = [d("durationWeight", base.durationWeight), d("deepWeight", base.deepWeight),
                       d("remWeight", base.remWeight), d("lightWeight", base.lightWeight),
                       d("awakeWeight", base.awakeWeight)]
        guard weights.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100 }) else {
            return Rejected(reason: "a weight is outside 0…100")
        }
        let sum = weights.reduce(0, +)
        guard weightSumRange.contains(sum) else {
            return Rejected(reason: "weights sum to \(sum), outside \(weightSumRange)")
        }
        let coverage = d("coverageFull", base.coverageFull)
        guard coverage.isFinite, coverage >= 0.5, coverage <= 1.0 else {
            return Rejected(reason: "coverageFull outside 0.5…1.0")
        }
        let floorHours = d("floorHours", base.floorHours)
        let floorAwake = d("floorAwakePct", base.floorAwakePct)
        let floorScore = i("floorScore", base.floorScore)
        let short6 = d("shortHours6", base.shortHours6)
        let cap6 = i("capUnder6h", base.capUnder6h)
        let short5 = d("shortHours5", base.shortHours5)
        let cap5 = i("capUnder5h", base.capUnder5h)

        guard floorHours.isFinite, (4.0...12.0).contains(floorHours) else { return Rejected(reason: "floorHours outside 4…12 h") }
        guard floorAwake.isFinite, (0.0...50.0).contains(floorAwake) else { return Rejected(reason: "floorAwakePct outside 0…50") }
        guard (0...100).contains(floorScore) else { return Rejected(reason: "floorScore outside 0…100") }
        guard short6.isFinite, (0.0...12.0).contains(short6) else { return Rejected(reason: "shortHours6 outside 0…12 h") }
        guard short5.isFinite, (0.0...12.0).contains(short5) else { return Rejected(reason: "shortHours5 outside 0…12 h") }
        guard (0...100).contains(cap6) else { return Rejected(reason: "capUnder6h outside 0…100") }
        guard (0...100).contains(cap5) else { return Rejected(reason: "capUnder5h outside 0…100") }
        guard short5 < short6, short6 <= floorHours else {
            return Rejected(reason: "gates must be ordered: shortHours5 < shortHours6 <= floorHours")
        }
        guard cap5 <= cap6 else { return Rejected(reason: "capUnder5h must not exceed capUnder6h") }

        var m = SleepScore.Model()
        m.durationWeight = weights[0]; m.deepWeight = weights[1]; m.remWeight = weights[2]
        m.lightWeight = weights[3]; m.awakeWeight = weights[4]
        m.coverageFull = coverage
        m.floorHours = floorHours; m.floorAwakePct = floorAwake; m.floorScore = floorScore
        m.shortHours6 = short6; m.capUnder6h = cap6; m.shortHours5 = short5; m.capUnder5h = cap5
        m.id = "sleep-v2@cloud"; m.version = version
        return Accepted(model: m, version: version, appliedAt: now)
    }

    /// Where an accepted model is cached, so a launch does not depend on the network.
    enum Cache {
        static let key = "agara.sleepScoreConfig"
        /// Re-fetch at most once per 12 h — same cadence as the coach summary, and a rollback stays quick.
        static let ttl: TimeInterval = 12 * 60 * 60

        static func isFresh(appliedAt: Date, now: Date) -> Bool {
            let age = now.timeIntervalSince(appliedAt)
            return age >= 0 && age < ttl
        }

        /// The cached override, or the compiled default — never a second hardcoded copy of the numbers.
        static func model(raw: String?, now: Date = Date()) -> SleepScore.Model {
            guard let raw, let data = raw.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return SleepScore.Model()
            }
            let accepted = parse(value: o["value"] as? [String: Any],
                                 model: o["model"] as? Int ?? -1,
                                 version: o["version"] as? Int ?? -1,
                                 now: now)
            return (accepted as? Accepted)?.model ?? SleepScore.Model()
        }

        static func encode(value: [String: Any], model: Int, version: Int, appliedAt: Date) -> String {
            let o: [String: Any] = ["model": model, "version": version,
                                    "appliedAt": appliedAt.timeIntervalSince1970, "value": value]
            guard let data = try? JSONSerialization.data(withJSONObject: o) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    /// The model in force: the installed override if any, else the compiled default.
    private static var installed: SleepScore.Model?

    static func install(_ model: SleepScore.Model?) { installed = model }
    static func active() -> SleepScore.Model { installed ?? SleepScore.Model() }

    /// One refresh step: `fetch` returns the record (or nil when the server has none / the call failed), `raw` is the
    /// cache as it stands. Returns the new cache string when it changed, nil when nothing should be written.
    static func refresh(fetch: (String) async -> [String: Any]?, raw: String?, now: Date = Date(),
                        key: String = "sleep_score") async -> String? {
        let cached = raw.flatMap { $0.data(using: .utf8) }
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        if let appliedAt = (cached?["appliedAt"] as? NSNumber)?.doubleValue,
           isFresh(epoch: appliedAt, now: now) {
            return nil                                    // at most one fetch per 12 h
        }
        guard let record = await fetch(key) else { return nil }   // offline / no record: keep what we have
        let model = record["model"] as? Int ?? -1
        let version = record["version"] as? Int ?? -1
        let value = record["value"] as? [String: Any] ?? [:]
        let accepted = parse(value: value, model: model, version: version, now: now)
        if let ok = accepted as? Accepted { install(ok.model) } else { install(nil) }
        return Cache.encode(value: (accepted as? Accepted) != nil ? value : [:],
                            model: model, version: version, appliedAt: now)
    }

    /// The compiled default, exposed for the settings/debug UI that names the model in use.
    static func compiledDefault() -> SleepScore.Model { SleepScore.Model() }

    private static func isFresh(epoch: Double, now: Date) -> Bool {
        Cache.isFresh(appliedAt: Date(timeIntervalSince1970: epoch), now: now)
    }
}
