import AppKit

/// What pressing Return in the pane search field means.
///
/// **Extracted because the view cannot be driven.** ↩ and ⇧↩ both arrive as `onSubmit` and the
/// direction is read from the modifiers at that moment; `onSubmit` cannot be fired from a unit
/// test and a SwiftUI `Button` is not an `NSControl`, so the routing had no coverage of any kind
/// while it was three lines inside the field. It is a pure table now, and the field calls it.
///
/// The table exists because the first cut got it wrong in a way nobody could see. ↩ accepted the
/// person offer, on the reasoning that ⇧↩ still "kept the plain search" — but ⇧↩ is *previous
/// match*, so on any query that happens to name someone (`daughter` matches twelve real filenames
/// here) forward advance became unreachable and the field's own placeholder, "↩ next, ⇧↩
/// previous", was wrong about both keys.
public enum PaneSearchSubmit {

    public enum Action: Equatable, Sendable {
        /// Turn the find into a person gather.
        case acceptPerson
        /// Walk the plain substring matches.
        case advance(reverse: Bool)
    }

    /// - Parameter hasOffer: whether the query names exactly one person right now.
    public static func action(modifiers: NSEvent.ModifierFlags, hasOffer: Bool) -> Action {
        // **The offer takes a chord of its own and steals nothing.** ⌘↩ had no meaning in this
        // field, so both plain directions survive a query that happens to be a name — which is
        // the property the first version lost.
        if modifiers.contains(.command), hasOffer { return .acceptPerson }
        return .advance(reverse: modifiers.contains(.shift))
    }
}

/// The two buttons beside the counter, as a value.
///
/// Same reason as the table above: the buttons cannot be pressed from a test (a SwiftUI `Button` is
/// not an `NSControl`), and they differ from each other only by the Bool they hand
/// `onSearchAdvance`. A copy-paste that walked forward twice would draw a correct-looking ▲ and ▼
/// and be wrong about half the control — so the direction, the glyph, the name and the chord live
/// here together, where `PaneHeaderSearchTests` can assert they line up.
///
/// The chords are stated rather than derived. They are the *same* keys `PaneSearchSubmit` routes,
/// and a button whose tooltip named a chord the field does not honour would teach a shortcut that
/// does nothing — so `theButtonChordsMatchWhatSubmitActuallyDoes` checks the two against each other.
public enum PaneSearchStep: CaseIterable, Sendable {
    case previous
    case next

    /// What `onSearchAdvance` is called with — its parameter is `reverse`.
    public var reverse: Bool { self == .previous }

    /// Up for previous, down for next. Deliberately NOT the ‹ › this same header uses for
    /// Back/Forward: the search row replaces the pane bar rather than joining it, so the two pairs
    /// are never on screen together, and one pair of left/right chevrons meaning "history" in one
    /// state and "match" in the other is exactly the sort of thing nobody reports and everybody
    /// misreads.
    public var systemImage: String { self == .previous ? "chevron.up" : "chevron.down" }

    /// The tooltip's sentence and the accessibility label.
    public var label: String { self == .previous ? "Previous match" : "Next match" }

    /// The keyboard equivalent the tooltip advertises.
    public var chord: String { self == .previous ? "⇧↩" : "↩" }
}
