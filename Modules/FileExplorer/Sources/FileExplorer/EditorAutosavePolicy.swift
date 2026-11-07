import Foundation
import Events

/// Which files the editor may write without being asked: all of them, except the ones you switch
/// off, until the app quits.
///
/// Autosave removes the "Don't Save" safety net, since every keystroke is already on disk. This
/// puts it back per file: switch it off before an experiment, and the file isn't written until you
/// press ⌘S or answer the question on the way out.
///
/// Session-only on purpose: quitting restores autosave everywhere, a surprise that points toward
/// safety, where a persisted list of files that silently don't save would stay invisible until it
/// cost something. A file closed and reopened within the session keeps its setting (keyed by path).
/// A reference type held by the app, like ``EditorDocument``, so a rebuilt `ContentView` can't
/// switch autosave back on for a document still open.
@MainActor
public final class EditorAutosavePolicy: ObservableObject {

    public init() {}

    /// The paths autosave won't write. Published, because the header's switch, the dot and the
    /// debounce all read it and must change together.
    @Published private var suspended: Set<String> = []

    /// Whether autosave may write this document. `nil` answers `true`: nothing is open, so nothing
    /// is withheld, and answering "off" would show the header's switch wrong when the editor is
    /// empty.
    public func isOn(_ path: String?) -> Bool {
        guard let path else { return true }
        return !suspended.contains(path)
    }

    public func setOn(_ on: Bool, for path: String) {
        if on { suspended.remove(path) } else { suspended.insert(path) }
    }

    /// A file switched off stays off when Finder, Organize or another device renames or moves it
    /// and the editor follows. The set is keyed by path, so without this the switch would quietly
    /// come back on at the new name.
    public func move(from old: String, to new: String) {
        guard old != new, suspended.contains(old) else { return }
        suspended.remove(old)
        suspended.insert(new)
    }

    /// Flips one file, and answers where it landed.
    @discardableResult
    public func toggle(_ path: String) -> Bool {
        let next = !isOn(path)
        setOn(next, for: path)
        // Logged, because this decides whether somebody's typing reaches disk; without it, a file
        // going unwritten would read in the log like a defect rather than a choice.
        Logger.shared.info("Autosave \(next ? "on" : "off") for \((path as NSString).lastPathComponent)")
        return next
    }

    /// How many files are off, for tests and the log. Nothing on screen counts them: only the open
    /// file's setting matters.
    public var suspendedCount: Int { suspended.count }
}
