import SwiftUI
import SwiftData
import UIKit
import PhotosUI

private let coldStartPrompts = [
    "How am I doing today?",
    "Explain my heart rate trend",
    "Summarize my week",
    "Should I work out?",
    "What data is missing?"
]

struct CoachView: View {
    /// Called when a workout card in the chat is tapped. Coach stays routing-agnostic
    /// so it reads the same whether it's presented as a tab or (as now) as a sheet —
    /// the presenter decides how to get to the activity detail.
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
    @FocusState private var composerFocused: Bool

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

    private func showColdStart(_ messages: [CoachMessage]) -> Bool {
        !viewModel.isSending && (messages.isEmpty || messages.last?.role == "assistant")
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
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(messages) { message in
                            CoachBubble(
                                message: message,
                                onChipTap: { send($0) },
                                onConfirm: { viewModel.confirmPendingAction(message, context: modelContext) },
                                onCancel: { viewModel.cancelPendingAction(message, context: modelContext) },
                                onOpenWorkout: { openWorkout($0) },
                                onOpenMeal: { openMeal($0) }
                            ).id(message.id)
                        }
                        if viewModel.isSending {
                            CoachTraceStrip(events: viewModel.traceEvents).id("trace")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: viewModel.traceEvents.count) {
                    withAnimation { proxy.scrollTo("trace", anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .agaraScrollEdges(.top)
            }

            VStack(spacing: 0) {
                if showColdStart(messages) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(coldStartPrompts, id: \.self) { prompt in
                                Button { send(prompt) } label: {
                                    Text(prompt)
                                        .font(AgaraFont.caption.weight(.regular))
                                        .foregroundStyle(AgaraColors.textSecondary)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .agaraGlass(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        // Prompt chips share one container so their glass renders/blends together.
                        .agaraGlassContainer(spacing: 6)
                    }
                }
                composer
            }
            // Clears the nav bar when idle; rises above the keyboard when typing.
            .padding(.bottom, composerBottomInset)
            .background(AgaraColors.secondaryBackground)
        }
        .background(AgaraColors.background)
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
        }
        .onChange(of: nav.requestedConversationId) { _, id in
            if id != nil { openRequestedConversation() }
        }
        .sheet(isPresented: $showHistory) {
            CoachHistorySheet(conversations: conversations, activeId: activeConversationId) { id in
                activeConversationId = id
            }
        }
        .sheet(isPresented: $showUsage) {
            CoachUsageSheet(
                conversation: activeConversation,
                messages: messages,
                settings: settingsStore.settings
            )
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

    private var header: some View {
        HStack(spacing: 12) {
            CoachOrb(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgaraCopy.coachTitle).font(AgaraFont.subheadline.weight(.semibold)).foregroundStyle(AgaraColors.textPrimary)
                Text("Using your latest ring sync").font(AgaraFont.caption2.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
            }
            Spacer()
            // Sibling glass circles share one container so their glass renders/blends together.
            HStack(spacing: 12) {
                Button { composerFocused = false; showUsage = true } label: {
                    Image(systemName: "info.circle").font(AgaraFont.body).foregroundStyle(AgaraColors.textSecondary)
                        .frame(width: 36, height: 36).agaraGlass(Circle(), interactive: true)
                        .minTapTarget(visualSize: 36)
                }
                .accessibilityLabel("Usage and privacy")
                Button { newConversation() } label: {
                    Image(systemName: "plus").font(AgaraFont.body).foregroundStyle(AgaraColors.textSecondary)
                        .frame(width: 36, height: 36).agaraGlass(Circle(), interactive: true)
                        .minTapTarget(visualSize: 36)
                }
                .accessibilityLabel("New conversation")
                // Conversation history: flag `coach_history` (iOS only today; Android port pending).
                if CoachGate.historyOn {
                    Button { composerFocused = false; showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath").font(AgaraFont.body).foregroundStyle(AgaraColors.textSecondary)
                            .frame(width: 36, height: 36).agaraGlass(Circle(), interactive: true)
                            .minTapTarget(visualSize: 36)
                    }
                    .accessibilityLabel("Conversation history")
                }
            }
            .agaraGlassContainer(spacing: 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(AgaraColors.secondaryBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(AgaraColors.borderSubtle).frame(height: 1) }
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
                        if UIImagePickerController.cameraAvailable { showCamera = true }
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

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
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
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var content: some View {
        if let turnError {
            CoachErrorBubble(error: turnError)
        } else if let structured {
            CoachResponseView(response: structured, onChipTap: onChipTap)
                .padding(14)
                .agaraGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if message.role == "user" && message.body.isEmpty && !attachments.isEmpty {
            // Image-only message: the image is the bubble, no empty text bubble below.
            EmptyView()
        } else {
            (message.role == "user" ? Text(message.body) : Text(coachMarkdown: message.body))
                .font(AgaraFont.subheadline.weight(.regular))
                .foregroundStyle(message.role == "user" ? AgaraColors.onAccent : AgaraColors.textPrimary)
                .padding(14)
                .modifier(CoachBubbleSurface(isUser: message.role == "user"))
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

/// Message-bubble surface: user bubbles keep the solid accent fill; assistant bubbles
/// use Liquid Glass. Kept as a modifier so the glass-vs-accent branch stays one place.
private struct CoachBubbleSurface: ViewModifier {
    let isUser: Bool
    func body(content: Content) -> some View {
        if isUser {
            content
                .background(AgaraColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.agaraGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
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
