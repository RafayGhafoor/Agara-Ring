import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// The coach conversation itself: the thread, the composer, the empty thread's data-based starter prompts and the
/// header's actions. `CoachTabView` hands it over when the tab's state is `.ready`; every other state is a card.
struct CoachView: View {
    /// Called when a workout card in the chat is tapped. Coach stays routing-agnostic so the tab's presenter decides
    /// how to get to the activity detail.
    var onOpenWorkout: ((UUID) -> Void)?
    /// Called when a meal card in the chat is tapped — same presenter-decides
    /// routing contract as `onOpenWorkout`.
    var onOpenMeal: ((UUID) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query(sort: \CoachConversation.updatedAt, order: .reverse) private var conversations: [CoachConversation]
    @State private var draft = ""
    @State private var viewModel = CoachViewModel()
    @State private var activeConversationId: UUID?
    @State private var showHistory = false
    @State private var showUsage = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var nav = CoachNavigation.shared
    @State private var settingsStore = CoachSettingsStore.shared
    /// The answer as the cloud coach writes it (server-sent events, 2026-10-23).
    @State private var stream = CoachStreamStore.shared
    /// Coalesced "rows changed" signal, so the empty thread's prompts follow the last sync.
    @State private var dataChange = AgaraDataChange.shared
    @FocusState private var composerFocused: Bool

    /// The empty thread's opening chips, built from the data the ring actually delivered (`CoachStarterBuilder`: three
    /// starters that quote the user's own numbers, degrading to generic questions when the store is empty). They are also
    /// the top-up pool for an answer that carries fewer than three follow-ups (`CoachFollowUpChips`).
    @State private var starterPrompts: [String] = []

    // Image attachment (multimodal input). One staged image per message.
    @State private var stagedImage: UIImage?
    @State private var stagedAttachment: CoachAttachmentRef?
    @State private var showPhotosPicker = false
    @State private var showCamera = false
    @State private var photosPickerItem: PhotosPickerItem?

    /// Image attach is offered only when enabled *and* the provider supports it.
    /// The on-device model has no image-input API in the shipping SDK, so the
    /// composer hides the attach button there even if the stored flag is on (e.g.
    /// left over from another provider).
    private var imageInputEnabled: Bool {
        settingsStore.settings.enableImageInput
            && settingsStore.settings.providerMode != .appleOnDevice
    }

    /// Bottom inset for the composer. Coach is presented as a sheet now (no overlaid
    /// nav bar), so the idle gap is small; when the keyboard is up the composer rises
    /// just above it. Computed manually because we pin the keyboard safe area below.
    private var composerBottomInset: CGFloat {
        guard keyboardHeight > 0 else { return 0 }
        return max(8, keyboardHeight - bottomSafeInset + 8)
    }

    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
    }

    /// The opening questions belong to a thread the user has not spoken in yet. (It used to be "the last message is the
    /// assistant's", which is true after every answer — so the starters came back at the top of each conversation.)
    /// And only when the coach's last message is not already offering questions: a structured briefing carries three
    /// follow-ups (topped up from these same starters), and the thread then showed the same three questions twice.
    private func showColdStart(_ messages: [CoachMessage]) -> Bool {
        // A nudge's seeded answer brings its own three questions; the starters under it made six.
        guard !viewModel.isSending, nav.requestedSeed == nil,
              !messages.contains(where: { $0.role == "user" }) else { return false }
        if let last = messages.last, last.role == "assistant", CoachResponse.decode(fromJSON: last.cardsJSON) != nil {
            return false
        }
        return true
    }

    /// Only the active conversation's messages are queried (it used to query every message of every
    /// conversation and filter in the body, on each keystroke and trace event — audit batch B).
    var body: some View {
        CoachMessagesReader(conversationId: activeConversationId) { messages in
            content(messages)
        }

    }

    @ViewBuilder
    private func content(_ messages: [CoachMessage]) -> some View {
        VStack(spacing: 0) {

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // A nudge's seeded answer (tap on a nudge or "Why?"): already written, with its numbers, its
                        // chart and three questions. No model call until the user sends one.
                        if let seed = nav.requestedSeed {
                            CoachSeedCard(
                                seed: seed,
                                onAsk: { question in
                                    nav.requestedSeed = nil
                                    send(question)
                                },
                                onDismiss: { nav.requestedSeed = nil }
                            )
                        }
                        ForEach(messages) { message in
                            CoachBubble(
                                message: message,
                                fallbackChips: starterPrompts,
                                onChipTap: { send($0) },
                                onConfirm: { viewModel.confirmPendingAction(message, context: modelContext) },
                                onCancel: { viewModel.cancelPendingAction(message, context: modelContext) },
                                onOpenWorkout: { openWorkout($0) },
                                onOpenMeal: { openMeal($0) }
                            ).id(message.id)
                        }
                        // The opening questions follow whatever the coach has already said (the daily briefing), and
                        // stand alone on an empty thread. Once the user has asked something, each answer's own three
                        // follow-ups take over — these used to come back at the TOP of every finished conversation.
                        if showColdStart(messages) && !starterPrompts.isEmpty {
                            CoachSuggestionList(questions: starterPrompts, identifier: "coach.starter") { send($0) }
                        }
                        if viewModel.isSending {
                            if stream.hasPreview {
                                // The cloud coach is writing: its title and summary as they arrive. The finished,
                                // validated answer replaces this when the turn ends.
                                CoachStreamingPreview(title: stream.title, summary: stream.summary).id("trace")
                            } else {
                                CoachTraceStrip(events: viewModel.traceEvents).id("trace")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .onChange(of: messages.count) {
                    guard let last = messages.last else { return }
                    // An ANSWER is read from its first line, so it lands at the TOP of the viewport. Anchoring to the
                    // bottom (the chat default) put a long answer's beginning off-screen and left only its tail visible,
                    // which read as the header cutting the answer in half. The user's own message still tracks the
                    // bottom, which is what a chat expects.
                    // Refined: the answer's QUESTION goes to the top, with the answer starting right under it — the
                    // pair reads as one exchange, and the answer still starts at its first line.
                    let target: UUID
                    if last.role == "assistant",
                       let question = messages.dropLast().last(where: { $0.role == "user" }) {
                        target = question.id
                    } else {
                        target = last.id
                    }
                    withAnimation {
                        proxy.scrollTo(target, anchor: last.role == "assistant" ? .top : .bottom)
                    }
                }
                .onChange(of: viewModel.traceEvents.count) {
                    withAnimation { proxy.scrollTo("trace", anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                // Soft edges top and bottom: the thread fades under the app header and under the composer instead of
                // meeting them at a hard line.
                .agaraScrollEdges(.vertical)
            }

            composer
                // Clears the nav bar when idle; rises above the keyboard when typing.
                .padding(.bottom, composerBottomInset)
                // The page's own colour: a tinted band made the composer read as a separate strip under the chat.
                .background(AgaraColors.background)
        }
        .background(AgaraColors.background)
        // The coach's actions are in the app header now (`CoachHeaderActions`, `CoachHeaderTitle`); they post requests
        // and this view, which owns the thread, answers them.
        .onChange(of: nav.newChatRequests) { _, _ in newConversation() }
        .onChange(of: nav.historyRequests) { _, _ in composerFocused = false; showHistory = true }
        .onChange(of: nav.usageRequests) { _, _ in composerFocused = false; showUsage = true }
        // Pin the keyboard safe area so only our manual lift moves the composer —
        // otherwise the sheet's native avoidance double-lifts it.
        .ignoresSafeArea(.keyboard)
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            // Visible keyboard height = how far its top is above the screen bottom.
            keyboardHeight = max(0, screenHeight - frame.origin.y)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onAppear {
            if activeConversationId == nil {
                activeConversationId = latestMessageConversationId() ?? conversations.first?.id
            }
            if nav.requestedConversationId != nil { openRequestedConversation() }
            refreshStarterPrompts()
            #if DEBUG
            // `-coachDemoChart YES`: seed one real assistant answer carrying a chart, so the chart's rendering (the
            // shared `AgaraChart` through `CoachChartView`) can be screenshotted without a cloud turn. It writes the same
            // `coach_response` JSON a real answer carries, so it exercises the production path end to end.
            if DebugLaunch.bool("coachDemoChart") { seedDemoChartAnswer() }
            #endif
        }
        // New ring data changes what the empty thread should suggest ("I'm at 4,210 steps…").
        .onChange(of: dataChange.token) { _, _ in refreshStarterPrompts() }
        .onChange(of: nav.requestedConversationId) { _, id in
            if id != nil { openRequestedConversation() }
        }
        .sheet(isPresented: $showHistory) {
            CoachHistorySheet(conversations: conversations, activeId: activeConversationId) { id in
                activeConversationId = id
            }
            .agaraRingEnvironment()
        }
        .sheet(isPresented: $showUsage) {
            CoachUsageSheet(
                conversation: activeConversation,
                messages: messages,
                settings: settingsStore.settings,
                usesCloud: CoachClientResolver.effectiveMode(for: settingsStore.settings.providerMode,
                                                             cloudReady: CoachGate.cloudReady) == .agaraCloud
            )
            .agaraRingEnvironment()
        }
    }

    /// The conversation of the newest message (one-row fetch).
    private func latestMessageConversationId() -> UUID? {
        var descriptor = FetchDescriptor<CoachMessage>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.conversationId
    }

    private func hasMessages(in conversationId: UUID) -> Bool {
        var descriptor = FetchDescriptor<CoachMessage>(predicate: #Predicate { $0.conversationId == conversationId })
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// The currently selected conversation object (for usage totals).
    private var activeConversation: CoachConversation? {
        guard let id = activeConversationId else { return conversations.first }
        return conversations.first { $0.id == id }
    }

    /// Open the activity detail for a workout logged in chat, dismissing the
    /// composer/keyboard first so the transition reads cleanly.
    private func openWorkout(_ id: UUID) {
        composerFocused = false
        onOpenWorkout?(id)
    }

    /// Open the meal detail for a meal logged in chat, mirroring `openWorkout`.
    private func openMeal(_ id: UUID) {
        composerFocused = false
        onOpenMeal?(id)
    }

    /// Rebuild the empty thread's chips from the current data (cheap: one context packet, no model call).
    private func refreshStarterPrompts() {
        starterPrompts = CoachStarterBuilder.build(context: modelContext).map(\.text)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let stagedImage { stagedThumbnail(stagedImage) }

            HStack(spacing: 8) {
                // Camera button — only shown when image input is enabled in
                // Settings. Nothing is shown when off. Opens the camera directly;
                // falls back to the photo library where no camera exists (simulator).
                if imageInputEnabled {
                    Button {
                        composerFocused = false
                        if CameraSupport.isAvailable { showCamera = true }
                        else { showPhotosPicker = true }
                    } label: {
                        Image(systemName: "camera")
                            .font(AgaraFont.headline.weight(.regular)).foregroundStyle(AgaraColors.textSecondary)
                            .frame(width: 36, height: 36).agaraGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a photo")
                }
                TextField("Ask the coach...", text: $draft)
                    .focused($composerFocused)
                    .textFieldStyle(.plain)
                    .font(AgaraFont.subheadline.weight(.regular))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .agaraGlass(Capsule())
                    .onSubmit { send(draft) }
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up")
                        .font(AgaraFont.bodyEmphasis)
                        .foregroundStyle(canSend ? AgaraColors.onAccent : AgaraColors.textMuted)
                        .frame(width: 36, height: 36)
                        .agaraGlass(Circle(), interactive: true, tint: canSend ? AgaraColors.accent : nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("coach.send")
                .disabled(!canSend)
            }
            // Camera / field / send glass share one container so they render/blend together.
            .agaraGlassContainer(spacing: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, item in
            guard let item else { return }
            Task { await loadPickedPhoto(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in stage(image) }
                .ignoresSafeArea()
                .agaraRingEnvironment()
        }
    }

    /// Small preview chip for the staged image, with a remove button.
    private func stagedThumbnail(_ image: UIImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AgaraColors.borderSubtle, lineWidth: 1))
                Button { clearStagedImage() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AgaraFont.title3.weight(.regular))
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                        .minTapTarget(visualSize: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo")
                .offset(x: 6, y: -6)
            }
            Spacer(minLength: 0)
        }
    }

    private var canSend: Bool {
        guard !viewModel.isSending else { return false }
        return !draft.trimmingCharacters(in: .whitespaces).isEmpty || stagedAttachment != nil
    }

    #if DEBUG
    /// Write one assistant message whose `coach_response` carries a chart. DEBUG only; used by screenshot runs
    /// (`-coachDemoChart YES`), never in a release build.
    private func seedDemoChartAnswer() {
        let context = modelContext
        let conversationId = activeConversationId ?? {
            let convo = CoachConversation()
            context.insert(convo)
            activeConversationId = convo.id
            return convo.id
        }()
        let existing = (try? context.fetch(FetchDescriptor<CoachMessage>(
            predicate: #Predicate { $0.conversationId == conversationId }))) ?? []
        guard !existing.contains(where: { $0.cardsJSON?.contains("\"chart\"") == true }) else { return }
        // Numbers computed, not written: 7 nights of 452/418/431/356/402/467/489 min average 430.7 = 7 h 11 m, 49 min
        // under 8 h; the shortest is Friday 16 Oct (5 h 56 m); Sunday and Monday are the two nights over 7 h 45 m.
        let nights: [(String, Int)] = [("2026-10-13", 452), ("2026-10-14", 418), ("2026-10-15", 431), ("2026-10-16", 356),
                                       ("2026-10-17", 402), ("2026-10-18", 467), ("2026-10-19", 489)]
        let answer: [String: Any] = [
            "response_type": "insight_with_chart",
            "title": "Your sleep this week",
            "summary": "You averaged **7 h 11 m** a night — 49 min under your 8 h goal. Friday was the short one at 5 h 56 m, and you made most of it back over Sunday and Monday.",
            "bullets": ["Two nights cleared 7 h 45 m: Sunday and Monday.",
                        "Friday's bedtime was 1 h 10 m later than your usual."],
            "chart": [
                "chart_type": "bar", "title": "Hours asleep, last 7 nights", "metric": "sleep",
                "range": ["start": "2026-10-13", "end": "2026-10-19"],
                "data": nights.map { ["x": $0.0, "y": $0.1, "series": NSNull()] as [String: Any] },
                "annotations": [["x": "2026-10-16", "label": "Friday: 5 h 56 m, the shortest night"]],
            ],
            "safety_note": NSNull(), "data_quality_note": "Sample data, not live readings.",
            "sources": [],
            "follow_up_chips": ["Why was Friday so short?", "What bedtime gets me to 8 hours?", "Does short sleep lower my HRV?"],
            "actions_taken": [], "confidence": "medium",
        ]
        // The question that answer replies to. Both are dated just AFTER now: the demo store's daily briefing is
        // written at launch, and a question dated earlier landed the briefing between the question and its answer.
        let question = CoachMessage(conversationId: conversationId, role: "user", body: "How did I sleep this week?")
        question.createdAt = AppClock.now.addingTimeInterval(1)
        context.insert(question)
        guard let data = try? JSONSerialization.data(withJSONObject: answer),
              let json = String(data: data, encoding: .utf8) else { return }
        let message = CoachMessage(conversationId: conversationId, role: "assistant", body: "You averaged 6 h 36 m…")
        message.cardsJSON = json
        message.createdAt = AppClock.now.addingTimeInterval(2)
        context.insert(message)
        try? context.save()
    }
    #endif

    /// Compresses + persists the picked image and stages it for the next send.
    private func stage(_ image: UIImage) {
        guard let ref = CoachAttachmentStore.save(image) else { return }
        stagedImage = image
        stagedAttachment = ref
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            stage(image)
        }
        photosPickerItem = nil
    }

    /// Removes the staged image and deletes its on-disk file (it was never sent).
    private func clearStagedImage() {
        if let ref = stagedAttachment { CoachAttachmentStore.delete(ref) }
        stagedImage = nil
        stagedAttachment = nil
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = stagedAttachment
        // Allow image-only sends: require either text or a staged image.
        guard !(trimmed.isEmpty && attachment == nil), !viewModel.isSending else { return }
        let conversationId = resolveConversationId()
        // Title a fresh conversation from its opening message.
        if let convo = conversations.first(where: { $0.id == conversationId }),
           isDefaultTitle(convo.title),
           !hasMessages(in: conversationId) {
            let seed = trimmed.isEmpty ? "Photo" : String(trimmed.prefix(40))
            convo.title = seed
            try? modelContext.save()
        }
        draft = ""
        stagedImage = nil
        stagedAttachment = nil
        composerFocused = false
        let attachments = attachment.map { [$0] } ?? []
        Task { await viewModel.send(trimmed, conversationId: conversationId, context: modelContext, attachments: attachments, coordinator: coordinator) }
    }

    /// The active conversation, creating one on first use.
    private func resolveConversationId() -> UUID {
        if let id = activeConversationId { return id }
        if let existing = conversations.first {
            activeConversationId = existing.id
            return existing.id
        }
        let conversation = CoachConversation(title: "New chat")
        modelContext.insert(conversation)
        try? modelContext.save()
        activeConversationId = conversation.id
        return conversation.id
    }

    private func isDefaultTitle(_ title: String) -> Bool {
        title == "New chat" || title == "Today check-in"
    }

    /// Open a specific conversation requested via deep-link (notification tap or
    /// a Today/Sleep summary-card tap).
    private func openRequestedConversation() {
        if let id = nav.requestedConversationId {
            activeConversationId = id
        }
        nav.requestedConversationId = nil
    }

    private func newConversation() {
        composerFocused = false
        let conversation = CoachConversation(title: "New chat")
        modelContext.insert(conversation)
        try? modelContext.save()
        activeConversationId = conversation.id
    }
}

/// Conversation history sheet — pick a past conversation to resume.
struct CoachHistorySheet: View {
    let conversations: [CoachConversation]
    let activeId: UUID?
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    Text("No conversations yet.")
                        .font(AgaraFont.subheadline.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(conversations) { convo in
                            Button { onSelect(convo.id); dismiss() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(convo.title)
                                            .font(AgaraFont.callout)
                                            .foregroundStyle(AgaraColors.textPrimary)
                                            // On the TITLE, not the row: a `List` row's own identifier does not reach the
                                            // accessibility tree (so a UI test cannot find or tap it by id).
                                            .accessibilityIdentifier("coach.history.title")
                                        Text(Self.dateFormatter.string(from: convo.updatedAt))
                                            .font(AgaraFont.caption2.weight(.regular))
                                            .foregroundStyle(AgaraColors.textMuted)
                                    }
                                    Spacer()
                                    if convo.id == activeId {
                                        Image(systemName: "checkmark").foregroundStyle(AgaraColors.accent)
                                    }
                                }
                            }
                            .listRowBackground(AgaraColors.card)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AgaraColors.background)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension UIApplication {
    /// Resigns the first responder app-wide (used to dismiss the keyboard on
    /// tab changes, where no single FocusState is in scope).
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct CoachOrb: View {
    var size: CGFloat = 40
    @State private var animate = false
    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [AgaraColors.accent, AgaraColors.spo2, AgaraColors.sleep, AgaraColors.accent],
                    center: .center
                )
            )
            .frame(width: size, height: size)
            .overlay(Circle().fill(AgaraColors.background.opacity(0.25)))
            .overlay(
                Circle().fill(.white.opacity(0.9)).frame(width: size * 0.22, height: size * 0.22)
                    .offset(x: -size * 0.12, y: -size * 0.12)
            )
            .shadow(color: AgaraColors.accent.opacity(0.5), radius: animate ? 10 : 4)
            .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true } }
    }
}

struct CoachBubble: View {
    let message: CoachMessage
    /// The conversation's data-based starter prompts, used to top an answer's chips up to three.
    var fallbackChips: [String] = []
    var onChipTap: ((String) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenWorkout: ((UUID) -> Void)?
    var onOpenMeal: ((UUID) -> Void)?

    /// Activity ids logged/edited by this turn — drive the in-chat workout card.
    private var loggedActivityIds: [UUID] {
        Self.decodeIds(message.loggedActivityIdsJSON)
    }

    /// Meal ids logged/edited by this turn — drive the in-chat meal card.
    private var loggedMealIds: [UUID] {
        Self.decodeIds(message.loggedMealIdsJSON)
    }

    private static func decodeIds(_ json: String?) -> [UUID] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }

    private var isAssistantOrError: Bool {
        message.role == "assistant" || message.role == "error"
    }

    private var structured: CoachResponse? {
        message.role == "assistant" ? CoachResponse.decode(fromJSON: message.cardsJSON) : nil
    }

    private var pendingAction: PendingAction? {
        message.role == "assistant" ? PendingAction.decode(fromJSON: message.pendingActionJSON) : nil
    }

    private var turnError: CoachTurnError? {
        message.role == "error" ? CoachTurnError.decode(fromJSON: message.cardsJSON) : nil
    }

    private var attachments: [CoachAttachmentRef] {
        CoachAttachmentRef.decode(fromJSON: message.attachmentsJSON)
    }

    /// Two shapes, on purpose. The user's message is a bubble at the trailing edge — short, theirs. The coach's answer is
    /// not a bubble: it is the page, full width, so a summary, bullets, a chart and three questions read as one document.
    /// Boxing it capped it at ~85% of the width and put a card (the chart) inside a card (the bubble).
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" { Spacer(minLength: 56) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 10) {
                ForEach(attachments, id: \.file) { ref in attachmentImage(ref) }
                content
                if let pendingAction {
                    CoachActionCardView(
                        action: pendingAction,
                        onConfirm: { onConfirm?() },
                        onCancel: { onCancel?() }
                    )
                }
                if isAssistantOrError {
                    ForEach(loggedActivityIds, id: \.self) { id in
                        CoachWorkoutCard(activityId: id, onOpen: { onOpenWorkout?($0) })
                    }
                    ForEach(loggedMealIds, id: \.self) { id in
                        CoachMealCard(mealId: id, onOpen: { onOpenMeal?($0) })
                    }
                    CoachToolTraceDisclosure(messageId: message.id)
                }
            }
            .frame(maxWidth: message.role == "user" ? nil : .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        if let turnError {
            CoachErrorBubble(error: turnError)
        } else if let structured {
            CoachResponseView(response: structured, fallbackChips: fallbackChips, onChipTap: onChipTap)
        } else if message.role == "user" && message.body.isEmpty && !attachments.isEmpty {
            // Image-only message: the image is the bubble, no empty text bubble below.
            EmptyView()
        } else {
            if message.role == "user" {
                Text(message.body)
                    .font(AgaraFont.subheadline.weight(.regular))
                    .foregroundStyle(AgaraColors.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AgaraColors.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Text(coachMarkdown: message.body)
                    .font(AgaraFont.body.weight(.regular))
                    .lineSpacing(3)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Renders an attached image (loaded from `CoachAttachmentStore`) as part of
    /// the message bubble. Falls back to a placeholder if the file is missing.
    @ViewBuilder private func attachmentImage(_ ref: CoachAttachmentRef) -> some View {
        if let image = CoachAttachmentStore.loadImage(ref) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(maxWidth: 240, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AgaraColors.borderSubtle, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AgaraColors.card)
                .frame(width: 120, height: 90)
                .overlay(Image(systemName: "photo").foregroundStyle(AgaraColors.textMuted))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AgaraColors.borderSubtle, lineWidth: 1))
        }
    }
}

/// Red-bordered error bubble shown when a coach turn fails. Displays the error
/// code (e.g. "HTTP 401") and the full reason so failures are explicit in chat,
/// across all providers. Matches the chat design system (card background, 18pt
/// radius, 14pt padding) with a `AgaraColors.danger` accent.
struct CoachErrorBubble: View {
    let error: CoachTurnError

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AgaraFont.footnote.weight(.semibold))
                Text("Coach error")
                    .font(AgaraFont.footnote.weight(.semibold))
                Text("·").foregroundStyle(AgaraColors.textMuted)
                Text(error.code)
                    .font(AgaraFont.face(12, .semibold).monospacedDigit())
            }
            .foregroundStyle(AgaraColors.danger)

            Text(error.reason)
                .font(AgaraFont.subheadline.weight(.regular))
                .foregroundStyle(AgaraColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(AgaraColors.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AgaraColors.danger, lineWidth: 1.5)
        )
    }
}

/// Live progress strip shown while a turn runs (in-process trace). Folds the
/// event stream into completed tool steps (shown with a status icon) above the
/// current phase's spinner row, so the user sees the turn's work accumulate.
/// The answer while it is still being written: the same heading and body type as `CoachResponseView`, plain text (the
/// final answer brings the markdown, bullets, chart and chips), and a quiet "Writing…" line under it.
struct CoachStreamingPreview: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title)
                    .font(AgaraFont.headline)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.isEmpty {
                Text(CoachText.keepUnitsTogether(summary))
                    .font(AgaraFont.body.weight(.regular))
                    .lineSpacing(3)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
            }
            Text("Writing…")
                .font(AgaraFont.caption)
                .foregroundStyle(AgaraColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coach.streaming")
    }
}

struct CoachTraceStrip: View {
    let events: [CoachTraceEvent]

    /// One finished tool step: a friendly label plus success/failure.
    private struct Step: Identifiable {
        let id = UUID()
        let label: String
        let failed: Bool
    }

    /// Fold the event stream into completed tool steps. A `.runningTool` opens a
    /// step; the matching `.completedTool`/`.failedTool` (same toolName) closes the
    /// most recent still-open step. Shows the last ≤4 finished steps.
    private var completedSteps: [Step] {
        var open: [(toolName: String?, label: String)] = []
        var done: [Step] = []
        for event in events {
            switch event.status {
            case .runningTool:
                open.append((event.toolName, event.label))
            case .completedTool, .failedTool:
                if let index = open.lastIndex(where: { $0.toolName == event.toolName }) {
                    let entry = open.remove(at: index)
                    done.append(Step(label: entry.label, failed: event.status == .failedTool))
                } else {
                    done.append(Step(label: event.label, failed: event.status == .failedTool))
                }
            default:
                break
            }
        }
        return Array(done.suffix(4))
    }

    /// Current phase label for the spinner row (thinking / writing / working).
    private var currentLabel: String {
        events.last(where: { $0.status == .thinking || $0.status == .writingAnswer })?.label
            ?? events.last(where: { $0.status == .runningTool })?.label
            ?? "Thinking…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(completedSteps) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.failed ? "xmark.circle" : "checkmark.circle")
                        .font(AgaraFont.caption2)
                        .foregroundStyle(step.failed ? AgaraColors.danger : AgaraColors.success)
                    Text(step.label)
                        .font(AgaraFont.caption.weight(.regular))
                        .foregroundStyle(AgaraColors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(AgaraColors.accent)
                Text(currentLabel)
                    .font(AgaraFont.caption.weight(.regular))
                    .foregroundStyle(AgaraColors.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agaraGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: completedSteps.count)
    }
}

/// Queries one conversation's messages (all messages only while no conversation exists yet) and hands
/// them to `content` — a `@Query` predicate is fixed at init, so the view is rebuilt per conversation.
private struct CoachMessagesReader<Content: View>: View {
    @Query private var messages: [CoachMessage]
    private let content: ([CoachMessage]) -> Content

    init(conversationId: UUID?, @ViewBuilder content: @escaping ([CoachMessage]) -> Content) {
        if let id = conversationId {
            _messages = Query(filter: #Predicate<CoachMessage> { $0.conversationId == id }, sort: \CoachMessage.createdAt)
        } else {
            _messages = Query(sort: \CoachMessage.createdAt)
        }
        self.content = content
    }

    var body: some View { content(messages) }
}
