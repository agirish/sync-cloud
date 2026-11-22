import Foundation

/// What the user chose about one number: current or older, whose, where it is used, the card it
/// goes on, and the copy it is read from. Every re-read and every move between To Confirm and
/// the Vault carries them as one value (VT69).
///
/// Stored flat, beside the record's own fields, under the keys each record has always used. A
/// find and a waiting choice store this value; a saved entry keeps a field for each, whose keys
/// are not this shape (``VaultEntry/choices``), so a new choice is a field there too.
public struct VaultChoices: Equatable, Sendable {
    /// Current or older (Pin).
    public var pin: VaultPin?
    /// Whose it is (Belongs To); nil goes by the name read.
    public var assignment: VaultAssignment?
    /// Where it is used (Used In); nil goes by the document.
    public var geo: VaultGeo?
    /// The card it goes on (Kind); nil goes by what it was read or typed as.
    public var card: VaultCardID?
    /// The copy of its document it is read from (Read from This Copy), by path; nil lets the
    /// Vault choose.
    public var source: String?

    public init(pin: VaultPin? = nil, assignment: VaultAssignment? = nil, geo: VaultGeo? = nil,
                card: VaultCardID? = nil, source: String? = nil) {
        self.pin = pin
        self.assignment = assignment
        self.geo = geo
        self.card = card
        self.source = source
    }

    /// Whether the user chose anything.
    public var isChosen: Bool { self != VaultChoices() }

    /// Each choice made here, and `other`'s where none was: a number typed in while it waits in
    /// To Confirm keeps what was chosen about it there.
    public func or(_ other: VaultChoices?) -> VaultChoices {
        guard let other else { return self }
        return VaultChoices(pin: pin ?? other.pin, assignment: assignment ?? other.assignment,
                            geo: geo ?? other.geo, card: card ?? other.card, source: source ?? other.source)
    }

    /// A key of the record the choices are stored in.
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Read from the record `decoder` holds, beside its own fields; `source` is under
    /// `sourceKey`.
    init(from decoder: Decoder, sourceKey: String) throws {
        let c = try decoder.container(keyedBy: Key.self)
        pin = try c.decodeIfPresent(VaultPin.self, forKey: Key("pin"))
        assignment = try c.decodeIfPresent(VaultAssignment.self, forKey: Key("assignment"))
        geo = try c.decodeIfPresent(VaultGeo.self, forKey: Key("geo"))
        card = try c.decodeIfPresent(VaultCardID.self, forKey: Key("card"))
        source = try c.decodeIfPresent(String.self, forKey: Key(sourceKey))
    }

    /// Written into the record `encoder` holds, beside its own fields; a choice not made is not
    /// written.
    func encode(to encoder: Encoder, sourceKey: String) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(pin, forKey: Key("pin"))
        try c.encodeIfPresent(assignment, forKey: Key("assignment"))
        try c.encodeIfPresent(geo, forKey: Key("geo"))
        try c.encodeIfPresent(card, forKey: Key("card"))
        try c.encodeIfPresent(source, forKey: Key(sourceKey))
    }
}
