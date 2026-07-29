import Foundation

/// The handful of folders you actually file into, remembered per provider.
///
/// Filing is repetitive — a small set of folders absorbs most of it — so a picker that remembers
/// nothing makes you re-navigate the same four columns every time. Five entries, because this is a
/// shortcut list and not a history: past that it stops being scannable, and the browse columns are
/// the better tool for anything further afield.
///
/// One defaults key holding a root → destinations dictionary, rather than a key per provider.
/// Deriving a key from the root would mean encoding a path into a key name, and the obvious way to
/// do that — hashing it — is a trap: Swift seeds `String.hashValue` per process, so the key would
/// differ on every launch and the list would appear to persist while never once being read back.
public enum DestinationRecents {

    /// How many destinations are kept per provider.
    public static let limit = 5

    /// The single defaults key holding every provider's list.
    public static let defaultsKey = "destinationRecentsByProvider"

    /// The remembered destinations for one provider, most recent first, with any that no longer
    /// resolve to a directory dropped.
    ///
    /// Pruning on *read* rather than on delete: folders disappear behind the app's back all the
    /// time — another Mac, the provider's web UI, the user's own Finder — and offering one that no
    /// longer exists would hand the picker a destination the transfer would then refuse. Read is
    /// also the only moment guaranteed to be on the picker's path.
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
    /// Removes before inserting rather than appending and de-duplicating afterwards, so re-filing
    /// into the folder you just used keeps it at the top instead of pushing it down.
    public static func record(
        _ path: String,
        providerRoot: String,
        in defaults: UserDefaults = .standard
    ) {
        let destination = PaneBrowsePath.normalized(path)
        let root = PaneBrowsePath.normalized(providerRoot)
        guard !destination.isEmpty, !root.isEmpty else { return }
        // Only remember destinations inside the provider. The system-panel escape can land
        // anywhere, and this is a per-provider shortcut list, not a bookmark store.
        guard destination == root || destination.hasPrefix(root + "/") else { return }

        var all = (defaults.dictionary(forKey: defaultsKey) as? [String: [String]]) ?? [:]
        var list = all[root] ?? []
        list.removeAll { $0 == destination }
        list.insert(destination, at: 0)
        all[root] = Array(list.prefix(limit))
        defaults.set(all, forKey: defaultsKey)
    }
}
