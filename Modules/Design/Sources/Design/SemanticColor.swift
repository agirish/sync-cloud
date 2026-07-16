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
    /// A failure, a delete, a conflict.
    public static let error = Color.red
    /// A file changed location (distinct from warning-orange and the app accent).
    public static let move = Color.purple
}
