import Foundation

/// Help topics an Organize surface points at.
///
/// Public because the check that matters lives in another module: the lens names a topic,
/// `HelpBook` owns the topics, and only a test in the app target joins the two. A broken pointer
/// opens the book at its front instead of the page asked for.
public enum OrganizeHelpTopics {
    /// *What Restructure finds* — the page explaining the findings, how a plan is reviewed, and
    /// why taking a landing back is not ⌘Z.
    public static let restructure = "restructure-shapes"

    /// *Reading your documents* — what the on-device readers open, how much of each file they read,
    /// what is kept, and why none of it reaches anyone.
    ///
    /// The same string `SettingsHelpTopics.onDeviceReading` holds, kept separate because this
    /// module and `Settings` can't see each other and neither can see the book. The app target's
    /// tests hold all three together.
    public static let onDeviceReading = "on-device-reading"
}
