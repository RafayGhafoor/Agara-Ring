import Foundation
import SwiftData

/// The name a user gives their ring ("Left hand", "Sleep ring", …). Pure rules shared by the pairing
/// "Name your ring" step, the Wearable screen's Rename sheet and every surface that shows the ring's
/// name. Mirrors Android `RingNickname`: trimmed, 1–24 characters, and an empty name means "use the
/// model name" (stored as nil, never as an empty string).
enum RingNickname {
    static let maxLength = 24
    /// Suggestion chips under the text field, in display order. Identical on Android.
    static let suggestions = ["Left hand", "Right hand", "Sleep ring", "Spare"]
    /// What an un-named ring is called: the catalog model name ("Agara Ring").
    static var defaultName: String { WearableModel.tk20.displayName }

    /// The value to store for what the user typed: trimmed, capped at `maxLength`, and nil when blank
    /// (the ring then shows its model name).
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The unchanged model name is "no nickname", as on Android: storing it would freeze today's
        // catalog name onto the row instead of following the model.
        guard !trimmed.isEmpty, trimmed != defaultName else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    /// Whether the editor may save `raw` as-is. Blank is valid (it resets to the model name); longer
    /// than `maxLength` after trimming is not — the field caps input, so this only guards paste.
    static func isValid(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).count <= maxLength
    }

    /// Caps live input in the text field at `maxLength` characters (leading/trailing space is only
    /// trimmed on save, so typing "Left " before "hand" still works).
    static func clampInput(_ raw: String) -> String {
        raw.count > maxLength ? String(raw.prefix(maxLength)) : raw
    }

    /// What the "Name your ring" step and the Rename sheet prefill: the connected ring's remembered name
    /// (per-ring map, keyed by `identifier`), else the person's own name when the profile has one, else the
    /// model name — so Save without editing keeps a re-paired ring's name instead of blanking it or copying
    /// another ring's.
    ///
    /// The person's name is a *prefill*, not a stored name: the pairing step runs before the profile step in
    /// onboarding, so it has nothing to offer there, and Rename is where a ring with no name gets one.
    static func prefill(
        identifier: String?,
        row: Device?,
        personName: String? = nil,
        memory: RingNicknameMemory = RingNicknameMemory()
    ) -> String {
        memory.nickname(forConnected: identifier ?? row?.peripheralIdentifier, row: row)
            ?? forPerson(personName)
            ?? defaultName
    }

    /// The suffix every person-derived name ends with. The typographic apostrophe (`’`, U+2019) is what the
    /// rest of the app's copy uses, and a name ending in *s* takes it too ("James’s Ring") — one style, no
    /// exceptions for a later session to re-derive (plan `scan-row-ring-name.md`, D6).
    static let possessiveSuffix = "’s Ring"

    /// The ring name a person's own name suggests: "Hayden Smith" → "Hayden’s Ring".
    ///
    /// A ring named after its person is what makes two rings in one room tellable apart, and it is the only
    /// thing the app knows about its owner. First word only, first letter capitalised, surrounding punctuation
    /// dropped, and the whole string capped at `maxLength` by shortening the *name* — never the suffix, so a
    /// very long name still yields a name that reads as one. `nil` when there is no usable name, which leaves
    /// the model name in place (the pre-existing behaviour).
    static func forPerson(_ raw: String?) -> String? {
        guard let name = firstWord(of: raw) else { return nil }
        let room = maxLength - possessiveSuffix.count
        guard room > 0 else { return nil }
        let shortened = String(name.prefix(room)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortened.isEmpty else { return nil }
        return shortened + possessiveSuffix
    }

    /// The chips under the name field: the person's own name first when the profile has one, then the standing
    /// suggestions. Deduped, so a person whose derived name equals a standing chip does not see it twice.
    static func suggestions(forPerson personName: String?) -> [String] {
        let personal = forPerson(personName).map { [$0] } ?? []
        return (personal + suggestions).reduce(into: [String]()) { chips, chip in
            if !chips.contains(chip) { chips.append(chip) }
        }
    }

    /// The first word of a name, with punctuation and whitespace trimmed off both ends, capitalised.
    /// A word with no letters in it ("123", "--") is not a person's name.
    private static func firstWord(of raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) else { return nil }
        let stripped = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
        guard stripped.contains(where: { $0.isLetter }) else { return nil }
        return stripped.prefix(1).uppercased() + stripped.dropFirst()
    }

    /// The name to show: the nickname when set, else the model name, else the default model name.
    static func displayName(nickname: String?, modelName: String?) -> String {
        if let nickname, let name = normalized(nickname) { return name }
        if let modelName, !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return modelName }
        return defaultName
    }
}

extension Device {
    /// Catalog model name for this row ("Agara Ring"), falling back to the family's display name.
    var modelDisplayName: String {
        WearableModel.model(id: wearableModelID)?.displayName ?? deviceType.displayName
    }

    /// What every surface calls this ring: the user's nickname, else its model name.
    var displayName: String {
        RingNickname.displayName(nickname: nickname, modelName: modelDisplayName)
    }
}

/// Per-ring nickname memory. The app keeps ONE `Device` row and reuses it for whichever ring connects,
/// so a nickname stored only on the row would be lost (or shown on the wrong ring) when the user owns
/// several rings. This map — ring identity → nickname, a JSON dictionary under `ringNicknames` in
/// UserDefaults — lets each ring keep its own name. Mirrors Android's per-address map.
///
/// The identity is the CoreBluetooth peripheral UUID (`CBPeripheral.identifier`): iOS never exposes the
/// ring's MAC, and that UUID is stable for a given ring on this phone across launches and reconnects
/// (it is what `RingBLEClient` already persists to auto-reconnect). It is stored on the row as
/// `Device.peripheralIdentifier`.
struct RingNicknameMemory {
    static let defaultsKey = "ringNicknames"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every remembered ring → nickname. Missing or unreadable storage reads as empty.
    var all: [String: String] {
        guard let json = defaults.string(forKey: Self.defaultsKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    func nickname(for identifier: String) -> String? {
        all[identifier].flatMap(RingNickname.normalized)
    }

    /// The name to prefill for the ring that just connected, before its connect event may have reached
    /// the store: that ring's remembered name; the row's only when the row is (or may be) that ring.
    func nickname(forConnected identifier: String?, row: Device?) -> String? {
        guard let identifier else { return row?.nickname }
        if let remembered = nickname(for: identifier) { return remembered }
        let sameRing = row?.peripheralIdentifier == nil || row?.peripheralIdentifier == identifier
        return sameRing ? row?.nickname : nil
    }

    /// Store (or, for nil / a blank / the model name, drop) one ring's nickname, normalized.
    func set(_ nickname: String?, for identifier: String) {
        var map = all
        map[identifier] = nickname.flatMap(RingNickname.normalized)
        write(map)
    }

    func remove(identifier: String) {
        set(nil, for: identifier)
    }

    /// A ring with `identifier` is now the one on the row: show that ring's own nickname. The row's
    /// current nickname is migrated into the map instead when it demonstrably belongs to this ring —
    /// the row has no identity yet (a name saved before this memory existed, or in the pairing step
    /// before the connect event landed) or already has this identity — and the map has no entry for it.
    func adopt(identifier: String, on device: Device) {
        let sameRing = device.peripheralIdentifier == nil || device.peripheralIdentifier == identifier
        if sameRing, nickname(for: identifier) == nil, let current = device.nickname.flatMap(RingNickname.normalized) {
            set(current, for: identifier)
        } else {
            device.nickname = nickname(for: identifier)
        }
        device.peripheralIdentifier = identifier
    }

    private func write(_ map: [String: String]) {
        guard !map.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }
}

extension DeviceRepository {
    /// Give an unnamed ring the person's own name once the profile knows it (plan `scan-row-ring-name.md`, D5/B2).
    ///
    /// Onboarding asks the ring's name *before* the person's, so the default case — pair, name nothing, fill in
    /// the profile — would otherwise leave the ring as "Agara Ring" for ever, and every row of a crowded scan
    /// list would read the same. Called when the profile is saved; it never replaces a name anybody chose and
    /// does nothing when no ring is paired, so it is safe to call on every profile save. The per-ring map makes
    /// it idempotent, so a re-connect cannot re-apply it after the user clears the name.
    ///
    /// Returns whether this call gave the ring its name (tests read it; callers ignore it).
    @MainActor
    @discardableResult
    static func adoptPersonName(
        _ personName: String?,
        peripheralIdentifier: String? = nil,
        memory: RingNicknameMemory = RingNicknameMemory(),
        context: ModelContext
    ) -> Bool {
        guard let suggested = RingNickname.forPerson(personName) else { return false }
        guard let device = current(context: context) else { return false }
        let identity = peripheralIdentifier ?? device.peripheralIdentifier
        let existing = identity.flatMap { memory.nickname(for: $0) }
            ?? device.nickname.flatMap(RingNickname.normalized)
        guard existing == nil else { return false }
        device.nickname = suggested
        if let identity { memory.set(suggested, for: identity) }
        device.updatedAt = AppClock.now
        try? context.save()
        AgaraDataChange.shared.notify()
        return true
    }

    /// Store the user's name for the (single) current ring, on the row and in the per-ring memory under
    /// that ring's identity. Blank resets to the model name. Creates the row when a just-paired ring's
    /// connect event has not been persisted yet, so the name is never lost; the event subscriber reuses
    /// that same row (`fetchDevices(context).first ?? Device()`).
    ///
    /// `peripheralIdentifier` is the live connected ring's identity when the caller knows it (the pairing
    /// step, which can run before the connect event reaches the store); it defaults to the row's.
    @MainActor
    @discardableResult
    static func setNickname(
        _ raw: String,
        peripheralIdentifier: String? = nil,
        memory: RingNicknameMemory = RingNicknameMemory(),
        context: ModelContext
    ) -> Device {
        let device: Device
        if let existing = current(context: context) {
            device = existing
        } else {
            device = Device()
            context.insert(device)
        }
        if let peripheralIdentifier, peripheralIdentifier != device.peripheralIdentifier {
            // Claim the row for the live ring now, so the connect event that follows recognises it.
            device.peripheralIdentifier = peripheralIdentifier
        }
        device.nickname = RingNickname.normalized(raw)
        if let identifier = device.peripheralIdentifier {
            memory.set(device.nickname, for: identifier)
        }
        device.updatedAt = AppClock.now
        try? context.save()
        AgaraDataChange.shared.notify()
        return device
    }
}
