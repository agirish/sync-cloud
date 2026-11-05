import SwiftUI

/// The one severity/semantic color table. Views that paint a meaning (success, a warning, a
/// failure, an informational note, a file moved) take the color from here, so one meaning can't
/// wear different colors in different corners of the app.
///
/// `move` is purple so it collides neither with warning orange nor with the app accent; copies
/// read as plain success.
public enum SemanticColor {
    /// An operation completed, a copy landed, a path is valid.
    public static let success = Color.green
    /// Neutral, informational.
    public static let info = Color.blue
    /// Needs attention but nothing was lost.
    public static let warning = Color.orange
    /// Needs the user's judgment before anything happens: softer than `warning`, which flags
    /// something the app skipped or that went wrong on its own. Risky file names, duplicate groups
    /// that need a person and low-confidence matches wear this. A glyph may appear in both tiers;
    /// the tier carries the meaning, the glyph the topic.
    public static let caution = Color.yellow
    /// A failure, a delete, a conflict.
    public static let error = Color.red
    /// A file changed location (distinct from warning-orange and the app accent).
    public static let move = Color.purple
    /// No severity at all: a diagnostic or trace entry, present for completeness rather than
    /// because anything happened. A member, not a literal `Color.gray` at the call site, so
    /// `SemanticInkContrastTests` measures it against the same contrast floor as the rest.
    public static let neutral = Color.gray

    /// Every member, as (name, colour): the one list. `SemanticInkContrastTests` measures from it,
    /// and `everySemanticColorMemberIsInTheAllList` source-scans this file to prove it is the whole
    /// set, since a list can't catch its own omissions.
    public static let all: [(name: String, color: Color)] = [
        ("success", success), ("info", info), ("warning", warning),
        ("caution", caution), ("error", error), ("move", move), ("neutral", neutral)
    ]
}
