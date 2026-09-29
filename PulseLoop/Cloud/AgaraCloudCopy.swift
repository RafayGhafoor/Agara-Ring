import Foundation

/// Native copy of the Agara Cloud screens (release 1.1). Written here for now; the lead moves the shared sentences into
/// `docs/strings/brand.yaml` (they are listed in the 1.1 hand-off report) so both apps say the same thing.
enum AgaraCloudCopy {
    // Settings row / intro
    static let title = "Agara Cloud"
    static let notConfiguredTitle = "Agara Cloud is not available yet"
    static let notConfiguredBody = "This build is not connected to an Agara Cloud server. Everything else in the app works as usual, and your data stays on this phone."
    static let introBody = "Optional. Back up your ring data to a private Agara account and pull it onto another phone. The app works fully without an account."

    // Consent (Apple 5.1.1(v) / 5.1.3)
    static let consentTitle = "Before you turn on Agara Cloud"
    static let consentIntro = "Agara Cloud is optional. Nothing leaves this phone until you agree and sign in."
    static let consentWhatTitle = "What is uploaded"
    static let consentWhat = [
        "Your ring readings: heart rate, SpO2, stress, HRV, temperature and the other measurements your ring records.",
        "Your daily steps, distance and calories.",
        "Your sleep: each night's times, stages and score.",
    ]
    static let consentWhereTitle = "Where it goes"
    static let consentWhere = "To Agara's servers, over an encrypted connection, tied to the account you create. This is health data. It is used only to back up and sync your data, and is not sold or shared."
    static let consentDeleteTitle = "How to delete it"
    static let consentDelete = "Settings › Agara Cloud › Delete account erases your cloud copy for good. Your data on this phone stays. You can also stop syncing any time by signing out."
    static let consentAgree = "I agree, continue"
    static let consentDecline = "Not now"

    // Account forms
    static let signUp = "Create account"
    static let signIn = "Sign in"
    static let email = "Email"
    static let password = "Password"
    static let forgotPassword = "Forgot password?"
    static let resetSent = "If an account exists for that address, a reset link is on its way."
    static let passwordHint = "8 to 128 characters."

    // Verify
    static let verifyTitle = "Verify your email"
    static func verifyBody(_ email: String) -> String { "We sent a link to \(email). Open it, then come back here. Sync starts as soon as your address is verified." }
    static let verifyCheck = "I've verified"
    static let verifyResend = "Resend email"
    static func verifyResendIn(_ seconds: Int) -> String { "Resend in \(seconds)s" }
    static let verifyStillWaiting = "Not verified yet. Check your inbox (and spam)."
    static func graceBanner(_ date: String) -> String { "Unverified accounts stop working with the cloud after \(date)." }
    static let graceOver = "The verification window has ended. Verify your email to use Agara Cloud."

    // Signed in
    static func signedInAs(_ email: String) -> String { "Signed in as \(email)" }
    static let syncNow = "Sync now"
    static let syncing = "Syncing…"
    static let lastSync = "Last sync"
    static let never = "Never"
    static let blocksSynced = "Uploaded"
    static let signOut = "Sign out"
    static let deleteAccount = "Delete account"
    static let deleteAccountTitle = "Delete your Agara Cloud account?"
    static let deleteAccountConfirm = "Delete account"
    static let cancel = "Cancel"
    static let deleteAccountBody = "This permanently deletes your account and everything stored in the cloud. It can't be undone. The data on this phone stays."
    static let deleteAllDataCloudNote = "You are signed in to Agara Cloud. This also signs you out on this phone, but does not delete your cloud account or cloud data. To delete those, use Settings › Agara Cloud › Delete account first."
    static let reauthTitle = "Enter your password"
    static let reauthBody = "For your security, confirm your password to delete the account."
    static let reauthConfirm = "Continue"

    // Privacy screen
    static let privacyFooterSignedIn = "You are signed in to Agara Cloud, so your readings, sleep and activity are also stored in your Agara account. Delete account in Settings › Agara Cloud removes that copy."
    static let privacyStoredSignedIn = "On this phone and in Agara Cloud"

    // Errors (Firebase Auth and the server), in plain language
    static func authError(_ error: AgaraAuthError) -> String {
        switch error {
        case .emailExists: return "We couldn't create that account. If you already have one, try signing in."
        case .invalidCredentials: return "The email or password is not right."   // same words for an unknown address and a wrong password
        case .tooManyAttempts: return "Too many attempts. Wait a few minutes and try again."
        case .weakPassword: return "Use a password of 8 to 128 characters."
        case .invalidEmail: return "Enter a valid email address."
        case .userDisabled: return "This account has been disabled."
        case .sessionExpired: return "Your sign-in expired. Please sign in again."
        case .recentLoginRequired: return "For your security, enter your password again to continue."
        case .notSignedIn: return "You are not signed in."
        case .notConfigured: return "Agara Cloud is not available in this build."
        case .network: return "No connection. Check your internet and try again."
        case .server: return "Something went wrong on the server. Please try again later."
        }
    }
    static let requestTimedOut = "The request timed out. Try again."
    static let accountDeletedElsewhere = "This account was deleted. Your data on this phone is untouched."
    static let serverRateLimited = "Too many requests. Try again in a moment."
    static let serverUnavailable = "The Agara Cloud server is unavailable. Try again later."
    static func serverRefused(_ code: String) -> String { "The server refused the request (\(code))." }

    // Status lines
    static func failure(_ failure: AgaraCloud.Failure) -> String {
        switch failure {
        case .offline: return "You're offline. Sync will retry when a connection is back."
        case .rateLimited: return "The server asked us to slow down. Retrying shortly."
        case .serverUnavailable: return "The Agara Cloud server is unavailable. Retrying shortly."
        case .emailNotVerified: return "Verify your email to keep syncing."
        case .accountDeleted: return "This account was deleted. Your data on this phone is untouched."
        case .sessionExpired: return "Your sign-in expired. Please sign in again."
        case .updateRequired: return "Update Agara Ring to keep syncing."
        case .sampleData: return "Sync is paused while sample data is shown."
        case let .other(message): return message
        }
    }

    static func metricName(_ metric: String) -> String {
        switch metric {
        case "hr": return "Heart rate"
        case "spo2": return "Blood oxygen"
        case "stress": return "Stress"
        case "hrv": return "HRV"
        case "temp": return "Temperature"
        case "bp_sys", "bp_dia": return "Blood pressure"
        case "glucose": return "Blood sugar"
        case "resp_rate": return "Breathing"
        case "steps": return "Steps"
        case "sleep_stage": return "Sleep stages"
        default: return metric.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
