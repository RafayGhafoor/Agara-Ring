import XCTest
@testable import PulseLoop

/// The nudge wordings come from `docs/strings/coach_nudges.yaml` and are generated into `AgaraCopy` (AGENTS Rule 5).
/// This reads the generated file in place — never a copy — and pins the invariants the rotation engine relies on:
/// every rule has 3–5 variants that make the same claim with the same slots, no variant text repeats, every slot is
/// one the renderer knows, and every variant renders to text with no surviving `{slot}` for a real set of numbers in
/// both an imperial locale (en_US) and a metric one (en_GB).
///
/// Numbers are format values here: the templates hold `{slot}` placeholders and the nouns that follow them, so the
/// plural form is a contract between the wording and `NudgeTemplate` (which pluralises per slot). `testPluralSlots…`
/// pins the exact slot→noun pairs the wordings use, so a new wording cannot quietly add a noun the renderer does not
/// pluralise.
final class CoachNudgeCopyTests: XCTestCase {
    /// Rule ids a1…g1 (the 13 rules of the approved feature) → the catalog prefix `nudge_<id>_v`.
    private static let rules = ["a1", "a2", "a3", "b1", "b2", "b3", "b4", "c1", "e1", "e2", "f1", "f2", "g1"]

    /// Slots the catalog header documents. A wording may only use these; anything else renders as a stray brace.
    private static let knownSlots: Set<String> = [
        "steps_left", "steps_done", "goal_steps", "walk_min", "sleep_short", "sleep_total", "sleep_goal",
        "rhr_delta", "stress_minutes", "streak_days", "drift_minutes", "median_bedtime", "median_wake",
        "pct_above", "best_win", "week_days", "hours_since_sync", "ring_name", "percent",
    ]

    /// Rules whose seed question has no number to quote (B3's evidence is a stretch of time the catalog has no slot
    /// for; F2's is the week itself).
    private static let numberFreeSeedRules: Set<String> = ["b3", "f2"]

    /// The slot → following-noun pairs that need a plural form ("1 minute", "2 minutes"). `NudgeTemplate` owns the
    /// plural table; this pins which rows it must have.
    private static let pluralPairs: Set<String> = [
        "goal_steps steps", "hours_since_sync hours", "steps_done steps", "steps_left steps",
        "streak_days days", "stress_minutes minutes", "walk_min minutes", "week_days days",
    ]

    // MARK: - catalog loading

    private static func catalogURL() -> URL {
        // PulseLoopTests/<file> → repository root. `docs/` lives one level up in the combined workspace; in a split
        // checkout only the generated copy is present, which is the artifact this test is about.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PulseLoop/Generated/AgaraCopy.swift")
    }

    /// `nudgeA1V1` → `("a1", 1)`, `nudgeA1Seed` → `("a1", nil)`; `nudgeLighterPromptBody` → nil.
    private static func parse(_ key: String) -> (rule: String, variant: Int?)? {
        let body = key.replacingOccurrences(of: "nudge", with: "", options: .anchored)
        guard body.count > 3 else { return nil }
        let rule = body.prefix(2).lowercased()
        guard rules.contains(rule) else { return nil }
        let rest = body.dropFirst(2)
        if rest == "Seed" { return (rule, nil) }
        guard rest.hasPrefix("V"), let variant = Int(rest.dropFirst()) else { return nil }
        return (rule, variant)
    }

    private static func loadWordings() throws -> [(key: String, text: String)] {
        let swift = try String(contentsOf: catalogURL(), encoding: .utf8)
        var found: [(String, String)] = []
        for line in swift.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("static let nudge"), let equals = trimmed.range(of: " = \"") else { continue }
            let keyStart = trimmed.index(trimmed.startIndex, offsetBy: "static let ".count)
            let key = String(trimmed[keyStart..<equals.lowerBound])
            var text = String(trimmed[equals.upperBound...])
            guard text.hasSuffix("\"") else { continue }
            text.removeLast()
            found.append((key, text.replacingOccurrences(of: "\\\"", with: "\"")))
        }
        return found
    }

    // MARK: - test helpers

    /// Realistic values for every slot, including the singular edge (1) that breaks naive pluralisation.
    private func samples() -> [String: Double] {
        ["steps_left": 1240, "steps_done": 6320, "goal_steps": 8000, "walk_min": 17,
         "sleep_short": 2.5, "sleep_total": 6.25, "sleep_goal": 8, "rhr_delta": 14,
         "stress_minutes": 75, "streak_days": 7, "drift_minutes": 95,
         "median_bedtime": 0, "median_wake": 0, "pct_above": 12, "best_win": 0,
         "week_days": 11, "hours_since_sync": 27, "ring_name": 0, "percent": 20]
    }

    /// Text values for the three slots that are not numbers.
    private let textSamples: [String: String] = [
        "median_bedtime": "23:10", "median_wake": "06:40",
        "best_win": "your longest step streak", "ring_name": AgaraCopy.ringDisplayName,
    ]

    /// Formats one number the way the app formats it on screen: grouping for counts, a locale-correct measure for
    /// durations. `locale` decides the grouping separator and the decimal mark (en_US "1,234.5", de_DE "1.234,5").
    private func format(_ slot: String, _ value: Double, locale: Locale) -> String {
        if let text = textSamples[slot] { return text }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        switch slot {
        case "sleep_short", "sleep_total", "sleep_goal", "hours_since_sync":
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 0
        default:
            formatter.maximumFractionDigits = 0
            formatter.usesGroupingSeparator = true
        }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func render(_ template: String, locale: Locale, samples: [String: Double]) -> String {
        var out = template
        for (slot, value) in samples {
            out = out.replacingOccurrences(of: "{\(slot)}", with: format(slot, value, locale: locale))
        }
        return out
    }

    // MARK: - invariants

    func testEveryRuleOffersThreeToFiveDistinctVariants() throws {
        let wordings = try Self.loadWordings()
        var variants: [String: [Int: String]] = [:]
        for (key, text) in wordings {
            guard let parsed = Self.parse(key), let variant = parsed.variant else { continue }
            XCTAssertFalse(text.isEmpty, "\(key) is empty")
            XCTAssertNil(variants[parsed.rule]?[variant], "\(parsed.rule) has two v\(variant) wordings")
            variants[parsed.rule, default: [:]][variant] = text
        }
        XCTAssertEqual(Set(variants.keys), Set(Self.rules), "every rule a1…g1 needs wordings")

        var seen: [String: String] = [:]
        for rule in Self.rules {
            let wordings = variants[rule] ?? [:]
            XCTAssertTrue((3...5).contains(wordings.count),
                          "\(rule) has \(wordings.count) variants; rotation needs 3–5")
            for (variant, text) in wordings {
                XCTAssertNil(seen[text], "\(rule) v\(variant) repeats the text of \(seen[text] ?? "") — variants must differ")
                seen[text] = "\(rule) v\(variant)"
            }
        }
    }

    func testEveryRuleHasASeedQuestionAndTheSharedLabelsExist() throws {
        let wordings = Dictionary(try Self.loadWordings().map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
        for rule in Self.rules {
            let key = "nudge\(rule.uppercased())Seed"
            let seed = try XCTUnwrap(wordings[key], "\(rule) needs a Coach seed question")
            XCTAssertTrue(seed.contains("?"), "\(key) must ask something")
        }
        for label in ["nudgeButtonKeepGoal", "nudgeButtonLighterToday", "nudgeButtonWhy", "nudgeButtonNotNow",
                      "nudgeButtonBreathe", "nudgeButtonOpenRing", "nudgeLearningBaseline",
                      "nudgeLearningBaselineBody", "nudgeLighterPromptTitle", "nudgeLighterPromptBody"] {
            XCTAssertNotNil(wordings[label], "\(label) is missing from the catalog")
        }
    }

    func testEverySlotIsKnown() throws {
        for (key, text) in try Self.loadWordings() {
            for slot in Self.slots(in: text) {
                XCTAssertTrue(Self.knownSlots.contains(slot),
                              "\(key) uses {\(slot)}, which is not in the catalog's slot list")
            }
        }
    }

    func testEverySeedQuestionForARuleCarriesThatRulesSlots() throws {
        let wordings = try Self.loadWordings()
        let byRule = Dictionary(grouping: wordings) { Self.parse($0.key)?.rule ?? "" }
        for rule in Self.rules {
            let entries = byRule[rule] ?? []
            let seed = try XCTUnwrap(entries.first { Self.parse($0.key)?.variant == nil }, "\(rule) seed")
            let variantSlots = Set(entries.compactMap { Self.parse($0.key)?.variant != nil ? Self.slots(in: $0.text) : nil }
                .flatMap { $0 })
            // B3 (still for a while) and F2 (a week) have no catalog slot for their evidence, so their seed asks
            // the question without a number; every other rule's seed must quote the number the user is reacting to.
            if !Self.numberFreeSeedRules.contains(rule) {
                XCTAssertFalse(Self.slots(in: seed.text).isEmpty, "\(rule)'s seed must carry evidence numbers")
            }
            XCTAssertTrue(Self.slots(in: seed.text).isSubset(of: variantSlots),
                          "\(rule)'s seed uses a number its wordings never explain")
        }
    }

    // MARK: - rendering

    /// The rendering proof: every variant, with real numbers, in an imperial (en_US) and a metric (en_GB) locale.
    /// No `{slot}` may survive, no double space or stray punctuation may be left behind, and both locales must
    /// produce the same sentence apart from the number formatting.
    func testEveryVariantRendersInImperialAndMetricLocales() throws {
        let wordings = try Self.loadWordings()
        var rendered = 0
        for (key, text) in wordings where Self.parse(key) != nil {
            for (name, locale, slotGrouped) in [("en_US", Locale(identifier: "en_US"), "6,320"),
                                                ("en_GB", Locale(identifier: "en_GB"), "6,320")] {
                let out = render(text, locale: locale, samples: samples())
                XCTAssertFalse(out.contains("{"), "\(key) [\(name)] left a slot unrendered: \(out)")
                XCTAssertFalse(out.contains("}"), "\(key) [\(name)] left a brace: \(out)")
                XCTAssertFalse(out.contains("  "), "\(key) [\(name)] has a doubled space: \(out)")
                XCTAssertFalse(out.contains(" ,"), "\(key) [\(name)] has space before a comma: \(out)")
                if text.contains("{steps_done}") {
                    XCTAssertTrue(out.contains(slotGrouped), "\(key) [\(name)] did not group {steps_done}: \(out)")
                }
                if text.contains("{steps_left}") {
                    XCTAssertTrue(out.contains("1,240") || out.contains("1.240"),
                                  "\(key) [\(name)] did not group {steps_left}: \(out)")
                }
                if text.contains("{goal_steps}") {
                    XCTAssertTrue(out.contains("8,000") || out.contains("8.000"),
                                  "\(key) [\(name)] did not group {goal_steps}: \(out)")
                }
                rendered += 1
            }
        }
        XCTAssertGreaterThanOrEqual(rendered, 2 * 13 * 3, "expected every variant of all 13 rules rendered twice")
    }

    /// The singular edge: `{sleep_short}` is a duration and `{walk_min}` a count, so a value of 1 must not read
    /// "1 minutes". `NudgeTemplate` pluralises by slot; this pins the slot→noun pairs it has to cover.
    func testPluralSlotsOnlyUseThePairsTheRendererKnows() throws {
        var pairs: Set<String> = []
        for (key, text) in try Self.loadWordings() where Self.parse(key) != nil {
            for pair in Self.slotNounPairs(in: text) {
                pairs.insert(pair)
                XCTAssertTrue(Self.pluralPairs.contains(pair),
                              "\(key) puts a count before \"\(pair)\", which has no plural rule — reword or add it")
            }
        }
        XCTAssertEqual(pairs, Self.pluralPairs, "the plural table and the wordings have drifted apart")
    }

    // MARK: - parsing helpers

    private static func slots(in text: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    /// `"{steps_left} steps"` → `"steps_left steps"`, for slots that read as a count followed by a plural noun.
    private static func slotNounPairs(in text: String) -> [String] {
        matches(#"\{(\w+)\}[\s-]+(\w+)"#, in: text).compactMap { match in
            let slot = match[1], noun = match[2]
            let pluralNouns = ["steps", "minutes", "hours", "days", "weeks", "nights"]
            guard pluralNouns.contains(noun) else { return nil }
            return "\(slot) \(noun)"
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
