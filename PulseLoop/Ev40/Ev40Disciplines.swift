import Foundation

/// The eight EV40 disciplines, in the order that is the wire format of `ev40_days.mask` (cloud-v2 §3.2, plan
/// "bit order is a wire format"): bit 0 Hydrate … bit 7 Rest. The order is **append-only** — a discipline is
/// never renumbered, and a new one would take the next free bit — because the server stores the number, not the
/// names, and Android reads the same bits.
///
/// Names come from the shared catalog (`docs/strings/brand.yaml` → `AgaraCopy`, Rule 5); the glyphs are the
/// platform's own (SF Symbols here, Material icons on Android) because a symbol name is not shared copy.
enum Ev40Discipline: Int, CaseIterable, Identifiable, Sendable {
    case hydrate = 0
    case move = 1
    case grow = 2
    case fuel = 3
    case energize = 4
    case fastRelease = 5
    case documentShare = 6
    case rest = 7

    var id: Int { rawValue }

    /// The bit this discipline owns in the day's mask.
    var bit: Int { 1 << rawValue }

    var title: String {
        switch self {
        case .hydrate: AgaraCopy.ev40DisciplineHydrate
        case .move: AgaraCopy.ev40DisciplineMove
        case .grow: AgaraCopy.ev40DisciplineGrow
        case .fuel: AgaraCopy.ev40DisciplineFuel
        case .energize: AgaraCopy.ev40DisciplineEnergize
        case .fastRelease: AgaraCopy.ev40DisciplineFastRelease
        case .documentShare: AgaraCopy.ev40DisciplineDocumentShare
        case .rest: AgaraCopy.ev40DisciplineRest
        }
    }

    var symbol: String {
        switch self {
        case .hydrate: "drop.fill"
        case .move: "figure.run"
        case .grow: "book.fill"
        case .fuel: "fork.knife"
        case .energize: "bolt.fill"
        case .fastRelease: "wind"
        case .documentShare: "camera.fill"
        case .rest: "moon.fill"
        }
    }

    /// The identifier the UI tests and VoiceOver use (`ev40.toggle.hydrate`).
    var testID: String { "ev40.toggle." + String(describing: self) }
}

/// Pure mask arithmetic — the one place both the store and the views do it, so the count, the toggle and the
/// completion rule cannot disagree (Rule 10).
enum Ev40Disciplines {
    static let all = Ev40Discipline.allCases
    static var fullMask: Int { all.reduce(0) { $0 | $1.bit } }

    static func isOn(_ mask: Int, _ discipline: Ev40Discipline) -> Bool { mask & discipline.bit != 0 }

    /// The mask with one discipline flipped. Only the eight known bits survive, so a corrupt stored value can never
    /// grow a ninth checkbox.
    static func toggle(_ mask: Int, _ discipline: Ev40Discipline) -> Int {
        (mask ^ discipline.bit) & fullMask
    }

    /// How many of the eight are done (0…8).
    static func count(_ mask: Int) -> Int { all.reduce(0) { $0 + (isOn(mask, $1) ? 1 : 0) } }

    static func isComplete(_ mask: Int) -> Bool { count(mask) == all.count }

    /// Bits outside the eight are dropped: the server's 0…255 allows a value an older or newer build could set.
    static func normalised(_ mask: Int) -> Int { mask & fullMask }
}
