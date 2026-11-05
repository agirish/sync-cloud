import AppKit

/// What pressing Return in the pane search field means.
///
/// A pure table because the view can't be driven from a test: ↩ and ⇧↩ both arrive as `onSubmit`
/// with the direction read from the modifiers, and a SwiftUI `Button` is not an `NSControl`. ↩ and
/// ⇧↩ must stay next and previous match even when the query names a person, or the field's own
/// placeholder ("↩ next, ⇧↩ previous") would be wrong.
public enum PaneSearchSubmit {

    public enum Action: Equatable, Sendable {
        /// Turn the find into a person gather.
        case acceptPerson
        /// Walk the plain substring matches.
        case advance(reverse: Bool)
    }

    /// - Parameter hasOffer: whether the query names exactly one person right now.
    public static func action(modifiers: NSEvent.ModifierFlags, hasOffer: Bool) -> Action {
        // The person offer takes ⌘↩, a chord with no other meaning here, so both plain directions
        // survive a query that happens to be a name.
        if modifiers.contains(.command), hasOffer { return .acceptPerson }
        return .advance(reverse: modifiers.contains(.shift))
    }
}

/// The two buttons beside the counter, as a value.
///
/// The buttons can't be pressed from a test, and they differ only by the Bool they hand
/// `onSearchAdvance`, so a copy-paste slip would draw a correct-looking ▲ and ▼ that both walk one
/// way. The direction, glyph, name and chord live here together, where `PaneHeaderSearchTests` can
/// check they line up. The chords are stated, not derived, and
/// `theButtonChordsMatchWhatSubmitActuallyDoes` checks them against `PaneSearchSubmit`.
public enum PaneSearchStep: CaseIterable, Sendable {
    case previous
    case next

    /// What `onSearchAdvance` is called with; its parameter is `reverse`.
    public var reverse: Bool { self == .previous }

    /// Up for previous, down for next, not the ‹ › this header uses for Back/Forward: the search row
    /// replaces the pane bar, and one pair of chevrons meaning history in one state and match in the
    /// other would be misread.
    public var systemImage: String { self == .previous ? "chevron.up" : "chevron.down" }

    /// The tooltip's sentence and the accessibility label.
    public var label: String { self == .previous ? "Previous match" : "Next match" }

    /// The keyboard equivalent the tooltip advertises.
    public var chord: String { self == .previous ? "⇧↩" : "↩" }
}
