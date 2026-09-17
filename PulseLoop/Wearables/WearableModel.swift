import SwiftUI

/// A selectable ring model for the pairing carousel — purely presentational, layered over the
/// persisted `RingDeviceType` family.
///
/// There is exactly one entry: the **Agara Ring** (the Veepoo/TK20 family). This is an Agara-only
/// build, so the catalog no longer models several families, and the app-variant picker that used to
/// disambiguate the earlier ring families's two firmwares is gone with them. `advertisedNamePatterns` is only
/// user-facing identity; protocol matching stays the coordinator's job.
struct WearableModel: Identifiable {
    let id: String
    let displayName: String
    /// Marketing brand, used to group models under the pairing screen's brand tabs.
    let brand: String
    /// The family this card resolves to. One family, one card.
    let family: RingDeviceType
    let tint: Color
    let blurb: String
    /// Bluetooth local-name patterns that identify this product. Protocol-family matching remains the
    /// coordinator's job; these patterns are only for user-facing identity.
    let advertisedNamePatterns: [String]
    /// Asset-catalog image name for this ring's product art. When nil, `RingArtView` falls back to a
    /// generic ring photo.
    var imageName: String? = nil
}

/// Copy for a user-initiated connect attempt that never completed. Pure, so the pairing screen's
/// recovery affordance and its tests reason about exactly the message `RingBLEClient` will show.
enum RingConnectFailure {
    static func message(family _: RingDeviceType?) -> String {
        "The ring didn't respond. Move it closer, wake it by tapping it, and try again."
    }
}

extension WearableModel {
    /// TK20 — the Veepoo-family ring sold with the "H Ring" app (`cn.hring.veepoo`), sold here as the
    /// **Agara Ring**. It advertises as plain `TK20` (the verified unit; the pattern also admits an
    /// `Agara`-suffixed name). No `imageName`: there is no TK20 imageset, and a non-nil name that isn't
    /// registered renders an empty platter — nil falls back to the generic ring art.
    static let tk20 = WearableModel(
        id: "tk20", displayName: AgaraCopy.ringDisplayName, brand: AgaraCopy.ringDisplayName,
        family: .veepoo,
        tint: PulseColors.hrv, blurb: "Steps · Sleep · HR · SpO₂ · HRV · BP · Stress · Glucose",
        advertisedNamePatterns: ["^TK20 ?[0-9A-Fa-f]{0,4}$", "^AGARA ?[0-9A-Fa-f]{0,4}$"],
        // No photograph of the ring exists, so the card carries the brand mark — the orange A,
        // transparent — rather than a generic silhouette.
        imageName: "agara-logo"
    )

    /// Every driver family this card can resolve to. The pairing screen filters discovered rows on this.
    var families: Set<RingDeviceType> { [family] }

    /// Whether a scan-tagged row belongs under this card.
    func acceptsScanFamily(_ scanFamily: RingDeviceType?) -> Bool {
        guard let scanFamily else { return false }
        return families.contains(scanFamily)
    }

    /// Every supported model. The pairing screen groups these by `brand` and sorts each tab
    /// alphabetically, so this array's order is not user-visible.
    static let catalog: [WearableModel] = [tk20]

    static func model(id: String?) -> WearableModel? {
        guard let id else { return nil }
        return catalog.first { $0.id == id }
    }

    /// The setup/onboarding surface — the same single card the pairing screen offers.
    static let setupCatalog: [WearableModel] = catalog

    static func model(advertisedName: String?) -> WearableModel? {
        guard let advertisedName else { return nil }
        let range = NSRange(advertisedName.startIndex..<advertisedName.endIndex, in: advertisedName)
        return catalog.first { model in
            model.advertisedNamePatterns.contains { pattern in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                return regex.firstMatch(in: advertisedName, options: [], range: range) != nil
            }
        }
    }

    /// Bluetooth identity wins when available; the user's carousel choice is the fallback for
    /// service-only or otherwise generic advertisements.
    static func resolve(
        advertisedName: String?,
        selectedModelID: String?,
        family: RingDeviceType
    ) -> WearableModel? {
        if let detected = model(advertisedName: advertisedName), detected.families.contains(family) {
            return detected
        }
        if let selected = model(id: selectedModelID), selected.families.contains(family) {
            return selected
        }
        // The only family that exists, so an unidentified Agara-family ring is still the Agara Ring.
        return family == .veepoo ? .tk20 : nil
    }
}
