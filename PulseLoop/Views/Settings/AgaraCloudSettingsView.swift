import SwiftUI
import SwiftData
import os

/// Agara cloud account + sync screen: sign in / create account / sign out, and a manual
/// "Sync now" (push local → pull cloud, in that order, so a fresh device ends up with both).
@MainActor
struct AgaraCloudSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var client = AgaraCloudClient.shared
    @State private var sync = AgaraCloudSync.shared
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var statusText: String?
    @State private var lastSync = UserDefaults.standard.object(forKey: "agara.lastSync") as? Date
    @State private var showSignOutDialog = false
    private static let log = Logger(subsystem: "com.pulseloop.lab", category: "agara-settings")

    private var signedIn: Bool { client.isSignedIn }

    /// Client-side gate mirroring the server rules (PocketBase demands ≥ 8 chars) so a bad password
    /// never leaves the screen.
    private var emailValid: Bool { email.contains("@") && email.count >= 3 }
    private var passwordValid: Bool { password.count >= 8 }
    private var canSubmit: Bool { emailValid && passwordValid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCopy(
                    title: signedIn ? "Signed in as \(client.email ?? "?")" : "Agara Cloud",
                    body: signedIn
                        ? "Your steps, sleep and vitals sync to your Agara account. Sync now after a "
                          + "ring session, or log in on another device to pull everything back."
                        : "Create an account (or sign in) to keep your ring data in the Agara cloud. "
                          + "Data already on this device uploads on your first sync."
                )

                if !signedIn {
                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                        HStack {
                            Button("Create account") { run { try await client.register(email: email, password: password) } }
                                .buttonStyle(.borderedProminent)
                            Button("Sign in") { run { try await client.signIn(email: email, password: password) } }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(working || !canSubmit)
                        if !password.isEmpty && !passwordValid {
                            Text("Password must be at least 8 characters.")
                                .font(.caption)
                                .foregroundStyle(PulseColors.danger)
                        } else if !email.isEmpty && !emailValid {
                            Text("Enter a valid email address.")
                                .font(.caption)
                                .foregroundStyle(PulseColors.danger)
                        } else if passwordValid {
                            Text("Password looks good.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Button("Sync now") { run { try await syncNow() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(working)
                        Button("Sign out", role: .destructive) { showSignOutDialog = true }
                            .disabled(working)
                    }
                }

                if let lastSync {
                    Text("Last sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(PulseColors.background)
        .confirmationDialog(
            "Sign out of Agara Cloud? Your data stays on this device.",
            isPresented: $showSignOutDialog, titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                client.signOut()
                statusText = nil
            }
        }
        .task {
            // Prefill the last-used email so signing back in is quick.
            if email.isEmpty, let known = UserDefaults.standard.string(forKey: "agara.email") {
                email = known
            }
        }
    }

    /// Perform an action, surfacing success/failure as the status line.
    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        statusText = nil
        Task {
            do {
                try await action()
                statusText = signedIn ? "Done." : nil
            } catch {
                statusText = error.localizedDescription
                Self.log.error("cloud action failed: \(error.localizedDescription)")
            }
            working = false
        }
    }

    private func syncNow() async throws {
        let pushed = try await sync.push(context: modelContext)
        let pulled = try await sync.pull(context: modelContext)
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "agara.lastSync")
        statusText = "Pushed \(pushed.days) day(s) / \(pushed.measurements) reading(s), pulled \(pulled) day(s)."
    }
}