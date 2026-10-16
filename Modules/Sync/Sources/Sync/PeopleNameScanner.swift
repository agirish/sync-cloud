import Events
import Foundation

/// Reads the filenames inside each person's folders so ``PersonNameLearning`` has something to
/// learn from.
///
/// **A separate type because it is the only part that touches a disk.** The rule itself is pure
/// over `folder → filenames`, which is what makes it testable without staging a tree; this is the
/// I/O, kept where a caller can decide when to pay for it. On the surveyed tree that is ~430
/// shallow directory listings — fast, but not something to do on every keystroke, which is why the
/// People section asks for it rather than doing it on appear.
public enum PeopleNameScanner {

    /// Lists the immediate files of every folder the profile records as somebody's.
    ///
    /// `root` is the provider root the profile's relative paths hang off. Unreadable folders are
    /// skipped rather than failing the sweep: a person's folder living on an evicted iCloud path is
    /// an ordinary state, and one of them must not cost the other four hundred.
    ///
    /// **Through the shared `listing(of:)`, because an evicted folder is exactly what it guards.**
    /// Its contents are not on this Mac, so listing it asks the cloud app for them — and when that
    /// app is not running, the bare `contentsOfDirectory` this used to call never returned: the
    /// sweep stopped for good at that folder, holding the thread it ran on, one more per click on
    /// Look for Names. Now the folder costs at most the reads' deadline, once, and is skipped like
    /// any other folder that cannot be read.
    public static func fileNames(registry: PersonRegistry, profile: FolderProfile, root: URL,
                                 fileManager: FileManaging = FileManager.default) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for relative in PersonNameLearning.personFolders(registry: registry, profile: profile) {
            let url = root.appendingPathComponent(relative)
            let listing = fileManager.listing(of: url)
            guard listing.outcome != .unreadable else { continue }
            let names = listing.urls.map(\.lastPathComponent)
            // Directory entries only — a subfolder's NAME is not a document's name, and including
            // it would let a folder called "Granny Elder" vouch for itself.
            let files = names.filter { name in
                var isDirectory: ObjCBool = false
                let child = url.appendingPathComponent(name).path
                guard fileManager.fileExists(atPath: child, isDirectory: &isDirectory) else { return false }
                return !isDirectory.boolValue && !name.hasPrefix(".")
            }
            if !files.isEmpty { out[relative] = files }
        }
        return out
    }

    /// The whole sweep: read, then learn.
    public static func suggestions(registry: PersonRegistry, profile: FolderProfile, root: URL,
                                   dismissed: Set<String>,
                                   fileManager: FileManaging = FileManager.default) -> [PersonNameSuggestion] {
        let names = fileNames(registry: registry, profile: profile, root: root,
                              fileManager: fileManager)
        let found = PersonNameLearning.suggestions(registry: registry, profile: profile,
                                                   fileNames: names, dismissed: dismissed)
        Logger.shared.info("People: read \(names.count) person folder(s) — "
                           + "\(found.count) name suggestion(s)")
        return found
    }
}
