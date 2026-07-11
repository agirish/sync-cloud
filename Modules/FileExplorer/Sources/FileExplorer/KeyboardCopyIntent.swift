import SwiftUI
import Sync

/// The normal Differences table's directional keyboard shortcuts, decided as a pure chord →
/// intent function so the wiring is unit-testable without a live view.
///
/// ⌘→ copies the selection to the right pane, ⌘← to the left; adding ⇧ turns the copy into a
/// move. Any chord WITHOUT ⌘ held — including a bare arrow, which the Table uses for row
/// navigation — yields `nil`, so the key handler returns `.ignored` and normal navigation is
/// untouched. ⌘ is always part of this chord, so the move flag comes from ⇧ alone here (unlike
/// the header buttons, whose move modifier is the app-wide ⇧-or-⌘ `ModifierTracker`).
enum KeyboardCopyIntent {
    /// The copy/move a key chord maps to, or `nil` when it isn't one of the four directional
    /// shortcuts (⌘ not held, or a non-arrow key).
    static func from(key: KeyEquivalent, modifiers: EventModifiers) -> (direction: FileDifference.SyncAction, isMove: Bool)? {
        guard modifiers.contains(.command) else { return nil }
        let direction: FileDifference.SyncAction
        // Compare the underlying character rather than the KeyEquivalent value directly, which
        // isn't Equatable across every SDK.
        if key.character == KeyEquivalent.rightArrow.character {
            direction = .copyToRight
        } else if key.character == KeyEquivalent.leftArrow.character {
            direction = .copyToLeft
        } else {
            return nil
        }
        return (direction, modifiers.contains(.shift))
    }
}
