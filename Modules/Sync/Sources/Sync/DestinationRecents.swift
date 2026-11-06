import Foundation

/// The handful of folders you actually file into, remembered per provider.
///
/// Filing is repetitive, so the picker remembers where you filed instead of making you re-navigate
/// the same columns. Five entries: a shortcut list, not a history.
///
/// One defaults key holding a root → destinations dictionary, not a key per provider. **Never
/// derive a key from `String.hashValue`**: Swift seeds it per process, so the list would be written
/// every launch and never read back.
public enum DestinationRecents {

    /// How many destinations are kept per provider.
    public static let limit = 5

    /// The single defaults key holding every provider's list.
    public static let defaultsKey = "destinationRecentsByProvider"

    /// The remembered destinations for one provider, most recent first, with any that no longer
    /// resolve to a directory dropped.
    ///
    /// Pruned on read: folders vanish behind the app's back (another Mac, the provider's web UI,
    /// Finder), and offering one would hand the picker a destination the transfer then refuses.
    public static func load(
        providerRoot: String,
        in defaults: UserDefaults = .standard,
        fileManager: FileManaging = FileManager.default
    ) -> [String] {
        let root = PaneBrowsePath.normalized(providerRoot)
        guard !root.isEmpty else { return [] }
        let stored = (defaults.dictionary(forKey: defaultsKey) as? [String: [String]])?[root] ?? []
        return stored.filter { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Records a destination as the most recent, de-duplicating and trimming to `limit`.
    ///
    /// Removes before inserting, so re-filing into the folder you just used keeps it at the top.
    public static func record(
        _ path: String,
        providerRoot: String,
        in defaults: UserDefaults = .standard,
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders
    ) {
        let destination = PaneBrowsePath.normalized(path)
        let root = PaneBrowsePath.normalized(providerRoot)
        guard !destination.isEmpty, !root.isEmpty else { return }
        // Only destinations inside the provider; the system-panel escape can land anywhere.
        // `PathBoundary`, not a prefix test: a folder the root links in from outside (iCloud
        // Drive's `~/Documents`) is inside the provider without being a string prefix of it.
        guard PathBoundary.contains(destination, under: root, links: links) else { return }

        var all = (defaults.dictionary(forKey: defaultsKey) as? [String: [String]]) ?? [:]
        var list = all[root] ?? []
        list.removeAll { $0 == destination }
        list.insert(destination, at: 0)
        all[root] = Array(list.prefix(limit))
        defaults.set(all, forKey: defaultsKey)
    }
}
