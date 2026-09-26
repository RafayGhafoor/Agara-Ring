import SwiftUI

/// Drives Find ring: one `RingSignalSource` → `RingProximity` → the current `Reading`. Re-evaluates on every reading
/// and on its own tick, so "Out of range" appears after `findSignalLostS` of silence even with no new readings.
@MainActor
@Observable
final class FindRingModel {
    private(set) var reading = RingProximity.Reading.noSignal
    /// Bumped each time `FindRingHapticGate` says a nearer band has held — the view's haptic trigger.
    private(set) var hapticToken = 0
    @ObservationIgnored private var proximity = RingProximity()
    @ObservationIgnored private var hapticGate = FindRingHapticGate()
    @ObservationIgnored private var source: RingSignalSource?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    var isRunning: Bool { source != nil }

    func start(source: RingSignalSource) {
        stop()
        proximity = RingProximity()
        hapticGate.reset()
        reading = .noSignal
        self.source = source
        source.start { [weak self] dbm in self?.ingest(dbm) }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RingSignalSources.pollInterval)
                self?.refresh()
            }
        }
    }

    /// Stops polling and scanning (closing the screen must leave no radio work behind).
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        source?.stop()
        source = nil
    }

    private func ingest(_ dbm: Int) {
        proximity.add(rssi: dbm, at: Self.now())
        refresh()
    }

    private func refresh() {
        let now = Self.now()
        let next = proximity.reading(at: now)
        if next != reading { reading = next }
        if hapticGate.update(next.band, at: now) { hapticToken += 1 }
    }
}

extension RingProximity.Band {
    /// Green → light green → amber → orange → red (palette roles, so every theme recolours it).
    var color: Color {
        switch self {
        case .rightHere:  return AgaraColors.success
        case .veryClose:  return AgaraColors.readiness
        case .warmer:     return AgaraColors.zoneAmber
        case .far:        return AgaraColors.zoneOrange
        case .outOfRange: return AgaraColors.zoneRed.opacity(0.6)
        }
    }
}

/// Wearable › Ring actions › Find ring (flag `find_ring_proximity`): how near the ring is, from its Bluetooth signal.
/// Concentric circles light up and change colour by band, a pulse speeds up as you approach, the band label + trend
/// sit under it with the live dBm in small text. The ring vibrates only when the user taps "Make it vibrate"
/// (owner decision 2026-09-26), and only while connected. Closing stops polling, scanning and any vibration.
struct FindRingView: View {
    /// The ring can vibrate (`find_ring` flag + the ring's `a7` find-device capability).
    let canVibrate: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @State private var model = FindRingModel()

    private var reading: RingProximity.Reading { model.reading }
    private var connected: Bool { ble.state == .connected }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            ProximityCircles(band: reading.band)
                .frame(maxWidth: 340)
                .padding(.horizontal, AgaraShape.gutter)
            status
                .padding(.top, 24)
            Spacer(minLength: 12)
            Text(AgaraCopy.findRingHint)
                .font(AgaraFont.footnote)
                .foregroundStyle(AgaraColors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            vibrateControl
                .padding(.horizontal, AgaraShape.gutter)
                .padding(.bottom, 12)
        }
        .background(AgaraColors.background.ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .medium), trigger: model.hapticToken)
        .onAppear { model.start(source: RingSignalSources.make(client: ble)) }
        .onDisappear {
            model.stop()
            coordinator.stopFindingRing()
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(AgaraFont.headline)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(AgaraColors.cardSoft, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("findRing.close")
            Spacer()
        }
        .overlay {
            Text(AgaraCopy.findRingTitle)
                .font(AgaraFont.headline)
                .foregroundStyle(AgaraColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, AgaraShape.gutter)
        .padding(.top, 8)
    }

    private var status: some View {
        VStack(spacing: 8) {
            Text(reading.band.label)
                .font(AgaraFont.title2)
                .foregroundStyle(reading.band == .outOfRange ? AgaraColors.textSecondary : reading.band.color)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: reading.band)
                .accessibilityIdentifier("findRing.band")
            trendRow
                .frame(height: 22)
            Text(reading.rawDbm.map { "\($0) dBm" } ?? "No signal")
                .font(AgaraFont.caption.monospacedDigit())
                .foregroundStyle(AgaraColors.textMuted)
                .accessibilityIdentifier("findRing.rssi")
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var trendRow: some View {
        switch reading.trend {
        case .closer:
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").accessibilityHidden(true)
                Text(AgaraCopy.findRingTrendCloser).accessibilityIdentifier("findRing.trend")
            }
            .font(AgaraFont.subheadline)
            .foregroundStyle(AgaraColors.success)
        case .further:
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").accessibilityHidden(true)
                Text(AgaraCopy.findRingTrendFurther).accessibilityIdentifier("findRing.trend")
            }
            .font(AgaraFont.subheadline)
            .foregroundStyle(AgaraColors.zoneOrange)
        case .steady:
            Color.clear
        }
    }

    @ViewBuilder private var vibrateControl: some View {
        if connected && canVibrate {
            if coordinator.isFindingRing {
                SecondaryButton(title: AgaraCopy.findRingStop, systemImage: "stop.fill") { coordinator.stopFindingRing() }
                    .accessibilityIdentifier("findRing.stop")
            } else {
                PrimaryButton(title: AgaraCopy.findRingVibrate, systemImage: "bell.and.waves.left.and.right") {
                    coordinator.findRing()
                }
                .accessibilityIdentifier("findRing.vibrate")
            }
        } else {
            // Keeps the layout steady while the link is down (vibrating needs a connection).
            Color.clear.frame(height: 56)
        }
    }
}

/// The ring art inside four concentric circles: one more lights up per band (Far = 1 … Right here = 4), all in the
/// band's colour, with a pulse expanding from the ring whose period shortens as you get closer.
struct ProximityCircles: View {
    let band: RingProximity.Band
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let circleScales: [CGFloat] = [0.46, 0.64, 0.82, 1.0]   // innermost first

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(Array(Self.circleScales.enumerated()), id: \.offset) { index, scale in
                    let lit = index < band.filledCircles
                    Circle()
                        .fill(lit ? band.color.opacity(0.08 + 0.05 * Double(Self.circleScales.count - index)) : .clear)
                        .overlay(Circle().strokeBorder(lit ? band.color.opacity(0.9) : AgaraColors.borderSubtle,
                                                       lineWidth: lit ? 2 : 1))
                        .frame(width: side * scale, height: side * scale)
                }
                if !reduceMotion { pulse(side: side) }
                RingArtView(tint: band.color, size: side * 0.34)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.35), value: band)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(band.label)
    }

    private func pulse(side: CGFloat) -> some View {
        TimelineView(.animation) { context in
            let period = band.pulsePeriod
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: period) / period)
            let scale = 0.36 + (1.0 - 0.36) * phase
            Circle()
                .stroke(band.color.opacity(Double(1 - phase) * 0.8), lineWidth: 3)
                .frame(width: side * scale, height: side * scale)
        }
        .allowsHitTesting(false)
    }
}
