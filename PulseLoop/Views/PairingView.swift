import SwiftUI
import CoreBluetooth
import SwiftData
import UIKit

/// The dedicated, modern ring-pairing screen. Swipe a carousel of supported ring models (product art,
/// name, capability chips, and a "Limited support" badge for experimental families), pick yours, then
/// scan and connect to a matching nearby device. Reused in two contexts: the onboarding pair step
/// (with a "Skip for now") and pushed from Settings → "Add a ring".
///
/// All scan/discover/connect UI lives here so Settings stays a clean device card. Pairing logic is
/// just orchestration over `RingBLEClient`; the chosen model's `family` biases which discovered
/// device we surface/auto-connect, while `RingBLEClient.coordinators` still does the real matching.
struct PairingView: View {
    @Environment(RingBLEClient.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext

    /// Pushed onto the Settings nav stack (no onboarding "Skip"): show our own glass
    /// back button and hide the system nav bar so it doesn't stack a second, empty
    /// header above the big "Add your ring" title.
    private var isPushed: Bool { onSkip == nil }

    private var forcePairingUIForTesting: Bool {
        #if DEBUG
        #if targetEnvironment(simulator)
        DebugLaunch.bool("forcePairingUI")
        #else
        false
        #endif
        #else
        false
        #endif
    }

    /// Called once a ring is connected (onboarding finishes; Settings pops the route).
    var onConnected: (() -> Void)?
    /// When set, shows a "Skip for now" action (onboarding only).
    var onSkip: (() -> Void)?

    init(onConnected: (() -> Void)? = nil, onSkip: (() -> Void)? = nil) {
        self.onConnected = onConnected
        self.onSkip = onSkip
    }

    @State private var selectedIndex = 0
    @State private var selectedBrand = Self.allBrandsTab
    @State private var isLooking = false
    @State private var didFireConnected = false
    /// The "Name your ring" step: shown once a ring connects, until the user saves a name or skips.
    /// Kept separate from `ble.state` so a link blip mid-typing doesn't throw the step away.
    @State private var isNaming = false
    @State private var nameText = RingNickname.defaultName
    /// The ring the user last tapped, kept so a failed attempt can be described by name.
    @State private var lastAttemptedRingID: UUID?

    private static let allBrandsTab = "All"
    private let allModels = WearableModel.setupCatalog
    /// Prepared when scanning starts so the success haptic fires promptly on connect. `@State` keeps
    /// one instance across re-renders so `prepare()` and the later `notificationOccurred` share it.
    @State private var successHaptic = UINotificationFeedbackGenerator()

    /// Brand tabs: "All" first, then each distinct brand alphabetically.
    private var brands: [String] {
        [Self.allBrandsTab] + Set(allModels.map(\.brand))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Models for the selected brand tab, sorted alphabetically by name.
    private var models: [WearableModel] {
        let scoped = selectedBrand == Self.allBrandsTab
            ? allModels
            : allModels.filter { $0.brand == selectedBrand }
        return scoped.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedModel: WearableModel {
        guard !models.isEmpty else { return .tk20 }
        return models[min(selectedIndex, models.count - 1)]
    }

    /// Connect to a tapped row.
    private func connect(to ring: RingBLEClient.DiscoveredRing) {
        lastAttemptedRingID = ring.id
        ble.connect(to: ring.id, selectedModelID: selectedModel.id)
    }

    /// Discovered rings whose matched family is one the selected model can resolve to (recognized
    /// first), falling back to all named devices if nothing matches yet so the user is never stuck.
    /// Matching on *every* family the card can be — not just its default — is what keeps a row the scan
    /// tagged `.the ringSmartHealth` visible under the ring card.
    private var matchingRings: [RingBLEClient.DiscoveredRing] {
        let matches = ble.discovered.filter { selectedModel.acceptsScanFamily($0.deviceType) }
        return matches.isEmpty ? ble.discovered : matches
    }

    /// Bluetooth is known to be unusable (off / not allowed / unsupported). Before the first scan the manager
    /// doesn't exist yet — the system permission prompt comes from the "Connect my ring" tap, not from
    /// opening this screen — so "not started" and "waiting for the first state" are not blocked.
    private var bluetoothBlocked: Bool {
        ble.isBluetoothStarted && !ble.isBluetoothReady && ble.bluetoothAvailability != .unknown
    }
    private var canUseBluetoothUI: Bool { !bluetoothBlocked || forcePairingUIForTesting }
    private var showsActionFooter: Bool {
        if isNaming { return true }
        guard ble.state != .connected else { return false }
        return isLooking ? onSkip != nil : (canUseBluetoothUI || onSkip != nil)
    }

    var body: some View {
        content
            .background(AgaraColors.background.ignoresSafeArea())
            .onChange(of: ble.state) { _, state in
                if state == .connected, !didFireConnected {
                    didFireConnected = true
                    isLooking = false
                    successHaptic.notificationOccurred(.success) // §6 success haptic
                    // "Name your ring" comes next; `onConnected` fires once it is saved or skipped.
                    nameText = RingNickname.prefill(
                        identifier: ble.deviceIdentifier, row: DeviceRepository.current(context: modelContext)
                    )
                    isNaming = true
                }
            }
            .onDisappear { isLooking = false; ble.stopScanning() } // reset so a re-appear doesn't show a frozen scan
    }

    /// Wraps the scroll content with a glass back button + hidden nav bar when pushed
    /// from Settings; onboarding (no nav stack) uses the bare scroll content.
    @ViewBuilder
    private var content: some View {
        if isPushed {
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(AgaraFont.bodyEmphasis)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .frame(width: 36, height: 36)
                            .agaraGlass(Circle(), interactive: true)
                            .minTapTarget(visualSize: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)
                scrollContent
            }
            .toolbar(.hidden, for: .navigationBar)
            .enablesBackSwipe()
        } else {
            scrollContent
        }
    }

    /// The bare default state (Bluetooth ready, not connected, not scanning) fits centered without
    /// scrolling on every iPhone — but only at standard Dynamic Type sizes. Scanning lists, the
    /// connected/bluetooth-off states, and accessibility sizes keep the scrolling layout so they
    /// never clip. `errorText` is nil-friendly and pulled out so both layouts share it.
    private var isFittedDefaultState: Bool {
        canUseBluetoothUI
            && !isNaming
            && ble.state != .connected
            && !isLooking
            && !dynamicTypeSize.isAccessibilitySize
    }

    private var scrollContent: some View {
        Group {
            if isFittedDefaultState {
                fittedDefault
            } else {
                scrollingContent
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsActionFooter {
                OnboardingActionFooter { pairingFooterContent }
            }
        }
    }

    // Fitted, no-scroll default: header + carousel sized to the viewport via the shared band.
    private var fittedDefault: some View {
        OnboardingFittedBand { s in
            VStack(spacing: 0) {
                FittedOnboardingHeader(
                    title: "Add your ring",
                    subtitle: "Swipe to find your model, then tap to connect.",
                    s: s
                )
                .frame(maxWidth: .infinity)

                Spacer().frame(height: (14 * s).rounded())

                carousel(s: s)

                if hasError {
                    Spacer().frame(height: 12)
                    errorText
                }
            }
        }
    }

    private var scrollingContent: some View {
        ScrollView {
            // Tight vertical rhythm so the whole picker — carousel *and* its scrub bar — clears the
            // pinned footer without scrolling. When it didn't, the scrub bar sat behind the footer,
            // whose glass sampled the accent thumb as a purple smear under "Connect ring".
            VStack(spacing: 16) {
                OnboardingHeader(
                    title: isNaming ? "Name your ring" : "Add your ring",
                    subtitle: isNaming
                        ? "Pick a name you'll recognise. You can change it later in Settings."
                        : "Swipe to find your model, then tap to connect."
                )
                .frame(maxWidth: .infinity) // full-width anchor: forces the column full so the button
                                            // never hugs to the (variable-width) dot row

                if isNaming || ble.state == .connected {
                    connectedCard
                } else if bluetoothBlocked && !forcePairingUIForTesting {
                    bluetoothOffCard
                } else {
                    carousel(s: 1)
                    if isLooking { scanningArea }
                }

                if hasError {
                    errorText
                }

            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .containerRelativeFrame(.horizontal) // size the column to the screen exactly (not to its
                                                 // content), so the button is full-width on every tab
        }
        .scrollBounceBehavior(.basedOnSize) // static when it fits; scrolls only if content overflows
                                            // (small devices / scanning list) so nothing clips
    }

    private var hasError: Bool {
        ble.lastError != nil && ble.state != .connected && !forcePairingUIForTesting
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = ble.lastError {
            VStack(spacing: 10) {
                Text(error)
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Carousel

    private func carousel(s: CGFloat) -> some View {
        let ringSize = (168 * s).rounded()
        return VStack(spacing: (6 * s).rounded()) {
            brandTabs

            TabView(selection: $selectedIndex) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    VStack(spacing: (10 * s).rounded()) {
                        AnimatedRingArt(
                            tint: model.tint, size: ringSize, imageName: model.imageName,
                            phase: isLooking ? .searching : .idle
                        )
                        Text(model.displayName)
                            .font(AgaraFont.numberL)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        CapabilityChips(blurb: model.blurb)
                    }
                    .frame(maxWidth: .infinity) // constant page width so content doesn't drive reflow
                    .tag(index)
                    .accessibilityElement(children: .combine) // §2
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // §2 Fix #2 — dots moved to modelDotRow
            // Derive from the scaled ring art plus a fixed band for the tallest page (name + chips).
            // Slack shows up as dead space above the scrub bar, so keep the band tight.
            .frame(height: (ringSize + 112).rounded())
            .id(selectedBrand) // recreate on brand change so pages swap instantly (no page-slide)

            modelDotRow // §2 fixed-height dot area keeps layout stable across tabs
        }
        .onChange(of: selectedIndex) { _, _ in
            // Re-scan/filter as the user changes their selected model.
            if isLooking { ble.startScanning() }
        }
    }

    /// Page position shown as a liquid-glass scroll bar: a faint glass track with an
    /// accent glass thumb that slides to the selected model and can be dragged to scrub.
    /// Scales to any catalog size — never clips or overflows like a per-model dot row.
    private var modelDotRow: some View {
        Group {
            if models.count > 1 {
                GlassScrollIndicator(count: models.count, index: $selectedIndex) {
                    if isLooking { ble.startScanning() } // re-filter scan as selection scrubs
                }
                .frame(maxWidth: 220)
                .accessibilityLabel("Model \(selectedIndex + 1) of \(models.count): \(selectedModel.displayName)")
            }
        }
        .frame(maxWidth: .infinity) // center the bar; keep it from driving column width
        .frame(height: 20)          // constant area across every brand tab; the bar centres inside it
    }

    /// Brand filter: centered when the pills fit on screen, horizontally scrollable when they don't.
    private var brandTabs: some View {
        ViewThatFits(in: .horizontal) {
            brandPillRow
            ScrollView(.horizontal, showsIndicators: false) { brandPillRow }
        }
        .frame(maxWidth: .infinity) // full width so the centered pill row stays centered and stable
        .sensoryFeedback(.selection, trigger: selectedBrand)
    }

    private var brandPillRow: some View {
        HStack(spacing: 8) {
            ForEach(brands, id: \.self) { brand in
                let isSelected = brand == selectedBrand
                Button {
                    // Switch brand without animating: prevents the TabView page-slide / reflow that
                    // read as the whole screen shifting right and back.
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        selectedBrand = brand
                        selectedIndex = 0
                    }
                    if isLooking { ble.startScanning() }
                } label: {
                    Text(brand)
                        .font(AgaraFont.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? AgaraColors.onAccent : AgaraColors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        // Selected = accent-tinted interactive glass; others = plain glass.
                        .agaraGlass(Capsule(), interactive: true, tint: isSelected ? AgaraColors.accent : nil)
                        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: selectedBrand)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, 2)
        .agaraGlassContainer(spacing: 8) // morph pills as the selection moves
    }

    // MARK: - Action area (scan + discovered rings)

    @ViewBuilder
    private var pairingFooterContent: some View {
        if isNaming {
            namingFooterContent
        } else {
            scanFooterContent
        }
    }

    /// Save / Skip for the "Name your ring" step. Skip keeps the default (writes nothing).
    private var namingFooterContent: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: "Save name", systemImage: "checkmark", action: saveName)
            Button("Skip", action: finishNaming)
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textMuted)
                .frame(height: 44)
        }
    }

    private func saveName() {
        guard RingNickname.isValid(nameText) else { return }
        DeviceRepository.setNickname(nameText, peripheralIdentifier: ble.deviceIdentifier, context: modelContext)
        finishNaming()
    }

    private func finishNaming() {
        guard isNaming else { return }
        isNaming = false
        onConnected?()
    }

    @ViewBuilder
    private var scanFooterContent: some View {
        VStack(spacing: 10) {
            if !isLooking, canUseBluetoothUI {
                PrimaryButton(title: "Connect my ring", systemImage: "dot.radiowaves.left.and.right") {
                    isLooking = true
                    successHaptic.prepare()
                    ble.startScanning()
                }
                if ble.hasLastKnownRing && ble.state != .reconnecting {
                    SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") {
                        ble.connectLastKnown()
                    }
                }
            }

            if let onSkip {
                Button("Skip for now", action: onSkip)
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textMuted)
                    .frame(height: 44)
            }
        }
    }

    private var scanningArea: some View {
        VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if ble.state == .connecting || ble.state == .reconnecting {
                        ProgressView()
                            .accessibilityLabel("Searching") // §4
                        Text("Connecting to \(selectedModel.displayName)…") // §4
                    } else {
                        ProgressView()
                            .accessibilityLabel("Searching") // §4
                        Text("Scanning for \(selectedModel.displayName)…") // §4
                    }
                }
                .font(AgaraFont.caption)
                .foregroundStyle(AgaraColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .center) // §4 centered

                VStack(spacing: 8) {
                    ForEach(matchingRings) { ring in
                        Button {
                            connect(to: ring)
                        } label: {
                            ringRow(ring)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .agaraGlassContainer(spacing: 8) // discovered glass rows blend/morph together

                if matchingRings.isEmpty {
                    InlineEmptyState(
                        title: "No rings found yet",
                        message: "Wake the ring by tapping or moving it, and keep it close."
                    )
                    .padding(.top, 8) // §4
                }

                SecondaryButton(title: "Stop scanning", systemImage: "stop.circle") { // §4
                    isLooking = false
                    ble.stopScanning()
                }
        }
        .padding(16) // §4 card wrapper
        .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The wrong-pick escape hatch. A user-initiated connect that dies in `.failed` on a two-app card is,
    /// far more often than not, the other app's driver — the ring never answered because we were speaking
    private func ringRow(_ ring: RingBLEClient.DiscoveredRing) -> some View {
        let signalLevel: String = ring.rssi >= -65 ? "Strong signal"
            : ring.rssi >= -80 ? "Medium signal"
            : "Weak signal"
        // A matched ring is shown by the app's product name, never the Bluetooth hardware name the ring advertises
        // ("TK20"): pairing is the first place a person meets the ring, and the hardware model is not our name for it
        // (AGENTS Rule 3). Unmatched peripherals keep their advertised name so the user can still find them.
        let shownName = ring.deviceType.map { _ in AgaraCopy.ringDisplayName } ?? ring.name
        return HStack {
            Image(systemName: ring.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                .foregroundStyle(ring.isLikelyRing ? AgaraColors.accent : AgaraColors.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(shownName).font(AgaraFont.subheadline.weight(.medium)).foregroundStyle(AgaraColors.textPrimary)
            }
            Spacer()
            SignalStrengthDots(rssi: ring.rssi) // §5
                .accessibilityHidden(true) // §5 row provides spoken signal level
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        // Interactive glass row (it's a tappable connect button).
        .agaraGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        .overlay(alignment: .leading) { // §5 accent left-stripe for likely rings
            if ring.isLikelyRing {
                Rectangle()
                    .fill(AgaraColors.accent)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) // §5 clips stripe
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine) // §5
        .accessibilityLabel(Text( // §5 spoken label with signal level
            "\(shownName), \(signalLevel)"
        ))
    }

    // MARK: - States

    /// Pairing succeeded: the ring settles with a success flash, the confirmation names it, and the
    /// "Name your ring" editor sits underneath (Save / Skip live in the footer).
    private var connectedCard: some View {
        VStack(spacing: 16) {
            AnimatedRingArt(tint: selectedModel.tint, size: 140, imageName: selectedModel.imageName, phase: .paired)
                .padding(.vertical, 6)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AgaraColors.success)
                    .scaleEffect(didFireConnected ? 1.0 : 0.3) // §6 checkmark spring
                    .animation(.spring(response: 0.45, dampingFraction: 0.55), value: didFireConnected) // §6
                Text("Connected to \(connectedRingName)")
                    .font(AgaraFont.headline)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            if isNaming {
                RingNameEditor(text: $nameText, onSubmit: saveName)
            } else if let onSkip {
                // Already connected on arrival (e.g. back-navigating in onboarding): nothing to name.
                PrimaryButton(title: "Continue", systemImage: "checkmark", action: onSkip)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// The ring's current name for the "Connected to …" line: its stored nickname, else the model name.
    private var connectedRingName: String {
        let modelName = ble.activeWearableModel?.displayName
            ?? ble.activeDeviceType?.displayName
            ?? selectedModel.displayName
        return RingNickname.displayName(
            nickname: DeviceRepository.current(context: modelContext)?.nickname,
            modelName: modelName
        )
    }

    private var bluetoothOffCard: some View {
        // "Off" and "not allowed" need different fixes (Android's pairing card makes the same split).
        let copy = BluetoothUnavailableCopy(ble.bluetoothAvailability)
        return VStack(spacing: 14) { // §6 spacing bumped to 14
            Image(systemName: copy.symbol)
                .font(AgaraFont.largeTitle.weight(.regular))
                .foregroundStyle(AgaraColors.textMuted)
            Text(copy.title)
                .font(AgaraFont.headline)
                .foregroundStyle(AgaraColors.textPrimary)
            Text(copy.body)
                .font(AgaraFont.subheadline)
                .foregroundStyle(AgaraColors.textMuted)
                .multilineTextAlignment(.center)
            if let action = copy.settingsButton, let url = URL(string: UIApplication.openSettingsURLString) {
                SecondaryButton(title: action, systemImage: "gear") { // §6
                    UIApplication.shared.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Why CoreBluetooth can't be used right now, from `CBCentralManager.state`.
enum BluetoothAvailability: Equatable {
    case ready, off, notAllowed, unsupported, unknown

    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .ready
        case .poweredOff: self = .off
        case .unauthorized: self = .notAllowed
        case .unsupported: self = .unsupported
        default: self = .unknown
        }
    }
}

/// Pairing-card copy for an unusable Bluetooth. Titles/bodies match Android's pairing card. iOS can't
/// deep-link to the Bluetooth switch, so "off" points at Control Center instead of offering a button that
/// would only open this app's settings page; "not allowed" opens that page, where the permission lives.
struct BluetoothUnavailableCopy: Equatable {
    let title: String
    let body: String
    let symbol: String
    /// Label of the "open this app's Settings" button, or nil when Settings can't fix it.
    let settingsButton: String?

    init(_ availability: BluetoothAvailability) {
        switch availability {
        case .notAllowed:
            title = "Bluetooth isn't allowed"
            body = "Allow Bluetooth permission for this app in its settings to find and connect your ring."
            symbol = "lock.shield"
            settingsButton = "Open app settings"
        case .unsupported:
            title = "Bluetooth isn't available"
            body = "This device doesn't support Bluetooth Low Energy, which the ring needs."
            symbol = "antenna.radiowaves.left.and.right.slash"
            settingsButton = nil
        case .off, .unknown, .ready:
            title = "Bluetooth is off"
            body = "Turn on Bluetooth in Control Center or Settings to find and connect your ring."
            symbol = "antenna.radiowaves.left.and.right.slash"
            settingsButton = nil
        }
    }
}
