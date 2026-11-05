import Foundation

/// Help topics a Settings surface points at.
///
/// Public for the same reason as `OrganizeHelpTopics`: `HelpBook` lives in the app target, which
/// this module can't see, so a test in `SyncCloudTests` checks that each id names a real article.
/// A broken pointer doesn't throw or log; the book just opens at its cover. A named constant
/// rather than an inline literal, so that test has something to assert about.
public enum SettingsHelpTopics {
    /// *Reading your documents*: what the on-device readers open, how much of each file they read,
    /// what is kept afterwards, and why none of it reaches anyone. Pointed at from Intelligence ▸
    /// On-device, beside "Read file contents on-device", the one control whose subject is privacy.
    public static let onDeviceReading = "on-device-reading"
}
