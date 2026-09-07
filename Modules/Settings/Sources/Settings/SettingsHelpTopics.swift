import Foundation

/// Help topics a Settings surface points at.
///
/// **The twin of `OrganizeHelpTopics`, and public for the identical reason.** `HelpBook` lives in
/// the app target; this module cannot see it, so nothing here can check that the id below names a
/// real article. The join is made by a test in `SyncCloudTests`, which can see both — and it has to
/// be, because a broken pointer does not throw or log: the book simply opens at its cover, and the
/// reader who asked a specific question gets the front page.
///
/// One constant, because there is one pointer. It stays a named type rather than a literal at the
/// call site so that the app-target test has something to assert *about* — a string spelled inline
/// in a view body is invisible to the module that owns the book.
public enum SettingsHelpTopics {
    /// *Reading your documents* — what the on-device readers open, how much of each file they read,
    /// what is kept afterwards, and why none of it reaches anyone.
    ///
    /// Pointed at from **Intelligence ▸ On-device**, beside "Read file contents on-device". That
    /// switch is the one control in Settings whose subject is entirely privacy, and until this it
    /// was also the one with the least to read.
    public static let onDeviceReading = "on-device-reading"
}
