import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
import SwiftData
#endif

/// Live measurement sheet — a view of `MeasurementService`, the app-scoped engine that actually runs the test.
/// Opening the sheet starts the spec (or resumes the one already running); closing it with a swipe leaves the
/// measurement running (the in-app pill and, in the background, a notification report it); Cancel stops it.
/// A disconnected ring surfaces an error — it never fabricates a reading, because a fake vital saved to history
/// is indistinguishable from a real one.
///
/// THE RING IS ONE CLOCK, and it only ever tells the truth about time:
///
///  * `.hr` is the single measurement with a genuinely fixed duration — it samples its whole window
///    (see `RingSyncCoordinator.measureHR`), so the ring fills 0→full while a countdown ticks to zero.
///    The window is read from the coordinator, never copied, so the fill can't desync from the measure.
///  * every other kind returns the instant its value lands, at a time nobody can predict. They get an
///    indeterminate sweep and a count-*up*: an honest "still working", not a promise we can't keep.
///
/// Both are derived from wall-clock time via `TimelineView(.animation)`, so they keep moving under
/// Reduce Motion (a TimelineView tick is not accessibility "motion"). Reduce Motion gates only the
/// decorative heartbeat and beat-rings; it never freezes a value the user is waiting on.
struct MeasurementSheet: View {
    /// `.vitals` is one sweep that returns every metric the ring computes (the ring's `0x24` packet);
    /// the rest are single-metric spot readings on devices that measure one thing at a time.
    enum Kind: Hashable { case hr, spo2, hrv, bloodPressure, vitals, stress, glucose, bloodComponents }

    /// The measurement lifecycle. `searching` is the working state — counting down (HR) or up (rest).
    enum Stage { case preparing, searching, locking, result, error }

    let spec: MeasurementSpec
    private var kind: Kind { spec.kind }
    @Environment(\.dismiss) private var dismiss
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [UserProfile]
    @State private var features = AgaraFeatureStore.shared
    /// The engine: stage, reading, clock and error all live there, so they outlive this sheet.
    @State private var service = MeasurementService.shared

    // MARK: State (view-only; the measurement's own state is the service's)
    private var stage: Stage { service.spec?.id == spec.id ? service.stage : .preparing }
    private var reading: MeasurementReading? { service.spec?.id == spec.id ? service.reading : nil }
    private var measureStart: Date? { service.spec?.id == spec.id ? service.measureStart : nil }
    /// The sheet opened on an outcome that landed while it was closed: hold it until Done, so it can be read.
    @State private var openedOnOutcome = false
    /// Coarse elapsed clock (0.5s), used only for copy swaps and the throttled VoiceOver bucket —
    /// never for the ring, which is time-derived.
    @State private var elapsed: TimeInterval = 0
    @State private var announcedStillWorking = false
    /// One-shot so the "reading acquired" haptic fires once per measurement.
    @State private var acquiredHaptic = false
    @AccessibilityFocusState private var errorFocus: Bool

    // MARK: Animation drivers (the ONLY Reduce-Motion gates)
    @State private var ambientPulse = false
    @State private var beatPulse = false
    @State private var ringColor: Color = .clear
    @State private var resultBounce: CGFloat = 1

    #if canImport(UIKit)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let notify = UINotificationFeedbackGenerator()
    #endif

    private let elapsedTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - Per-kind tokens
    //
    // `Kind` answers everything that depends only on which metric this is — see
    // `MeasurementKindPresentation`. The sheet keeps only what depends on the measurement's *state*.

    private var color: Color { kind.tint }
    private var name: String { kind.title }
    private var unit: String {
        kind == .glucose ? UnitsFormatter.glucoseUnit(glucoseUnit) : kind.unit
    }
    private var instruction: String { kind.instruction }
    private var glucoseUnit: GlucoseUnit { UserPhysiologyProfile(profiles.first).preferredGlucoseUnit }
    private var sex: BiologicalSex { BiologicalSex(profileSex: profiles.first?.sex) }
    /// The ring is on its charger (flag `charging_state`): measuring is blocked, with a banner.
    private var ringCharging: Bool { features.isOn(.chargingState) && ble.isCharging }

    /// The one measurement with a fixed, known duration — so the only one we can honestly count down.
    /// Sourced from the coordinator: copying the literal is how the ring and the measurement desync.
    /// Nil in demo mode too — no 30s window is running there, so a countdown would be pure theatre.
    private var countdownWindow: Double? {
        guard kind == .hr, ble.state == .connected else { return nil }
        return Double(coordinator.hrMeasureSeconds)
    }

    /// The big number in the ring. Blood pressure shows the systolic/diastolic pair.
    private var readingText: String? {
        if kind == .bloodComponents { return nil }   // five values: shown in the result grid, not the ring
        guard let reading else { return nil }
        if kind == .glucose, let mgdl = reading.glucoseMgdl {
            return UnitsFormatter.glucose(mgdl: mgdl, unit: glucoseUnit).value
        }
        guard let value = reading.value else { return nil }
        if kind == .bloodPressure, let secondary = reading.secondary { return "\(value)/\(secondary)" }
        return "\(value)"
    }

    private var vitals: RingSyncCoordinator.VitalsReading? { reading?.vitals }
    private var components: BloodComponentsReading? { reading?.components }

    /// Explicit Done (vs auto-dismiss) is required under VoiceOver or Switch Control — and for the
    /// combined sweep, which has several numbers to read.
    private var needsExplicitDone: Bool {
        if kind == .vitals || kind == .bloodComponents || openedOnOutcome { return true }
        #if DEBUG
        // `-measureHoldResult YES` (E2E tooling): keep the result on screen until Done, so a UI test can
        // read it instead of racing the 1.3 s auto-dismiss.
        if DebugLaunch.bool("measureHoldResult") { return true }
        #endif
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(24)

            // The combined sweep returns a whole grid rather than one number, so at result it replaces
            // the ring entirely (see `VitalsResultsView`). Every other kind keeps the ring.
            if ringCharging, stage != .result {
                ChargingBanner()
                    .padding(.horizontal, 24)
            }
            if stage == .result, kind == .vitals, let vitals {
                VitalsResultsView(vitals: vitals)
                Spacer(minLength: 0)
            } else if stage == .result, kind == .bloodComponents, let components {
                BloodComponentsResultView(reading: components, unit: glucoseUnit, sex: sex)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else {
                measuringContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgaraColors.background.ignoresSafeArea())
        .agaraGlassContainer()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Measuring \(name)")
        .overlay(alignment: .bottom) { statusElement }
        .onReceive(elapsedTimer) { _ in tickElapsed() }
        // A real bpm landed mid-window (HR runs the full window regardless, so this doesn't advance the
        // stage — it just gives the moment a tactile beat and lets the live value take over the centre).
        .onChange(of: coordinator.measurementReceivedReading) { _, received in
            guard kind == .hr, received, !acquiredHaptic else { return }
            acquiredHaptic = true
            #if canImport(UIKit)
            softImpact.impactOccurred(intensity: 0.7)
            #endif
        }
        .onAppear(perform: startOrResume)
        .onChange(of: service.stage) { _, new in
            guard service.spec?.id == spec.id else { return }
            apply(new)
        }
        .onChange(of: service.runID) { _, _ in resetVisuals() }
        // A result that auto-dismisses; one the user must read waits for Done.
        .task(id: stage) {
            guard stage == .result, !needsExplicitDone else { return }
            try? await Task.sleep(for: .seconds(1.8))
            if Task.isCancelled { return }
            close()
        }
        // The user saw the outcome once the sheet goes away (swipe included); a running test keeps going.
        .onDisappear { if service.spec?.id == spec.id { service.acknowledge() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.eyebrow(isCombinedSweep: kind == .vitals))
                    .font(AgaraFont.micro).tracking(1.8)
                    .foregroundStyle(stage.eyebrowColor(tint: color))
                    .contentTransition(.opacity)
                Text(name).font(AgaraFont.title3).foregroundStyle(AgaraColors.textPrimary)
            }
            Spacer()
            controlButton
        }
    }

    /// Cancel while working, Done at result.
    private var controlButton: some View {
        Group {
            switch stage {
            case .preparing, .searching, .locking:
                // Cancel stops the ring's test; a swipe down leaves it running in the background.
                Button("Cancel") { service.cancel(); dismiss() }
                    .accessibilityHint("Stops measuring and closes without saving.")
            case .result:
                Button("Done") { close() }
            case .error:
                EmptyView()
            }
        }
        .font(AgaraFont.footnote)
        .foregroundStyle(AgaraColors.textPrimary)
        .padding(.horizontal, 14)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Capsule())
        .agaraGlass(Capsule(), interactive: true)
    }

    // MARK: - Measuring content (ring + copy), vertically centred

    @ViewBuilder
    private var measuringContent: some View {
        VStack(spacing: 0) {
            Spacer()

            if stage == .error {
                errorState
                    .transition(.opacity)
            } else {
                ring
                    .frame(height: 260)
                    .accessibilityHidden(true)

                copyLine
                    .padding(.top, 24)
                    .padding(.horizontal, 24)

                if kind.isEstimate {
                    Text(AgaraCopy.estimateDisclaimer)
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                        .padding(.top, 10)
                }
            }

            Spacer()

            if stage == .result {
                Text("Saved")
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .agaraMaterialize(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - The ring

    private var ring: some View {
        MeasurementRingView(
            stage: stage,
            tint: color,
            symbolName: kind.symbolName,
            unit: unit.uppercased(),
            countdownWindow: countdownWindow,
            measureStart: measureStart,
            liveValue: liveValue,
            resultText: readingText,
            slowBreathing: kind.slowBreathing,
            ringColor: ringColor,
            resultBounce: resultBounce,
            ambientPulse: ambientPulse,
            beatPulse: beatPulse
        )
    }

    /// A value worth putting in the centre of the ring *during* the measurement. Only HR has one: it
    /// streams a real bpm mid-window. The rest have nothing trustworthy to show until they land — SpO₂
    /// in particular reports progress percentages through the same channel as its result, so a "live"
    /// SpO₂ number would sometimes just be a progress bar wearing a percent sign.
    private var liveValue: String? {
        guard kind == .hr, coordinator.measurementReceivedReading, let bpm = coordinator.latestHRValue else {
            return nil
        }
        return "\(bpm)"
    }

    // MARK: - Copy under the ring

    private var copyLine: some View {
        Text(copyText)
            .font(AgaraFont.subheadline.weight(.regular))
            .foregroundStyle(AgaraColors.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
            .contentTransition(.opacity)
    }

    private var copyText: String {
        switch stage {
        case .preparing: return instruction
        case .searching:
            if elapsed >= 20 { return "Just a few seconds more…" }
            if elapsed >= 12 {
                return kind == .hr ? "Still working — hold steady." : "Still working — stay still."
            }
            return kind.workingCopy
        case .locking: return kind == .hr ? "Locking it in…" : "Locking in your reading…"
        case .result: return "Saved to your history."
        case .error: return ""
        }
    }

    // MARK: - Error

    private var errorState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark")
                .font(AgaraFont.title.weight(.bold))
                .foregroundStyle(AgaraColors.danger)
                .frame(width: 80, height: 80)
                .background(AgaraColors.danger.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(AgaraColors.danger.opacity(0.3), lineWidth: 1))
                .accessibilityHidden(true)

            Text(errorMessage)
                .font(AgaraFont.subheadline.weight(.regular))
                .foregroundStyle(AgaraColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            HStack(spacing: 12) {
                Button("Try again") { retry() }
                    .agaraGlassButton(prominent: true)
                    .accessibilityFocused($errorFocus)

                Button("Close") { close() }
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .agaraGlass(Capsule(), interactive: true)
            }
            .padding(.top, 4)
        }
    }

    /// Chosen by the service when the test failed (not connected, charging, refused, not worn, or generic).
    private var errorMessage: String {
        service.errorMessage ?? kind.failureMessage
    }

    // MARK: - VoiceOver status

    private var statusElement: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("\(name) measurement")
            .accessibilityValue(statusValue)
            .accessibilityIdentifier("measurement.status")
            .accessibilityAddTraits(isBusy ? .updatesFrequently : [])
    }

    private var isBusy: Bool { stage == .preparing || stage == .searching || stage == .locking }

    /// Bucketed to ~10s while working — never a per-second string, which VoiceOver would spam.
    private var statusValue: String {
        switch stage {
        case .preparing: return "Preparing"
        case .searching:
            guard let window = countdownWindow else { return "Measuring \(name)" }
            let bucket = max(0, Int((window - elapsed) / 10) * 10)
            return bucket > 0 ? "Measuring \(name), about \(bucket) seconds" : "Measuring \(name)"
        case .locking: return "Locking in your reading"
        case .result:
            if kind == .vitals {
                let count = vitals.map { VitalsResultsView.tiles(for: $0).count } ?? 0
                return "Reading complete. \(count) results. Saved."
            }
            if kind == .bloodComponents { return "Estimate complete. Five results. Saved." }
            guard let readingText else { return "Complete" }
            return "\(readingText) \(unit). Saved."
        case .error: return errorMessage
        }
    }

    // MARK: - Stage transitions (visuals only — the service drives the stages)

    /// Open on this spec: resume it if the service is already on it (running or finished), else start it.
    private func startOrResume() {
        #if canImport(UIKit)
        lightImpact.prepare()
        softImpact.prepare()
        notify.prepare()
        #endif
        if service.spec?.id == spec.id {
            openedOnOutcome = service.hasUnacknowledgedOutcome
            restoreVisuals(for: service.stage)
        } else {
            service.start(spec, glucoseUnit: glucoseUnit)
        }
    }

    /// Reopened mid-measurement or on a result: set the picture without replaying haptics or announcements.
    private func restoreVisuals(for stage: Stage) {
        switch stage {
        case .searching, .locking:
            ambientPulse = true
            beatPulse = true
            elapsed = measureStart.map { Date().timeIntervalSince($0) } ?? 0
        case .result:
            ringColor = AgaraColors.success
        case .preparing, .error:
            break
        }
    }

    private func apply(_ stage: Stage) {
        switch stage {
        case .preparing: break
        case .searching: enterSearching()
        case .locking: enterLocking()
        case .result: enterResult()
        case .error: enterError()
        }
    }

    private func enterSearching() {
        elapsed = 0
        announcedStillWorking = false
        withAnimation(.easeInOut(duration: 0.25)) {
            ambientPulse = true
            beatPulse = true
        }
        #if canImport(UIKit)
        lightImpact.impactOccurred()
        #endif
        announce("Measuring \(name)")
    }

    private func enterLocking() {
        // The stage itself changes in the service; this is only the bounce.
        withAnimation(reduceMotion ? .none : AgaraMotion.bouncy) { resultBounce = 1 }
    }

    private func enterResult() {
        withAnimation(.easeInOut(duration: 0.3)) { ringColor = AgaraColors.success }
        #if canImport(UIKit)
        notify.notificationOccurred(.success)
        #endif
        if !reduceMotion {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { resultBounce = 1.06 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.18)) { resultBounce = 1.0 }
        }
        announce(statusValue)
    }

    private func enterError() {
        #if canImport(UIKit)
        notify.notificationOccurred(.error)
        #endif
        announce(errorMessage)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            errorFocus = true
        }
    }

    private func tickElapsed() {
        guard stage == .searching, let start = measureStart else { return }
        elapsed = Date().timeIntervalSince(start)
        if !announcedStillWorking, elapsed >= 12 {
            announcedStillWorking = true
            announce("Still working, keep still")
        }
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(message).post()
        #endif
    }

    /// Done / Close / auto-dismiss: the outcome has been seen.
    private func close() {
        service.acknowledge()
        dismiss()
    }

    private func resetVisuals() {
        elapsed = 0
        ringColor = .clear
        ambientPulse = false
        beatPulse = false
        resultBounce = 1
        acquiredHaptic = false
        announcedStillWorking = false
        openedOnOutcome = false
    }

    /// "Try again": a fresh run of the same spec (the service replaces the failed outcome).
    private func retry() {
        resetVisuals()
        service.start(spec, glucoseUnit: glucoseUnit)
    }
}
