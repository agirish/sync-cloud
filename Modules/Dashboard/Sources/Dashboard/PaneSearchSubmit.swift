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
/// match*, so on any query that happens to name someone (`aditi` matches twelve real filenames
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
