import Foundation

/// A number (or piece of text) a nudge wording asks for. The renderer owns formatting, so a rule never builds
/// user-visible text itself: locale number grouping, duration style and plurals all happen here, once.
enum NudgeSlotValue: Equatable, Sendable {
    /// A counted thing with a noun: 1 step / 2,400 steps.
    case count(Int, unit: NudgeUnit)
    /// A bare number for hyphenated adjectives ("{walk_min}-minute walk", "{streak_days}-day streak").
    case number(Int)
    case duration(minutes: Double)
    case percent(Double)
    /// Minutes after local midnight, rendered as a localized clock time.
    case timeOfDay(Int)
    case text(String)
}

enum NudgeUnit: String, Sendable {
    case step, minute, hour, day

    var singular: String {
        switch self {
        case .step: return "step"
        case .minute: return "minute"
        case .hour: return "hour"
        case .day: return "day"
        }
    }

    var plural: String {
        switch self {
        case .step: return "steps"
        case .minute: return "minutes"
        case .hour: return "hours"
        case .day: return "days"
        }
    }
}

enum NudgeSlot: String, CaseIterable, Sendable {
    case stepsLeft = "steps_left"
    case stepsDone = "steps_done"
    case goalSteps = "goal_steps"
    case walkMin = "walk_min"
    case sleepShort = "sleep_short"
    case sleepTotal = "sleep_total"
    case sleepGoal = "sleep_goal"
    case rhrDelta = "rhr_delta"
    case stressMinutes = "stress_minutes"
    case streakDays = "streak_days"
    case driftMinutes = "drift_minutes"
    case medianBedtime = "median_bedtime"
    case medianWake = "median_wake"
    case pctAbove = "pct_above"
    case bestWin = "best_win"
    case weekDays = "week_days"
    case hoursSinceSync = "hours_since_sync"
    case ringName = "ring_name"
    case percent = "percent"

    var placeholder: String { "{\(rawValue)}" }
}

/// Renders a wording from `AgaraCopy.nudge…` with its slots filled, and picks the rotation variant.
///
/// A wording whose slots cannot all be filled is not eligible: a nudge never ships a raw `{slot}`.
enum NudgeTemplate {

    /// The same wording is not reused inside this many days.
    static let rotationWindowDays = 7

    static func variants(for rule: NudgeRule) -> [(id: String, text: String)] {
        switch rule {
        case .a1: return [("a1_v1", AgaraCopy.nudgeA1V1), ("a1_v2", AgaraCopy.nudgeA1V2), ("a1_v3", AgaraCopy.nudgeA1V3)]
        case .a2: return [("a2_v1", AgaraCopy.nudgeA2V1), ("a2_v2", AgaraCopy.nudgeA2V2), ("a2_v3", AgaraCopy.nudgeA2V3)]
        case .a3: return [("a3_v1", AgaraCopy.nudgeA3V1), ("a3_v2", AgaraCopy.nudgeA3V2), ("a3_v3", AgaraCopy.nudgeA3V3)]
        case .b1: return [("b1_v1", AgaraCopy.nudgeB1V1), ("b1_v2", AgaraCopy.nudgeB1V2), ("b1_v3", AgaraCopy.nudgeB1V3)]
        case .b2: return [("b2_v1", AgaraCopy.nudgeB2V1), ("b2_v2", AgaraCopy.nudgeB2V2), ("b2_v3", AgaraCopy.nudgeB2V3)]
        case .b3: return [("b3_v1", AgaraCopy.nudgeB3V1), ("b3_v2", AgaraCopy.nudgeB3V2), ("b3_v3", AgaraCopy.nudgeB3V3)]
        case .b4: return [("b4_v1", AgaraCopy.nudgeB4V1)]
        case .c1: return [("c1_v1", AgaraCopy.nudgeC1V1), ("c1_v2", AgaraCopy.nudgeC1V2), ("c1_v3", AgaraCopy.nudgeC1V3)]
        case .e1: return [("e1_v1", AgaraCopy.nudgeE1V1), ("e1_v2", AgaraCopy.nudgeE1V2), ("e1_v3", AgaraCopy.nudgeE1V3)]
        case .e2: return [("e2_v1", AgaraCopy.nudgeE2V1), ("e2_v2", AgaraCopy.nudgeE2V2), ("e2_v3", AgaraCopy.nudgeE2V3)]
        case .f1: return [("f1_v1", AgaraCopy.nudgeF1V1), ("f1_v2", AgaraCopy.nudgeF1V2), ("f1_v3", AgaraCopy.nudgeF1V3)]
        case .f2: return [("f2_v1", AgaraCopy.nudgeF2V1), ("f2_v2", AgaraCopy.nudgeF2V2), ("f2_v3", AgaraCopy.nudgeF2V3)]
        case .g1: return [("g1_v1", AgaraCopy.nudgeG1V1), ("g1_v2", AgaraCopy.nudgeG1V2), ("g1_v3", AgaraCopy.nudgeG1V3)]
        }
    }

    /// The message the Coach tab opens with when the user taps the nudge or "Why?". Carries the evidence numbers;
    /// it never calls a model by itself.
    static func seed(for rule: NudgeRule) -> String {
        switch rule {
        case .a1: return AgaraCopy.nudgeA1Seed
        case .a2: return AgaraCopy.nudgeA2Seed
        case .a3: return AgaraCopy.nudgeA3Seed
        case .b1: return AgaraCopy.nudgeB1Seed
        case .b2: return AgaraCopy.nudgeB2Seed
        case .b3: return AgaraCopy.nudgeB3Seed
        case .b4: return AgaraCopy.nudgeB4Seed
        case .c1: return AgaraCopy.nudgeC1Seed
        case .e1: return AgaraCopy.nudgeE1Seed
        case .e2: return AgaraCopy.nudgeE2Seed
        case .f1: return AgaraCopy.nudgeF1Seed
        case .f2: return AgaraCopy.nudgeF2Seed
        case .g1: return AgaraCopy.nudgeG1Seed
        }
    }

    /// Render `template` with `slots`. Returns nil when a slot is missing — an unfilled wording is not eligible.
    static func render(
        _ template: String,
        slots: [NudgeSlot: NudgeSlotValue],
        locale: Locale = .current
    ) -> String? {
        var output = template
        for slot in NudgeSlot.allCases where output.contains(slot.placeholder) {
            guard let value = slots[slot] else { return nil }
            let (text, unit) = formatted(value, slot: slot, locale: locale)
            // The catalog wording carries the noun itself ("{steps_left} steps", "for {stress_minutes} minutes"):
            // drop the literal noun so the rendered sentence does not read "2,400 steps steps", while the value
            // keeps the plural the count actually needs ("1 step").
            if let unit {
                for noun in [unit.singular, unit.plural] {
                    let phrase = "\(slot.placeholder) \(noun)"
                    var search = output.startIndex
                    while let range = output.range(of: phrase, range: search..<output.endIndex) {
                        let next = output.index(range.upperBound, offsetBy: 0)
                        let atWordBoundary = next == output.endIndex
                            || output[next] == " "
                            || output[next].isPunctuation
                            || output[next].isNewline
                        if atWordBoundary {
                            output = output.replacingCharacters(in: range, with: slot.placeholder)
                        }
                        search = output.index(range.lowerBound, offsetBy: phrase.count, limitedBy: output.endIndex) ?? output.endIndex
                        if search >= output.endIndex { break }
                    }
                }
            }
            output = output.replacingOccurrences(of: slot.placeholder, with: text)
        }
        return output.contains("{") ? nil : output
    }

    /// Pick the variant the user has not seen in `rotationWindowDays`. `lastUsed` is the persisted
    /// template id → when it was last shown. Falls back to the least recently shown variant.
    static func rotation(
        for rule: NudgeRule,
        slots: [NudgeSlot: NudgeSlotValue],
        lastUsed: [String: Date],
        now: Date,
        locale: Locale = .current
    ) -> (id: String, text: String)? {
        let window = TimeInterval(rotationWindowDays) * 86_400
        let variants = variants(for: rule).filter { candidate in
            render(candidate.text, slots: slots, locale: locale) != nil
        }
        let fresh = variants.first { candidate in
            guard let used = lastUsed[candidate.id] else { return true }
            return now.timeIntervalSince(used) >= window
        }
        let chosen = fresh ?? variants.min { a, b in
            (lastUsed[a.id] ?? .distantPast) < (lastUsed[b.id] ?? .distantPast)
        }
        guard let chosen, let text = render(chosen.text, slots: slots, locale: locale) else { return nil }
        return (chosen.id, text)
    }

    // MARK: Formatting

    private static func formatted(
        _ value: NudgeSlotValue,
        slot: NudgeSlot,
        locale: Locale
    ) -> (text: String, unit: NudgeUnit?) {
        switch value {
        case let .count(number, unit):
            let digits = integer(number, locale: locale)
            return ("\(digits) \(number == 1 ? unit.singular : unit.plural)", unit)
        case let .number(number):
            return (integer(number, locale: locale), nil)
        case let .duration(minutes):
            return (duration(minutes, locale: locale), nil)
        case let .percent(value):
            return (percent(value, locale: locale), nil)
        case let .timeOfDay(minute):
            return (clock(minute, locale: locale), nil)
        case let .text(text):
            return (text, nil)
        }
    }

    static func integer(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "2 h", "1 h 30 min" — abbreviated and localized, so a one-hour sleep reads "1 hr" and never "1 hrs".
    static func duration(_ minutes: Double, locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.calendar?.locale = locale
        formatter.collapsesLargestUnit = false
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, minutes) * 60) ?? "\(Int(minutes.rounded())) min"
    }

    static func percent(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value / 100)) ?? "\(Int(value.rounded()))%"
    }

    static func clock(_ minuteOfDay: Int, locale: Locale) -> String {
        let normalized = ((minuteOfDay % 1440) + 1440) % 1440
        var components = DateComponents()
        components.hour = normalized / 60
        components.minute = normalized % 60
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return String(format: "%02d:%02d", normalized / 60, normalized % 60) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
