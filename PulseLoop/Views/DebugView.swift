import SwiftUI
import SwiftData

struct DebugView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var filter = "all"
    @State private var refreshToken = UUID()
    @State private var showsFeatureFlags = false
    @State private var tipsReset = false

    var body: some View {
        let packets = DebugRepository.queryPackets(filter: packetFilter, context: modelContext)
        VStack(spacing: 12) {
            #if DEBUG
            SecondaryButton(title: "Feature flags", systemImage: "flag") { showsFeatureFlags = true }
                .padding(.horizontal)
                .sheet(isPresented: $showsFeatureFlags) { FeatureFlagsView() }
            #endif
            tipsRow
                .padding(.horizontal)
            Picker("Filter", selection: $filter) {
                Text("All").tag("all")
                Text("In").tag(PacketDirection.incoming.rawValue)
                Text("Out").tag(PacketDirection.outgoing.rawValue)
                Text("Unknown").tag("unknown")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            List(packets) { packet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(packet.timestamp, style: .time)
                        Text(packet.directionRaw)
                        Text(String(format: "0x%02x", packet.commandId))
                        Spacer()
                        Text(packet.confidence.debugLabel)
                            .foregroundStyle(packet.confidence == .unknown ? PulseColors.warning : PulseColors.success)
                    }
                    .font(PulseFont.caption.monospacedDigit())
                    Text(packet.hexPayload)
                        .font(PulseFont.caption2.monospacedDigit())
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(2)
                    Text(packet.decodedKind ?? "unknown")
                        .font(PulseFont.caption)
                        .foregroundStyle(PulseColors.textSecondary)
                }
                .listRowBackground(PulseColors.card)
            }
            .scrollContentBackground(.hidden)

            HStack {
                SecondaryButton(title: "Log mock packet", systemImage: "plus") {
                    // A frame the app really writes: the D8 realtime-readout poll. The old mock built a
                    // status command with the removed the ring encoder, which logged a packet no driver here
                    // can produce.
                    let data = VeepooEncoder.steps()
                    DebugRepository.insertRawPacket(
                        direction: .outgoing,
                        commandId: Int(data.first ?? 0),
                        hexPayload: data.hexString,
                        decodedKind: "steps_poll",
                        decodedJSON: nil,
                        confidence: .known,
                        context: modelContext
                    )
                    try? modelContext.save()
                    refreshToken = UUID()
                }
            }
            .padding(.horizontal)
        }
        .id(refreshToken)
        .background(PulseColors.background)
        .pageChrome("Debug")
    }

    /// Settings › Developer › Tips: "Show tips again" clears the seen one-time hints
    /// (`CoachMarkStore.resetAll`), so the Measure and ring-chip coach marks appear again, in
    /// `CoachMarkStore.order`. Same row as Android's `TipsCard`.
    private var tipsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show tips again")
                    .font(PulseFont.body)
                    .foregroundStyle(PulseColors.textPrimary)
                Text(tipsReset
                     ? "Tips will show again."
                     : "The one-time hints (Measure, then the ring chip) appear again the next time their screen is shown.")
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Reset") {
                CoachMarkStore.shared.resetAll()
                tipsReset = true
            }
            .font(PulseFont.body.weight(.semibold))
            .foregroundStyle(PulseColors.accent)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("Show tips again")
        }
        .padding(12)
        .background(PulseColors.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var packetFilter: DebugPacketFilter {
        switch filter {
        case PacketDirection.incoming.rawValue:
            return DebugPacketFilter(direction: .incoming)
        case PacketDirection.outgoing.rawValue:
            return DebugPacketFilter(direction: .outgoing)
        case "unknown":
            return DebugPacketFilter(confidence: .unknown)
        default:
            return DebugPacketFilter()
        }
    }
}

struct ComponentGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroInsightCardView(
                    title: "Steady build",
                    summary: "You're at 9,342 steps, 7h 35m of sleep, and your latest reading is 72 bpm.",
                    chips: [ToneChip(label: "Steps +12%", tone: .up), ToneChip(label: "HR collected", tone: .neutral), ToneChip(label: "Sleep synced", tone: .neutral)]
                )
                MetricCardButton(metric: "hr", label: "Heart rate", value: "72", unit: "bpm", color: PulseColors.heartRate, sparkline: [62, 68, 72, 70, 76])
                StatusCopy(title: "Empty state", body: "Reusable loading, empty, and error states use the same card hierarchy.")
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Components")
    }
}
