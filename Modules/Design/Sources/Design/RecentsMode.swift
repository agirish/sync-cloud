import Foundation

/// What the sidebar's Recents heading lists; its icon cycles through these.
///
/// The raw value is the heading's text and the stored setting, so an unknown stored value falls
/// back to plain Recents rather than to a list this build can't draw.
public enum RecentsMode: String, CaseIterable, Sendable {
    /// Every folder you were last in, newest first.
    case recents = "Recents"
    /// Folders stayed in on two or more different days, newest first.
    case revisited = "Revisited"
    /// Folders stayed in most, by faded count of stays.
    case frequent = "Frequent"

    /// The mode one click of the heading's icon moves to: Recents → Revisited → Frequent → Recents.
    public var next: RecentsMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
