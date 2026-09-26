import SwiftUI
import SwiftData

/// The ring-name field and its suggestion chips. Shared by the pairing "Name your ring" step and the
/// Wearable screen's Rename sheet so both edit the name the same way (Android `RingNameEditor`).
/// Input is capped at `RingNickname.maxLength`; trimming happens on save.
struct RingNameEditor: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    private var trimmedCount: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .foregroundStyle(AgaraColors.textMuted)
                    .accessibilityHidden(true)
                TextField(RingNickname.defaultName, text: $text)
                    .font(AgaraFont.body)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .accessibilityLabel("Ring name")
                    .accessibilityHint("Up to \(RingNickname.maxLength) characters. Leave empty to use \(RingNickname.defaultName).")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear name")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusControl, style: .continuous), interactive: true)
            .onChange(of: text) { _, new in
                let clamped = RingNickname.clampInput(new)
                if clamped != new { text = clamped }
            }

            HStack {
                Text("Leave it empty to use \(RingNickname.defaultName).")
                Spacer()
                Text("\(trimmedCount)/\(RingNickname.maxLength)")
                    .monospacedDigit()
                    .accessibilityLabel("\(trimmedCount) of \(RingNickname.maxLength) characters")
            }
            .font(AgaraFont.caption)
            .foregroundStyle(AgaraColors.textMuted)
            .padding(.horizontal, 4)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips(RingNickname.suggestions) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { chips(Array(RingNickname.suggestions.prefix(2))) }
                    HStack(spacing: 8) { chips(Array(RingNickname.suggestions.suffix(2))) }
                }
            }
            .agaraGlassContainer(spacing: 8)
        }
    }

    @ViewBuilder
    private func chips(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            let selected = RingNickname.normalized(text) == name
            Button { text = name } label: {
                Text(name)
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? AgaraColors.textPrimary : AgaraColors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .agaraGlass(Capsule(), interactive: true, tint: selected ? AgaraColors.accent : nil)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .accessibilityLabel("Name it \(name)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Wearable screen → Rename: the same editor in a sheet. Save writes the nickname (blank resets to the
/// model name); Cancel leaves it untouched.
struct RenameRingSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    /// The connected ring's identity, so Save files the name under that ring (nil: the row's ring).
    private let peripheralIdentifier: String?

    /// `initialText` is `RingNickname.prefill(…)`: the ring's remembered name, else the model name.
    init(initialText: String, peripheralIdentifier: String? = nil) {
        _text = State(initialValue: initialText)
        self.peripheralIdentifier = peripheralIdentifier
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Give your ring a name you'll recognise.")
                        .font(AgaraFont.subheadline)
                        .foregroundStyle(AgaraColors.textMuted)
                    RingNameEditor(text: $text, onSubmit: save)
                }
                .padding(20)
            }
            .background(AgaraColors.background.ignoresSafeArea())
            .navigationTitle("Rename ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!RingNickname.isValid(text))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard RingNickname.isValid(text) else { return }
        DeviceRepository.setNickname(text, peripheralIdentifier: peripheralIdentifier, context: modelContext)
        dismiss()
    }
}
