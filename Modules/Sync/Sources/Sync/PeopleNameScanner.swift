import Events
import Foundation

/// Reads the filenames inside each person's folders so ``PersonNameLearning`` has something to
/// learn from.
///
/// The only part that touches a disk: the learning rule is pure over `folder → filenames`, so it
/// tests without a staged tree, and the caller decides when to pay for this I/O. A real tree is
/// ~430 shallow listings, so the People section asks for it rather than running it on appear.
public enum PeopleNameScanner {

    /// Lists the immediate files of every folder the profile records as somebody's.
    ///
    /// `root` is the provider root the profile's relative paths hang off. Unreadable folders are
    /// skipped rather than failing the sweep: an evicted iCloud folder is an ordinary state.
    ///
    /// Lists through the shared `listing(of:)`, which has a deadline. Listing an evicted folder
    /// asks the cloud app, and with that app not running a bare `contentsOfDirectory` never
    /// returns, holding its thread for good. With the deadline the folder is skipped as unreadable.
    public static func fileNames(registry: PersonRegistry, profile: FolderProfile, root: URL,
                                 fileManager: FileManaging = FileManager.default) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for relative in PersonNameLearning.personFolders(registry: registry, profile: profile) {
            let url = root.appendingPathComponent(relative)
            let listing = fileManager.listing(of: url)
            guard listing.outcome != .unreadable else { continue }
            let names = listing.urls.map(\.lastPathComponent)
            // Files only: a subfolder's name is not a document's name, and counting it would let a
            // folder called "Granny Elder" vouch for itself.
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
