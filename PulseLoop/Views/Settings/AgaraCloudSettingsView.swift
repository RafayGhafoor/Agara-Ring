import SwiftUI

/// Settings › Agara Cloud (release 1.1, behind the `agara_cloud` flag). One screen, five states driven by
/// `AgaraCloud.phase`: not configured · consent · sign up / sign in · verify your email · signed in.
/// The app never requires an account; every state has a way back.
struct AgaraCloudSettingsView: View {
    @State private var cloud = AgaraCloud.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch cloud.phase {
                case .notConfigured: CloudNotConfiguredView()
                case .needsConsent: CloudConsentView(cloud: cloud)
                case .signedOut: CloudAuthView(cloud: cloud)
                case .needsVerification: CloudVerifyView(cloud: cloud)
                case .ready: CloudAccountView(cloud: cloud)
                }
            }
            .padding(16)
        }
        .background(AgaraColors.background)
        .pageChrome(AgaraCloudCopy.title)
        .accessibilityIdentifier("cloud.screen")
        .onAppear { cloud.refresh() }
    }
}

// MARK: - Not configured

private struct CloudNotConfiguredView: View {
    var body: some View {
        StatusCopy(title: AgaraCloudCopy.notConfiguredTitle, body: AgaraCloudCopy.notConfiguredBody)
            .accessibilityIdentifier("cloud.notConfigured")
    }
}

// MARK: - Consent (before any sign-up, hence before any upload)

private struct CloudConsentView: View {
    let cloud: AgaraCloud
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusCopy(title: AgaraCloudCopy.consentTitle, body: AgaraCloudCopy.consentIntro)
                .accessibilityIdentifier("cloud.consent")
            SettingsGroup(header: AgaraCloudCopy.consentWhatTitle) {
                ForEach(AgaraCloudCopy.consentWhat, id: \.self) { line in
                    Text(line).font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            SettingsGroup(header: AgaraCloudCopy.consentWhereTitle) {
                Text(AgaraCloudCopy.consentWhere).font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            SettingsGroup(header: AgaraCloudCopy.consentDeleteTitle) {
                Text(AgaraCloudCopy.consentDelete).font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            PrimaryButton(title: AgaraCloudCopy.consentAgree, systemImage: "checkmark") { cloud.acceptConsent() }
                .accessibilityIdentifier("cloud.consent.agree")
            SecondaryButton(title: AgaraCloudCopy.consentDecline, systemImage: "xmark") { dismiss() }
                .accessibilityIdentifier("cloud.consent.decline")
        }
    }
}

// MARK: - Sign up / sign in / forgot password

private struct CloudAuthView: View {
    let cloud: AgaraCloud
    private enum Mode: String, CaseIterable, Identifiable {
        case signUp, signIn
        var id: String { rawValue }
        var title: String { self == .signUp ? AgaraCloudCopy.signUp : AgaraCloudCopy.signIn }
    }
    @State private var mode: Mode = .signUp
    @State private var email = ""
    @State private var password = ""
    @State private var resetNote: String?

    private var emailValid: Bool { email.contains("@") && email.count >= 3 }
    private var passwordValid: Bool { AgaraAuthClient.passwordLengthOK(password) }
    private var canSubmit: Bool { emailValid && passwordValid && !cloud.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusCopy(title: AgaraCloudCopy.title, body: AgaraCloudCopy.introBody)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cloud.mode")

            SettingsGroup(footer: mode == .signUp ? AgaraCloudCopy.passwordHint : nil) {
                FormField {
                    TextField(AgaraCloudCopy.email, text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .accessibilityIdentifier("cloud.email")
                }
                FormField {
                    // No content type on purpose: the Designed-for-iPad Mac autofill bridge throws a benign ObjC exception.
                    SecureField(AgaraCloudCopy.password, text: $password)
                        .accessibilityIdentifier("cloud.password")
                }
            }

            if mode == .signUp, !password.isEmpty, !passwordValid {
                Text(AgaraAuthError.weakPassword.message).font(AgaraFont.footnote).foregroundStyle(AgaraColors.danger)
                    .accessibilityIdentifier("cloud.passwordHint")
            }
            if let message = cloud.authMessage ?? resetNote {
                Text(message).font(AgaraFont.footnote)
                    .foregroundStyle(cloud.authMessage != nil ? AgaraColors.danger : AgaraColors.textMuted)
                    .accessibilityIdentifier("cloud.message")
            }

            PrimaryButton(title: mode.title, systemImage: mode == .signUp ? "person.badge.plus" : "person.fill") {
                resetNote = nil
                Task {
                    if mode == .signUp { await cloud.signUp(email: email, password: password) }
                    else { await cloud.signIn(email: email, password: password) }
                }
            }
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
            .accessibilityIdentifier("cloud.submit")

            if mode == .signIn {
                Button(AgaraCloudCopy.forgotPassword) {
                    Task { if await cloud.sendPasswordReset(email: email) { resetNote = AgaraCloudCopy.resetSent } }
                }
                .font(AgaraFont.footnote)
                .disabled(!emailValid || cloud.busy)
                .accessibilityIdentifier("cloud.forgot")
            }
        }
        .task { if email.isEmpty, let known = cloud.email { email = known } }
    }
}

// MARK: - Verify your email

private struct CloudVerifyView: View {
    let cloud: AgaraCloud
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusCopy(title: AgaraCloudCopy.verifyTitle, body: AgaraCloudCopy.verifyBody(cloud.email ?? ""))
            if cloud.syncAllowed == false || cloud.status == .failed(.emailNotVerified) {
                Text(AgaraCloudCopy.graceOver).font(AgaraFont.footnote).foregroundStyle(AgaraColors.warning)
                    .accessibilityIdentifier("cloud.grace")
            } else if let graceEnds = cloud.graceEndsAt {
                Text(AgaraCloudCopy.graceBanner(graceEnds.formatted(date: .abbreviated, time: .shortened)))
                    .font(AgaraFont.footnote).foregroundStyle(AgaraColors.warning)
                    .accessibilityIdentifier("cloud.grace")
            }
            if let message = cloud.authMessage ?? note {
                Text(message).font(AgaraFont.footnote)
                    .foregroundStyle(cloud.authMessage != nil ? AgaraColors.danger : AgaraColors.textMuted)
                    .accessibilityIdentifier("cloud.message")
            }
            PrimaryButton(title: AgaraCloudCopy.verifyCheck, systemImage: "checkmark.seal") {
                Task { if await cloud.checkVerification() { note = nil } else { note = AgaraCloudCopy.verifyStillWaiting } }
            }
            .disabled(cloud.busy)
            .accessibilityIdentifier("cloud.verify.check")

            // Re-send with a cooldown. TimelineView re-evaluates each second so the label counts down.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, Int((cloud.resendAvailableAt ?? .distantPast).timeIntervalSince(AppClock.now).rounded(.up)))
                SecondaryButton(title: remaining > 0 ? AgaraCloudCopy.verifyResendIn(remaining) : AgaraCloudCopy.verifyResend,
                                systemImage: "envelope") { Task { await cloud.resendVerification() } }
                    .disabled(remaining > 0 || cloud.busy)
                    .opacity(remaining > 0 ? 0.5 : 1)
                    .accessibilityIdentifier("cloud.verify.resend")
            }
            Button(AgaraCloudCopy.signOut, role: .destructive) { cloud.signOut() }
                .font(AgaraFont.footnote)
                .accessibilityIdentifier("cloud.signOut")
        }
        // Auto-poll every `verify_poll_seconds` while this screen is showing; cancelled when it goes away.
        .task { await cloud.pollVerification() }
        .task { await cloud.refreshMe() }
    }
}

// MARK: - Signed in

private struct CloudAccountView: View {
    let cloud: AgaraCloud
    @State private var progress = SyncProgress.shared
    @State private var confirm: ConfirmAction?
    @State private var askPassword = false
    @State private var password = ""
    @State private var deleteError: String?

    private var syncing: Bool { cloud.status == .syncing }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusCopy(title: AgaraCloudCopy.signedInAs(cloud.email ?? "?"), body: AgaraCloudCopy.introBody)

            SettingsGroup {
                FormValueRow(title: AgaraCloudCopy.lastSync) {
                    Text(cloud.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? AgaraCloudCopy.never)
                        .foregroundStyle(AgaraColors.textMuted)
                        .accessibilityIdentifier("cloud.lastSync")
                }
                if cloud.totalBlocks > 0 {
                    FormValueRow(title: AgaraCloudCopy.blocksSynced) {
                        Text("\(cloud.syncedBlocks) / \(cloud.totalBlocks)").foregroundStyle(AgaraColors.textMuted)
                            .accessibilityIdentifier("cloud.counts")
                    }
                }
            }

            if case let .failed(failure) = cloud.status {
                Text(AgaraCloudCopy.failure(failure)).font(AgaraFont.footnote).foregroundStyle(AgaraColors.warning)
                    .accessibilityIdentifier("cloud.status")
            }

            if syncing || progress.cloudActive {
                SettingsGroup(header: AgaraCloudCopy.syncing) {
                    ForEach(progress.cloudRows) { row in
                        FormValueRow(title: AgaraCloudCopy.metricName(row.metric)) {
                            ProgressView(value: row.fraction).frame(width: 90)
                            Text("\(row.done)/\(row.total)").font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                        }
                    }
                }
                .accessibilityIdentifier("cloud.progress")
            }

            PrimaryButton(title: syncing ? AgaraCloudCopy.syncing : AgaraCloudCopy.syncNow, systemImage: "arrow.triangle.2.circlepath") {
                Task { await cloud.syncNow() }
            }
            .disabled(syncing)
            .opacity(syncing ? 0.5 : 1)
            .accessibilityIdentifier("cloud.syncNow")

            if let deleteError {
                Text(deleteError).font(AgaraFont.footnote).foregroundStyle(AgaraColors.danger)
                    .accessibilityIdentifier("cloud.deleteError")
            }
            SecondaryButton(title: AgaraCloudCopy.signOut, systemImage: "rectangle.portrait.and.arrow.right") {
                confirm = .signOutCloud { cloud.signOut() }
            }
            .disabled(syncing)
            .accessibilityIdentifier("cloud.signOut")
            DestructiveButton(title: AgaraCloudCopy.deleteAccount, systemImage: "trash") {
                confirm = .deleteCloudAccount { Task { await delete() } }
            }
            .disabled(syncing || cloud.busy)
            .accessibilityIdentifier("cloud.deleteAccount")
        }
        .confirmAction($confirm)
        .alert(AgaraCloudCopy.reauthTitle, isPresented: $askPassword) {
            SecureField(AgaraCloudCopy.password, text: $password)
            Button(AgaraCloudCopy.reauthConfirm) {
                let entered = password
                password = ""
                Task { if await cloud.reauthenticate(password: entered) { await delete() } else { deleteError = cloud.authMessage } }
            }
            Button(AgaraCloudCopy.cancel, role: .cancel) { password = "" }
        } message: { Text(AgaraCloudCopy.reauthBody) }
        .task { await cloud.refreshMe() }
    }

    private func delete() async {
        deleteError = nil
        switch await cloud.deleteAccount() {
        case .deleted: break
        case .needsRecentLogin: askPassword = true
        case let .failed(message): deleteError = message
        }
    }
}
