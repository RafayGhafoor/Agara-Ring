import Foundation

/// Thin adapter over the shared catalog (`docs/strings/brand.yaml` `cloud_*` keys -> `AgaraCopy.cloud…`), so both apps say
/// the same thing (Rule 5). Placeholders `{email}` `{seconds}` `{date}` `{code}` are filled here with plain replacement.
/// Only `cancel` and `metricName` are native.
enum AgaraCloudCopy {
    private static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    // Settings row / intro
    static let title = AgaraCopy.cloudTitle
    static let notConfiguredTitle = AgaraCopy.cloudNotConfiguredTitle
    static let notConfiguredBody = AgaraCopy.cloudNotConfiguredBody
    static let introBody = AgaraCopy.cloudIntro

    // Consent (Apple 5.1.1(v) / 5.1.3)
    static let consentTitle = AgaraCopy.cloudConsentTitle
    static let consentIntro = AgaraCopy.cloudConsentIntro
    static let consentWhatTitle = AgaraCopy.cloudConsentWhatTitle
    static let consentWhat = [AgaraCopy.cloudConsentWhatReadings, AgaraCopy.cloudConsentWhatDaily, AgaraCopy.cloudConsentWhatSleep]
    static let consentNotUploaded = AgaraCopy.cloudConsentNotUploaded
    static let consentWhereTitle = AgaraCopy.cloudConsentWhereTitle
    static let consentWhere = AgaraCopy.cloudConsentWhere
    static let consentDeleteTitle = AgaraCopy.cloudConsentDeleteTitle
    static let consentDelete = AgaraCopy.cloudConsentDelete
    static let consentAgree = AgaraCopy.cloudConsentAgree
    static let consentDecline = AgaraCopy.cloudConsentDecline

    // Account forms
    static let signUp = AgaraCopy.cloudSignUp
    static let signIn = AgaraCopy.cloudSignIn
    static let email = AgaraCopy.cloudEmail
    static let password = AgaraCopy.cloudPassword
    static let forgotPassword = AgaraCopy.cloudForgotPassword
    static let resetSent = AgaraCopy.cloudResetSent
    static let passwordHint = AgaraCopy.cloudPasswordRule

    // Verify
    static let verifyTitle = AgaraCopy.cloudVerifyTitle
    static func verifyBody(_ email: String) -> String { fill(AgaraCopy.cloudVerifyBody, ["email": email]) }
    static let verifyCheck = AgaraCopy.cloudVerifyCheck
    static let verifyResend = AgaraCopy.cloudVerifyResend
    static func verifyResendIn(_ seconds: Int) -> String { fill(AgaraCopy.cloudVerifyResendIn, ["seconds": String(seconds)]) }
    static let verifyStillWaiting = AgaraCopy.cloudVerifyStillWaiting
    static func graceBanner(_ date: String) -> String { fill(AgaraCopy.cloudVerifyGrace, ["date": date]) }
    static let graceOver = AgaraCopy.cloudVerifyBlocked

    // Signed in
    static func signedInAs(_ email: String) -> String { fill(AgaraCopy.cloudSignedInAs, ["email": email]) }
    static let syncNow = AgaraCopy.cloudSyncNow
    static let syncing = AgaraCopy.cloudSyncing
    static let lastSync = AgaraCopy.cloudLastSync
    static let never = AgaraCopy.cloudNever
    static let blocksSynced = AgaraCopy.cloudUploaded
    static let signOut = AgaraCopy.cloudSignOut
    static let deleteAccount = AgaraCopy.cloudDeleteAccount
    static let deleteAccountTitle = AgaraCopy.cloudDeleteTitle
    static let deleteAccountConfirm = AgaraCopy.cloudDeleteConfirm
    static let cancel = "Cancel"   // generic system-style label: native
    static let deleteAccountBody = AgaraCopy.cloudDeleteBody
    static let deleteAllDataCloudNote = AgaraCopy.cloudDeleteAllDataNote
    static let reauthTitle = AgaraCopy.cloudReauthTitle
    static let reauthBody = AgaraCopy.cloudReauthBody
    static let reauthConfirm = AgaraCopy.cloudReauthConfirm

    // Privacy screen
    static let privacyFooterSignedIn = AgaraCopy.cloudPrivacyFooterSignedIn
    static let privacyStoredSignedIn = AgaraCopy.cloudPrivacyStoredSignedIn

    // Errors (Firebase Auth and the server), in plain language
    static func authError(_ error: AgaraAuthError) -> String {
        switch error {
        case .emailExists: return AgaraCopy.cloudErrorEmailExists   // never says whether the address is registered
        case .invalidCredentials: return AgaraCopy.cloudErrorInvalidCredentials   // same words for an unknown address and a wrong password
        case .tooManyAttempts: return AgaraCopy.cloudErrorTooManyAttempts
        case .weakPassword: return AgaraCopy.cloudPasswordRule
        case .invalidEmail: return AgaraCopy.cloudEmailInvalid
        case .userDisabled: return AgaraCopy.cloudErrorUserDisabled
        case .sessionExpired: return AgaraCopy.cloudErrorSessionExpired
        case .recentLoginRequired: return AgaraCopy.cloudErrorRecentLogin
        case .notSignedIn: return AgaraCopy.cloudErrorNotSignedIn
        case .notConfigured: return AgaraCopy.cloudErrorNotConfigured
        case .network: return AgaraCopy.cloudFailureOffline
        case .server: return AgaraCopy.cloudErrorServer
        }
    }
    static let requestTimedOut = AgaraCopy.cloudErrorTimeout
    static let accountDeletedElsewhere = AgaraCopy.cloudFailureAccountDeleted
    static let serverRateLimited = AgaraCopy.cloudFailureRateLimited
    static let serverUnavailable = AgaraCopy.cloudFailureServerUnavailable
    static func serverRefused(_ code: String) -> String { fill(AgaraCopy.cloudErrorServerRefused, ["code": code]) }

    // Status lines
    static func failure(_ failure: AgaraCloud.Failure) -> String {
        switch failure {
        case .offline: return AgaraCopy.cloudFailureOffline
        case .rateLimited: return AgaraCopy.cloudFailureRateLimited
        case .serverUnavailable: return AgaraCopy.cloudFailureServerUnavailable
        case .emailNotVerified: return AgaraCopy.cloudVerifyBlocked
        case .accountDeleted: return AgaraCopy.cloudFailureAccountDeleted
        case .sessionExpired: return AgaraCopy.cloudErrorSessionExpired
        case .updateRequired: return AgaraCopy.cloudFailureUpdateRequired
        case .sampleData: return AgaraCopy.cloudFailureSampleData
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
