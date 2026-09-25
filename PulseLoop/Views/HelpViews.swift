import SwiftUI
import Observation

/// A small ⓘ next to a metric header or stat label. Tap → a one-sentence popover (copy from
/// `docs/strings/help.yaml` → `AgaraHelp`); tap outside to close. Stays a popover on iPhone (no sheet).
/// Mirrors Android `HelpTip`.
struct HelpTip: View {
    let text: String
    var size: CGFloat = 13
    @State private var shown = false

    init(_ text: String, size: CGFloat = 13) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(PulseColors.textMuted)
                .frame(minWidth: 24, minHeight: 24)   // the glyph is small; the target is not
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More info")
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .top) {
            HelpBubbleText(text: text)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The text inside a help or coach-mark popover: wraps within a comfortable width, no scrolling.
struct HelpBubbleText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PulseFont.footnote)
            .foregroundStyle(PulseColors.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(14)
            .presentationBackground(PulseColors.elevated)
    }
}

/// Which one-time hints have been seen. Persisted in UserDefaults (`coachMark.seen.<id>`); a hint is offered
/// only once every hint before it in `order` has been seen, so two popovers never compete. Same ids and order
/// as Android `CoachMark`.
@Observable
final class CoachMarkStore {
    static let shared = CoachMarkStore()

    static let ringChip = "ringChip"
    static let measure = "measure"
    /// Priority: the Measure button (Vitals) first, then the ring chip — Android's order.
    static let order = [measure, ringChip]

    static func key(_ id: String) -> String { "coachMark.seen.\(id)" }

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var seen: Set<String>
    /// Off under XCTest and with `-noCoachMarks YES` (screenshot tooling).
    var suppressed: Bool

    init(defaults: UserDefaults = .standard, suppressed: Bool? = nil) {
        self.defaults = defaults
        #if DEBUG
        // `-resetCoachMarks YES` (E2E): show every hint again, as on a fresh install.
        if suppressed == nil, UserDefaults.standard.bool(forKey: "resetCoachMarks") {
            for id in Self.order { defaults.removeObject(forKey: Self.key(id)) }
        }
        #endif
        seen = Set(Self.order.filter { defaults.bool(forKey: Self.key($0)) })
        self.suppressed = suppressed
            ?? (NSClassFromString("XCTestCase") != nil || UserDefaults.standard.bool(forKey: "noCoachMarks"))
    }

    func isSeen(_ id: String) -> Bool { seen.contains(id) }

    /// Unseen, not suppressed, and every earlier hint already seen.
    func shouldShow(_ id: String) -> Bool {
        guard !suppressed, !seen.contains(id) else { return false }
        guard let index = Self.order.firstIndex(of: id) else { return true }
        return Self.order[..<index].allSatisfy(seen.contains)
    }

    func markSeen(_ id: String) {
        seen.insert(id)
        defaults.set(true, forKey: Self.key(id))
    }

    /// Settings › Developer can bring the hints back.
    func resetAll() {
        for id in Self.order { defaults.removeObject(forKey: Self.key(id)) }
        seen.removeAll()
    }
}

/// A one-time hint anchored to a control: pops up (as a popover) shortly after the control appears, the first
/// time only; tapping anywhere dismisses it and marks it seen. Mirrors Android `CoachMark`.
struct CoachMark: ViewModifier {
    let id: String
    let text: String
    var arrowEdge: Edge = .top
    @State private var store = CoachMarkStore.shared
    @State private var shown = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $shown, arrowEdge: arrowEdge) {
                HelpBubbleText(text: text)
                    .contentShape(Rectangle())
                    .onTapGesture { shown = false }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Double-tap to dismiss")
                    .accessibilityIdentifier("coachMark.\(id)")
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: shown) { _, now in
                if !now { store.markSeen(id) }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false; shown = false }
            // Re-evaluated when an earlier hint is dismissed, so the next one can follow.
            .task(id: store.shouldShow(id)) {
                guard store.shouldShow(id) else { return }
                // Let the screen settle (tab transition, first layout) before popping up.
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled, visible, store.shouldShow(id) else { return }
                shown = true
            }
    }
}

extension View {
    /// One-time hint on this control (see `CoachMark`).
    func coachMark(_ id: String, text: String, arrowEdge: Edge = .top) -> some View {
        modifier(CoachMark(id: id, text: text, arrowEdge: arrowEdge))
    }
}

extension MetricKind {
    /// The ⓘ sentence for this metric's card and detail header (`AgaraHelp`); nil where there is none yet.
    var helpText: String? {
        switch self {
        case .heartRate: return "Resting: \(AgaraHelp.restingHr)\nPeak: \(AgaraHelp.peakHr)"
        case .spo2: return AgaraHelp.spo2
        case .hrv: return AgaraHelp.hrv
        case .bloodPressure: return AgaraHelp.bloodPressure
        case .stress: return AgaraHelp.stress
        case .glucose: return AgaraHelp.glucose
        case .respiration: return AgaraHelp.respiration
        case .met: return AgaraHelp.met
        case .cardiacLoad: return AgaraHelp.cardiacLoad
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid: return AgaraHelp.bloodComponents
        case .fatigue, .temperature: return nil
        }
    }
}
