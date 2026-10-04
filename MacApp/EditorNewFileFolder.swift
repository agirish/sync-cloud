import Foundation

/// **Where ⌘N makes a file when the pane's folder is no place for one: `~/Documents/Notes`.**
///
/// ⌘N makes its file in the folder the left pane shows (see `editorFolder`), and that folder can be
/// one nobody means to put a note in: the top of the disk on a whole-disk source, `/Applications`,
/// `~/Library`, the top of the home folder — or none at all, with no source set up. Asked
/// 2026-10-03: those go to `~/Documents/Notes` instead, made on first use, and the pane is taken
/// there as ⌘N is pressed, so the name is typed in the folder it will land in.
///
/// **Two halves, because one of them reads the disk.** ``pathRefusal(of:home:)`` decides on the
/// spelling alone and is safe in a view body — the ＋'s tooltip asks it on every pass.
/// ``refusal(of:home:isWritable:)`` adds whether the folder can be written to, an `access(2)` that
/// can wait on a slow volume, so it is asked only when ⌘N is pressed and when the file is made.
///
/// **A list, not a writability test.** `/Applications` is group-writable for an admin, so "can I
/// write here" alone would let a note land among the apps.
enum EditorNewFileFolder {

    /// Why the pane's folder is no place for a new file.
    enum Refusal: Equatable {
        /// There is no folder: no source is set up, so the pane has no path.
        case noFolder
        /// The system's: anything on the disk outside `/Users` and `/Volumes`, those two folders
        /// themselves, and `~/Library` but for the cloud folders inside it.
        case system
        /// The top of the home folder — it holds Desktop, Documents and the rest, not files.
        case homeTop
        /// A Trash — the user's, an iCloud Drive's, or a volume's.
        case trash
        /// A folder that can't be written to, or one that is no longer there.
        case notWritable

        /// The reason, for the log line that says why the file went to Notes.
        func why(_ folder: String) -> String {
            switch self {
            case .noFolder: return "There is no folder in the file pane"
            case .system: return "\(folder) is a system folder"
            case .homeTop: return "\(folder) is the top of the home folder"
            case .trash: return "\(folder) is in the Trash"
            case .notWritable: return "\(folder) can't be written to"
            }
        }
    }

    /// What the ＋'s tooltip and the naming row call the fallback.
    static let notesName = "Notes"

    /// `~/Documents/Notes`.
    static func notes(home: String) -> String {
        (home as NSString).appendingPathComponent("Documents/\(notesName)")
    }

    /// **The spelling half of the rule** — no disk read, so a body may ask it.
    ///
    /// Compared case-folded: the boot volume is case-insensitive, so `/applications` is the same
    /// folder. **The cloud folders under `~/Library` are allowed** — iCloud Drive and every app's
    /// iCloud folder under `Mobile Documents`, and OneDrive, Google Drive and Dropbox under
    /// `CloudStorage` — each from its own top down, but not the two folders that hold them.
    static func pathRefusal(of folder: String, home: String) -> Refusal? {
        guard folder.hasPrefix("/") else { return .noFolder }
        let path = folded(folder)
        let components = path.split(separator: "/")
        if components.contains(".trash") || components.contains(".trashes") { return .trash }
        // An empty home would make `isWithin` claim every path, and `/Applications` with it.
        let home = folded(home)
        let hasHome = home.hasPrefix("/") && home != "/"
        if hasHome, path == home { return .homeTop }
        if hasHome, isWithin(path, home) {
            let library = home + "/library"
            guard isWithin(path, library) else { return nil }
            let clouds = ["mobile documents", "cloudstorage"].map { library + "/" + $0 + "/" }
            return clouds.contains { path.hasPrefix($0) } ? nil : .system
        }
        for parent in ["/users", "/volumes"] where isWithin(path, parent) {
            return path == parent ? .system : nil
        }
        return .system
    }

    /// The whole rule: the spelling, then whether the folder can be written to.
    static func refusal(of folder: String, home: String, isWritable: (String) -> Bool) -> Refusal? {
        if let refusal = pathRefusal(of: folder, home: home) { return refusal }
        return isWritable(folder) ? nil : .notWritable
    }

    /// Where the file goes: the pane's folder, or Notes with the reason the pane's was refused.
    static func destination(paneFolder: String, home: String,
                            isWritable: (String) -> Bool) -> (folder: String, refusal: Refusal?) {
        guard let refusal = refusal(of: paneFolder, home: home, isWritable: isWritable) else {
            return (paneFolder, nil)
        }
        return (notes(home: home), refusal)
    }

    /// Lower-cased, without a trailing slash (but `/` stays `/`).
    private static func folded(_ path: String) -> String {
        let lower = path.lowercased()
        return lower.count > 1 && lower.hasSuffix("/") ? String(lower.dropLast()) : lower
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
