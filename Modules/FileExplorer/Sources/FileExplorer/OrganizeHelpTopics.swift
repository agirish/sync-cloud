import Foundation

/// Help topics an Organize surface points at.
///
/// **Public because the check that matters lives in another module.** The lens names a topic and
/// `HelpBook` owns the topics; nothing but a test joins the two, and that test is in the app
/// target because that is where the book is. A private constant here would leave the pointer
/// unverifiable and a broken one silently opens the book at its front — the reader asked for a
/// page and got the cover.
public enum OrganizeHelpTopics {
    /// *What Restructure finds* — the page explaining the findings, how a plan is reviewed, and
    /// why taking a landing back is not ⌘Z.
    public static let restructure = "restructure-shapes"

    /// *Reading your documents* — what the on-device readers open, how much of each file they read,
    /// what is kept, and why none of it reaches anyone.
    ///
    /// **The same string `SettingsHelpTopics.onDeviceReading` holds**, and deliberately not shared
    /// between them: this module and `Settings` cannot see each other, and neither can see the
    /// book. Two constants naming one article is the shape that already exists here; the app
    /// target's tests are what hold all three together.
    public static let onDeviceReading = "on-device-reading"
}
