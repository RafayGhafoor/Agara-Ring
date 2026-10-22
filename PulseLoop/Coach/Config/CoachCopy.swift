import Foundation

/// Every user-visible string the Coach tab adds for release 1.1 (tab bar, the cloud-coach states, the consent flow,
/// the quota pill and the starter prompts). One file so the strings can be catalogued into
/// `docs/strings/brand.yaml` and generated for both apps at once — nothing here is hand-written twice.
///
/// Each member's doc comment says what the user sees and whether Android must match it:
///
/// * **Android: match** — same words on both apps once the cloud coach ports (the parity matrix lists the coach as
///   iOS-first, so these are the strings the port takes over unchanged).
/// * **Android: n/a** — an iOS-only surface (the on-device Apple model, the gear, the account screen).
///
/// Existing shared copy stays where it is (`AgaraCopy.coachTitle`, `AgaraCloudCopy.*`); this file holds only what is
/// new. Format strings ("%d", "%@") get their arguments from `CoachCopy`'s helpers next to them.
enum CoachCopy {

    // MARK: - Tab bar

    /// The Coach tab's title. **Android: match** (the tab keeps the name the coach has everywhere).
    static let tabTitle = "Coach"

    // MARK: - Coach-off state (the master switch or the `coach` flag is off)

    /// Card headline when the coach is switched off. **Android: match**
    static let offTitle = "AI Coach is off"

    /// Card body when the coach is switched off. **Android: match**
    static let offBody = "Turn the coach on to ask about your sleep, heart rate, activity and recovery."

    /// Button that switches the coach on from the card. **Android: match**
    static let offEnable = "Turn on Coach"

    /// Button that opens Settings › AI Coach. **Android: match**
    static let openSettings = "Coach Settings"

    // MARK: - Signed out

    /// Card headline when the cloud coach is selected but nobody is signed in. **Android: match**
    static let signedOutTitle = "Sign in to use the cloud coach"

    /// Card body for the signed-out state: why an account is needed, and the free alternative. **Android: match**
    static let signedOutBody = "The cloud coach needs an Agara account, so your daily questions follow you between phones. You can also use the on-device coach — it is free and nothing leaves your phone."

    /// Button that opens the Agara Cloud account screen. **Android: match**
    static let signIn = "Sign in"

    /// Button that switches the coach to the on-device model (no account, no network). **Android: n/a** for the exact
    /// wording — Android's on-device path depends on its own platform model — but the offer itself is parity.
    static let useOnDevice = "Use the on-device coach"

    // MARK: - Email not verified

    /// Card headline when the account exists but its email is unverified (the coach spends money per call, so it
    /// has no grace window — coach-proxy.md §4). **Android: match**
    static let unverifiedTitle = "Verify your email"

    /// Card body for the unverified state. **Android: match**
    static let unverifiedBody = "The cloud coach only answers for a verified address. Open your inbox, tap the link we sent, then come back here."

    /// Button that opens the account screen, where the verification state and the resend button live. **Android: match**
    static let openAccount = "Open account"

    // MARK: - Consent (Apple 5.1.2(i))

    /// Card headline before the first cloud question, when consent has not been given. **Android: match**
    static let consentTitle = "Your permission is needed"

    /// Card body before the first cloud question. **Android: match**
    static let consentBody = "The cloud coach sends a short, numeric summary of your health data to an AI provider. Nothing is stored on our server. The on-device coach never sends anything."

    /// Button that opens the consent sheet. **Android: match**
    static let consentReview = "Review and agree"

    /// The consent sheet's title. **Android: match**
    static let consentSheetTitle = "Share data with the cloud coach?"

    /// Consent sheet, section 1 heading: exactly what leaves the device (coach-proxy.md §5). **Android: match**
    static let consentLeavesTitle = "What leaves your phone"

    /// Consent sheet, section 1 body — one line per item sent. **Android: match**
    static let consentLeavesBody = [
        "Age, sex, height and weight",
        "Your goals, today's totals and the last seven days",
        "Your latest vitals, last night's sleep and recent workouts",
        "The questions you type and the answers you get",
    ]

    /// Consent sheet, section 1 footer: what is deliberately withheld. **Android: match**
    static let consentNeverSent = "Never sent: your name, email, city or location, raw sensor data, and anything from Apple Health that another app recorded."

    /// Consent sheet, section 2 heading: who answers. **Android: match**
    static let consentProviderTitle = "Who answers"

    /// Consent sheet, section 2 body: the third-party provider. **Android: match**
    static let consentProviderBody = "OpenCode Go, running a DeepSeek model. It is a third-party AI provider, not Agara."

    /// Consent sheet, section 2 footer: the provider's retention window (coach-proxy.md §13). Renegotiated monthly,
    /// so this line names the commitment rather than a date. **Android: match**
    static let consentProviderRetention = "The provider agrees to zero-day retention and does not train on your data."

    /// Consent sheet, section 3 heading: what the server keeps. **Android: match**
    static let consentStoredTitle = "What is kept"

    /// Consent sheet, section 3 body: nothing is stored (coach-proxy.md §12). **Android: match**
    static let consentStoredBody = "Nothing. A question and its answer are held in memory only while the coach is answering, then dropped. We write no prompts, answers or health data to our server or our logs."

    /// Consent sheet, section 4 heading: how to withdraw. **Android: match**
    static let consentWithdrawTitle = "How to change your mind"

    /// Consent sheet, section 4 body: the withdrawal path. **Android: match** (the path is the same screen in both apps).
    static let consentWithdrawBody = "Settings › AI Coach › Cloud coach consent › Withdraw. Cloud answers stop at once and the on-device coach stays available."

    /// Consent sheet's primary button. **Android: match**
    static let consentAgree = "Agree and continue"

    /// Consent sheet's secondary button. **Android: match**
    static let consentDecline = "Not now"

    // MARK: - Settings › AI Coach: the consent record and its withdrawal

    /// Settings group heading for the coach's cloud consent. **Android: match**
    static let consentSettingsHeader = "Cloud coach"

    /// Row title in Settings › AI Coach. **Android: match**
    static let consentRow = "Cloud coach consent"

    /// Trailing value when consent is on record. **Android: match**
    static let consentGiven = "Agreed"

    /// Trailing value when consent is not on record. **Android: match**
    static let consentNotGiven = "Not given"

    /// Footer under the consent row: what withdrawing does. **Android: match**
    static let consentSettingsFooter = "Withdrawing stops cloud answers immediately and switches the coach back to on-device. Your health data stays on your phone."

    /// Button that withdraws consent (goes through the shared `ConfirmAction`). **Android: match**
    static let consentWithdraw = "Withdraw consent"

    /// Confirmation title before withdrawing consent. **Android: match**
    static let consentWithdrawConfirmTitle = "Withdraw cloud coach consent?"

    /// Confirmation body before withdrawing consent. **Android: match**
    static let consentWithdrawConfirmBody = "Cloud answers stop immediately and the coach switches to the on-device model. Nothing about your data changes; you can agree again at any time."

    /// Confirmation button label for withdrawing consent. **Android: match**
    static let consentWithdrawConfirm = "Withdraw"

    // MARK: - Coach busy

    /// Card headline when a turn is already running for this account (`409 coach_busy`). **Android: match**
    static let busyTitle = "The coach is still answering"

    /// Card body for the busy state. **Android: match**
    static let busyBody = "One answer at a time. Give it a moment, then ask again."

    /// Button that re-checks the busy state. **Android: match**
    static let busyRetry = "Try again"

    // MARK: - Out of quota

    /// Card headline when today's cloud questions are used up. **Android: match**
    static let quotaTitle = "That's all for today"

    /// Card body when today's questions are used up and the reset time is known. **Android: match**
    /// Argument: the formatted reset time ("21 Oct at 00:00").
    static func quotaResets(at formatted: String) -> String {
        "Your daily cloud questions reset \(formatted). Until then you can keep going with the on-device coach."
    }

    /// Card body when today's questions are used up and the reset time is not known yet. **Android: match**
    static let quotaUnknownReset = "Your daily cloud questions reset at midnight. Until then you can keep going with the on-device coach."

    /// The quota pill in the coach header. **Android: match**
    /// Argument: questions left today, from `X-Coach-Remaining-Day`.
    static func quotaPill(remaining: Int) -> String {
        remaining == 1 ? "1 left today" : "\(remaining) left today"
    }

    /// The header line's quota, after "Agara Cloud ·": the line shares its row with four controls and "24 left today"
    /// truncated there. The VoiceOver label still says "today" and when it resets. **Android: match**
    static func quotaShort(remaining: Int) -> String { "\(remaining) left" }

    /// The quota pill's VoiceOver label, which also says when the count resets. **Android: match**
    /// Arguments: questions left, and the formatted reset time (or nil when unknown).
    static func quotaPillSpoken(remaining: Int, resets: String?) -> String {
        let left = remaining == 1 ? "1 cloud question left today" : "\(remaining) cloud questions left today"
        guard let resets else { return left }
        return "\(left), resetting \(resets)"
    }

    /// The pill's VoiceOver hint: what the count refers to. **Android: match**
    static let quotaPillHint = "Cloud questions left today"

    /// The header's subtitle under the coach name when the cloud coach answers. **Android: match**
    static let headerCloudSubtitle = "Using your synced ring data in the cloud"

    /// The header's subtitle under the coach name when the on-device model answers. **Android: match**
    static let headerOnDeviceSubtitle = "Answering on this phone — nothing is sent"

    /// The header's short status line above the title: where answers come from. It shares a row with four controls,
    /// so it is two words; the full sentences above are its VoiceOver label, and tapping it opens Usage and privacy.
    /// **Android: match**
    static let headerStatusCloud = "Agara Cloud"
    static let headerStatusOnDevice = "On this phone"

    /// The usage sheet's model when the conversation has no recorded turn yet and the cloud answers (it fell back to the
    /// bring-your-own-key model field and said "gpt-5.4"). Same provider as `consentProviderBody`. **Android: match**
    static let cloudModelLabel = "DeepSeek, via OpenCode Go"

    /// The sheet the status line opens. **Android: match**
    static let privacySheetTitle = "Privacy & usage"

    /// What tapping the status line does, for VoiceOver. **Android: match**
    static let headerStatusHint = "Opens usage and privacy"

    /// Settings › AI Coach status line when the cloud coach is ready (signed in, verified, agreed, quota left).
    /// **Android: match**
    static let cloudStatusReady = "Ready · Agara Cloud"

    /// The provider picker's (and Settings row's) name for the cloud coach. **Android: match**
    static let providerCloud = "Agara Cloud"

    // MARK: - Empty conversation: data-based starter prompts

    /// Starter prompt when last night's sleep score is known. **Android: match**
    /// Argument: the score ("78").
    static func starterSleepScore(_ score: Int) -> String {
        "My sleep score was \(score) — how do I improve it?"
    }

    /// Starter prompt when last night's sleep duration is known but the score is not. **Android: match**
    /// Argument: the formatted duration ("6h 20m").
    static func starterSleepDuration(_ duration: String) -> String {
        "I slept \(duration) last night — is that enough?"
    }

    /// Starter prompt for the day's step count. **Android: match**
    /// Argument: steps so far today ("4,210").
    static func starterSteps(_ steps: String) -> String {
        "I'm at \(steps) steps today — how am I doing?"
    }

    /// Starter prompt for the resting heart rate. **Android: match**
    /// Argument: bpm ("62").
    static func starterRestingHR(_ bpm: String) -> String {
        "My resting heart rate is \(bpm) bpm — is that normal?"
    }

    /// Starter prompt when the ring has not delivered today's data yet. **Android: match**
    static let starterNoData = "What data is missing?"

    /// Starter prompt for the weekly rollup. **Android: match**
    static let starterWeek = "Summarize my week"

    /// Starter prompt naming the latest vital the ring reported. **Android: match**
    /// Arguments: the metric ("SpO₂") and its value ("97%").
    static func starterVital(_ metric: String, _ value: String) -> String {
        "My \(metric) is \(value) — what does that mean?"
    }

    // MARK: - History

    /// History button's VoiceOver label (the header's clock icon). **Android: match**
    static let historyButton = "Conversation history"

    /// History sheet's title. **Android: match**
    static let historyTitle = "Conversations"

    /// History sheet's empty state. **Android: match**
    static let historyEmpty = "No conversations yet."
}
