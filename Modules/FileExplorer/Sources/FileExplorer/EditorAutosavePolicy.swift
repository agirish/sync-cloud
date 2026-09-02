import Foundation
import Events

/// Which files the editor is allowed to write without being asked.
///
/// **On for everything, off for the files you say, and forgotten when the app quits.** Autosave
/// took away the oldest safety net on the platform — the one where you close a document, are asked,
/// and answer "Don't Save" — because there is nothing to ask when every keystroke is already on
/// disk. This is that net, put back per file and only where somebody wants it: switch it off before
/// an experiment, and the file stops being written until you press ⌘S or answer the question on the
/// way out.
///
/// **Session-only, and that is a decision rather than an omission.** Nothing here is persisted, so
/// quitting restores autosave everywhere. The surprise that buys — coming back tomorrow to a file
/// you had switched off, now writing again — points toward safety, which is the direction a
/// surprise should point; a persisted list of files that silently do not save points the other way,
/// and would be invisible until it cost something. A file closed and reopened *within* the session
/// keeps its setting, because the set is keyed by path and nothing clears it.
///
/// **A reference type held by the app**, like ``EditorDocument`` and for the same reason: closing
/// the window rebuilds `ContentView` and everything it owns, and a set that died with the window
/// would switch autosave back on for a document still open in it.
@MainActor
public final class EditorAutosavePolicy: ObservableObject {

    public init() {}

    /// The paths autosave will not write. Published, because the header's switch, the dot and the
    /// debounce all read it and have to change together.
    @Published private var suspended: Set<String> = []

    /// Whether autosave may write this document.
    ///
    /// **`nil` answers `true`.** No document is open, so nothing is being withheld — and a caller
    /// that treated "nothing open" as "autosave is off" would put the header's switch in the wrong
    /// position the moment the editor was empty.
    public func isOn(_ path: String?) -> Bool {
        guard let path else { return true }
        return !suspended.contains(path)
    }

    public func setOn(_ on: Bool, for path: String) {
        if on { suspended.remove(path) } else { suspended.insert(path) }
    }

    /// Flips one file, and answers where it landed.
    @discardableResult
    public func toggle(_ path: String) -> Bool {
        let next = !isOn(path)
        setOn(next, for: path)
        // **Logged, because this decides whether somebody's typing reaches disk.** Every other
        // event of that weight in the editor leaves a line — opened, reloaded, could not save — and
        // a log that recorded a file going unwritten without recording that it had been ASKED to go
        // unwritten would read like a defect rather than a decision.
        Logger.shared.info("Autosave \(next ? "on" : "off") for \((path as NSString).lastPathComponent)")
        return next
    }

    /// How many files are currently off. For tests and for the log breadcrumb; nothing on screen
    /// counts them, because the only file whose setting matters is the one you are looking at.
    public var suspendedCount: Int { suspended.count }
}
