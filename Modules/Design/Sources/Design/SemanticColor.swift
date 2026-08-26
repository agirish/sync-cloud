import SwiftUI

/// The one severity/semantic color table (C3). Views that paint a *meaning* — an operation
/// succeeded, a warning, a failure, an informational note, a file moved — pull the color from
/// here so the same meaning can't wear different colors in different corners of the app.
///
/// `move` is deliberately purple: Sync History used to paint move = orange (colliding with
/// warning) and copy = accent (colliding with the app accent everywhere else), so moves now
/// get their own hue and copies read as plain success.
public enum SemanticColor {
    /// An operation completed, a copy landed, a path is valid.
    public static let success = Color.green
    /// Neutral, informational.
    public static let info = Color.blue
    /// Needs attention but nothing was lost.
    public static let warning = Color.orange
    /// Needs the user's *judgment* before anything happens — softer than `warning`, which flags
    /// something the app skipped or that went wrong on its own. Name-only duplicate groups,
    /// risky file names, and low-confidence matches wear this. The same glyph may appear in
    /// both tiers (a triangle can mean "skipped" in orange and "your call" in yellow); the
    /// TIER carries the meaning, the glyph carries the topic.
    public static let caution = Color.yellow
    /// A failure, a delete, a conflict.
    public static let error = Color.red
    /// A file changed location (distinct from warning-orange and the app accent).
    public static let move = Color.purple
    /// **No severity at all** — a diagnostic or trace entry, present for completeness rather than
    /// because anything happened.
    ///
    /// Added because the table was incomplete in a way only its one non-member could show. The
    /// Activity Log's level tint calls itself "the only place severity is turned into colour,
    /// drawn from the shared semantic table" and then returned a bare `Color.gray` for `.debug`,
    /// because there was nothing here to return. A literal at a call site is outside every
    /// guarantee this type exists to give: `SemanticInkContrastTests` measures the members against
    /// a contrast floor in both appearances, and `.gray` was measured by nothing.
    ///
    /// `Color.gray` is what it already rendered, kept deliberately: closing the table is the fix,
    /// and changing the colour in the same move would make it impossible to tell a contrast result
    /// from a redesign. It now clears the same floor as the rest, which is the point.
    public static let neutral = Color.gray

    /// Every member, as (name, colour) — the ONE list.
    ///
    /// `SemanticInkContrastTests` used to carry its own copy of the six, which is a registry
    /// beside a type: adding a member left the test measuring the old set and passing, and nothing
    /// anywhere said the two had drifted. The test reads this now, and
    /// `everySemanticColorMemberIsInTheAllList` source-scans this very file to prove the list is
    /// the whole set rather than most of it — the drift this replaces is exactly the kind a list
    /// cannot catch about itself.
    public static let all: [(name: String, color: Color)] = [
        ("success", success), ("info", info), ("warning", warning),
        ("caution", caution), ("error", error), ("move", move), ("neutral", neutral)
    ]
}
