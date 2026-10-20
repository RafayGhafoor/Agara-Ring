import SwiftUI

/// The cloud coach's disclosure sheet — Apple guideline 5.1.2(i): health data may only leave the device after the
/// user has been told, in the app, what is sent, to whom, what is kept, and how to stop it
/// (`docs/ring/coach-proxy.md` §11).
///
/// The four sections are the contract's four facts, in the contract's order, and the buttons are the shared
/// confirmation pattern the rest of the app uses for an important step: one clear primary action on the right of the
/// decision, the way out as a plain secondary, and nothing destructive or pre-selected. The same layout as Settings ›
/// Agara Cloud's consent (`StatusCopy` + `SettingsGroup` + `PrimaryButton`/`SecondaryButton`), so the two disclosures
/// read as one family; the strings live in `CoachCopy` for cataloguing.
///
/// Agreeing records the disclosure's version (`CoachConsentStore`), which is what the tab's state machine reads.
/// Withdrawing happens in Settings › AI Coach, next to the provider choice it affects.
struct CoachConsentSheet: View {
    /// Called after the user agrees, so the caller can re-resolve the tab's state.
    var onAgree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    private var consent = CoachConsentStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatusCopy(title: CoachCopy.consentSheetTitle, body: CoachCopy.consentBody)
                        .accessibilityIdentifier("coach.consent.intro")

                    SettingsGroup(header: CoachCopy.consentLeavesTitle, footer: CoachCopy.consentNeverSent) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(CoachCopy.consentLeavesBody, id: \.self) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "arrow.up.right")
                                        .font(AgaraFont.micro.weight(.semibold))
                                        .foregroundStyle(AgaraColors.accent)
                                        .padding(.top, 3)
                                    Text(line)
                                        .font(AgaraFont.subheadline)
                                        .foregroundStyle(AgaraColors.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                    .accessibilityIdentifier("coach.consent.leaves")

                    SettingsGroup(header: CoachCopy.consentProviderTitle, footer: CoachCopy.consentProviderRetention) {
                        Text(CoachCopy.consentProviderBody)
                            .font(AgaraFont.subheadline)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .accessibilityIdentifier("coach.consent.provider")

                    SettingsGroup(header: CoachCopy.consentStoredTitle) {
                        Text(CoachCopy.consentStoredBody)
                            .font(AgaraFont.subheadline)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .accessibilityIdentifier("coach.consent.stored")

                    SettingsGroup(header: CoachCopy.consentWithdrawTitle) {
                        Text(CoachCopy.consentWithdrawBody)
                            .font(AgaraFont.subheadline)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .accessibilityIdentifier("coach.consent.withdraw")

                    PrimaryButton(title: CoachCopy.consentAgree, systemImage: "checkmark") {
                        consent.give()
                        onAgree()
                        dismiss()
                    }
                    .accessibilityIdentifier("coach.consent.agree")

                    SecondaryButton(title: CoachCopy.consentDecline, systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("coach.consent.decline")
                }
                .padding(20)
            }
            .background(AgaraColors.background)
            .navigationTitle(CoachCopy.consentSettingsHeader)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
    }
}
