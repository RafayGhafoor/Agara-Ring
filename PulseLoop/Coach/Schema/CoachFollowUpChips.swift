import Foundation

/// An answer's follow-up chips, always exactly three.
///
/// The wire contract (`docs/ring/coach-proxy.md` §8) makes `follow_up_chips` exactly three, each specific to the
/// user's numbers. A bring-your-own-key provider in a debug build is not held to it, and messages written before
/// the contract shipped carry none, so the renderer normalises instead of trusting: keep what the answer gave (at
/// most three, deduped, blanks dropped) and top up from the conversation's data-based starter prompts.
enum CoachFollowUpChips {
    /// How many chips an answer shows — the contract's number, not a per-screen preference.
    static let count = 3

    /// Exactly `count` chips: the answer's own first, then `fallback` for the rest.
    static func balanced(_ chips: [String], fallback: [String] = [], count: Int = count) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func take(_ raw: String) -> Bool {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return false }
            out.append(text)
            return true
        }
        for chip in chips where out.count < count { _ = take(chip) }
        for chip in fallback where out.count < count { _ = take(chip) }
        return out
    }
}
