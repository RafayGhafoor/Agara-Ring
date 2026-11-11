import Foundation

/// One row of the pairing scan list: what it says and whether it is a ring this phone already knows.
///
/// `text` is for the row, `spokenText` for VoiceOver (the tag without the separator dot: "AGARA Heart, A1F3"
/// reads better than a mid-dot), and `isKnown` drives the order — a ring this phone remembers is the row the
/// person is looking for.
struct RingScanRow: Equatable {
    let text: String
    let spokenText: String
    let isKnown: Bool
}

/// Row order key. A struct rather than a tuple so `sorted()` and `XCTAssertLessThan` accept it: tuples do not
/// conform to `Comparable`.
struct RingScanOrder: Comparable {
    let known: Int
    let likely: Int
    let signal: Int

    static func < (lhs: RingScanOrder, rhs: RingScanOrder) -> Bool {
        (lhs.known, lhs.likely, lhs.signal) < (rhs.known, rhs.likely, rhs.signal)
    }

    init(isKnown: Bool, isLikelyRing: Bool, rssi: Int) {
        self.known = isKnown ? 0 : 1
        self.likely = isLikelyRing ? 0 : 1
        self.signal = -rssi
    }
}

/// What a discovered ring is called in the scan list, and which row comes first.
///
/// Both apps used to show the product copy for *every* recognised ring, so ten rings in one room produced ten
/// identical rows ("AGARA Heart") and the only differentiator was the signal glyph — the wrong tap paired
/// someone else's ring. The scan row is also the one surface that ignored the name the user gave the ring,
/// which Settings, the Wearable screen and the coach's `device_name` all honour.
///
/// So: a ring this phone has a name for is shown by that name; an unnamed ring is told apart by a short tag
/// hashed from its scan identity; anything unrecognised keeps its advertised name exactly as before (Rule 3
/// governs matched rings only). Pure and storage-free — the caller passes what `RingNicknameMemory` holds.
/// Android's `RingScanName` mirrors this file line for line (plan `scan-row-ring-name.md`, D1/D2).
enum RingScanName {
    /// Tag length in hex characters.
    static let tagLength = 4

    /// Separator between the product name and the tag.
    static let tagSeparator = " · "

    /// A short tag that is stable for one ring and differs between rings: FNV-1a 32-bit over the uppercased
    /// identity, low 16 bits, uppercase hex.
    ///
    /// Deliberately a hash rather than the address: iOS never exposes a ring's MAC (`CBPeripheral.identifier` is
    /// the only identity we have), and an address has no business on screen. The identity is stable per ring on
    /// this phone, so the tag survives relaunches and reconnects.
    static func tag(identity: String) -> String {
        var hash: UInt32 = 0x811C_9DC5          // FNV-1a offset basis
        for byte in identity.uppercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193          // FNV-1a prime
        }
        let hex = String(hash & 0xFFFF, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, tagLength - hex.count)) + hex
    }

    /// One row, given the scan identity, this ring's remembered name (if any) and the advertisement.
    ///
    ///  * a remembered name wins — it is the only value that tells two rings apart;
    ///  * a ring nobody named shows the product name plus its tag;
    ///  * a peripheral that is not a recognised ring keeps its advertised name and gets no tag.
    ///
    /// `isKnown` is true for a ring with a remembered name or for the ring this phone is paired to, which is
    /// what puts it first (D2).
    static func row(
        identity: String,
        nickname: String?,
        advertisedName: String?,
        isMatched: Bool,
        pairedIdentity: String?,
        productName: String = AgaraCopy.ringDisplayName
    ) -> RingScanRow {
        let known = RingNickname.normalized(nickname ?? "") != nil
            || (pairedIdentity.map { $0.caseInsensitiveCompare(identity) == .orderedSame } ?? false)
        guard isMatched else {
            // Unmatched peripherals are how a person finds a ring we do not recognise (and how a bug report
            // names it): the advertised name as-is, no tag, and never sorted as if it were theirs.
            let name = (advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? productName
            return RingScanRow(text: name, spokenText: name, isKnown: false)
        }
        if let nickname, let chosen = RingNickname.normalized(nickname) {
            return RingScanRow(text: chosen, spokenText: chosen, isKnown: true)
        }
        let tag = tag(identity: identity)
        return RingScanRow(
            text: productName + tagSeparator + tag,
            spokenText: productName + ", " + tag,
            isKnown: known
        )
    }

    /// Row order: a known ring first, then recognised rings, then the rest, each group by descending signal.
    static func sortKey(isKnown: Bool, isLikelyRing: Bool, rssi: Int) -> RingScanOrder {
        RingScanOrder(isKnown: isKnown, isLikelyRing: isLikelyRing, rssi: rssi)
    }
}
