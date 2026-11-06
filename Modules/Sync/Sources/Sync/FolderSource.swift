import Foundation

/// A plain folder the user added as a source, as persisted. Its own record, not a `CloudProvider`:
/// cloud providers are discovered from `~/Library/CloudStorage` each launch, while a folder source
/// exists only because the user added it, so the list itself is stored.
/// `SettingsManager.mapProviders` turns each into a `CloudProvider`, listed after the discovered
/// ones.
///
/// The app isn't sandboxed, so a path is just a path, with no security-scoped bookmark to keep.
public struct FolderSource: Codable, Equatable, Sendable, Identifiable {
    /// Provider id, unique and stable across renames and path edits. Prefixed so it never collides
    /// with a discovered account's id (a CloudStorage folder name, or `iCloud`) and is recognisable
    /// from the id alone, which the CLI shows and override keys are built from.
    public let id: String
    /// The absolute path, tilde-abbreviated inside the home directory (`~/Projects`) so the list
    /// survives the home directory moving. Expanded wherever it is used.
    public var path: String

    /// Prefix on every folder-source id. `:` can't appear in a CloudStorage folder name, so no
    /// discovered account's id starts with this.
    public static let idPrefix = "folder:"

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }

    /// A new source for `path`, with a fresh random id. Not derived from the path, or editing the
    /// Location would change the id and lose the name override and enabled state.
    /// `SettingsManager.addFolderSource` prevents duplicate paths.
    public static func new(path: String) -> FolderSource {
        FolderSource(id: idPrefix + UUID().uuidString, path: abbreviated(path))
    }

    /// Whether an id names a folder source.
    public static func isFolderSourceId(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// The name shown when the user hasn't renamed the source: the folder's own name, or "Home
    /// folder" for the home directory, whose own name is the account's and reads as a person.
    public var defaultDisplayName: String {
        Self.defaultDisplayName(forPath: path, volumeName: Self.volumeName(of:))
    }

    /// The rule, with the volume lookup injected so it stays pure and testable without a disk.
    /// Every path answers from its last component (`/Volumes/Backup` is "Backup") except `/`, which
    /// has none and takes the volume's name instead. A tab at a provider root wears this name
    /// (`PaneTab.displayName(providerName:)`), so `/` would show in tabs, headers, ⌘K and Settings.
    static func defaultDisplayName(forPath path: String, volumeName: (String) -> String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path {
            return "Home folder"
        }
        let name = (standardized as NSString).lastPathComponent
        guard name.isEmpty || name == "/" else { return name }
        // Still the path if the volume won't name itself: an unhelpful name beats a missing one.
        return volumeName(standardized).flatMap { $0.isEmpty ? nil : $0 } ?? standardized
    }

    /// What the filesystem calls the volume at `path`. Only asked for a path with no last component
    /// (in practice `/`): one cached resource read for the one source that needs it.
    static func volumeName(of path: String) -> String? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    /// `path` with the home directory folded back to `~`. Standardized and resolved first, because
    /// `abbreviatingWithTildeInPath` alone misses trailing slashes, `..` and the
    /// `/System/Volumes/Data/Users/…` firmlink spelling NSOpenPanel can return.
    public static func abbreviated(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return (standardized as NSString).abbreviatingWithTildeInPath
    }

    /// Two paths naming the same folder. Case-folded, because the default macOS volume is
    /// case-insensitive: `~/projects` beside `~/Projects` would be a second row for one folder.
    public static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        }
        return key(lhs) == key(rhs)
    }
}

extension FolderSource {

    /// Where a path moves to when the volume under it is renamed, or nil when it isn't on that
    /// volume. Renaming a card in Finder moves its mount point (`/Volumes/NO NAME` becomes
    /// `/Volumes/Camera SD`), and a source left on the old path would be dead for good.
    ///
    /// The mount point matches case-folded (`/Volumes` is on the case-insensitive boot volume), but
    /// the suffix keeps its spelling, since what is below may be case-sensitive. `/` is refused: the
    /// startup disk keeps its mount point, and a rewrite would repoint every source.
    ///
    /// **The cut is `old.count` Characters into the original string, matched on lowercased forms.**
    /// Safe because lowercasing keeps the Character count; it can change the scalar count
    /// (`İ`), so the same code over `unicodeScalars` would cut in the wrong place.
    ///
    /// - Returns: the new path, already ``abbreviated(_:)`` the way a stored path is spelled.
    public static func repathed(_ path: String,
                                whenVolumeMovedFrom oldVolume: String,
                                to newVolume: String) -> String? {
        let source = expandedAndTrimmed(path)
        let old = expandedAndTrimmed(oldVolume)
        let new = expandedAndTrimmed(newVolume)
        guard !new.isEmpty, new.lowercased() != old.lowercased(), isOnVolume(path, volume: oldVolume)
        else { return nil }
        return abbreviated(new + String(source.dropFirst(old.count)))
    }

    /// Whether a path lives on a given volume: equal to its mount point, or under it. Shared by the
    /// rename and eject rules. Case-folded (`/Volumes` is on the case-insensitive boot volume),
    /// matched on a component boundary so `/Volumes/CARD 2` isn't under `/Volumes/CARD`, and `/` is
    /// refused: the startup disk is never renamed away or unmounted, and would sweep up every source.
    public static func isOnVolume(_ path: String, volume: String) -> Bool {
        let source = expandedAndTrimmed(path).lowercased()
        let mount = expandedAndTrimmed(volume).lowercased()
        guard !mount.isEmpty, mount != "/" else { return false }
        return source == mount || source.hasPrefix(mount + "/")
    }

    /// The sources that go away when a volume is unmounted, in list order. Its own member so
    /// ``isOnVolume(_:volume:)``'s boundary rule decides, not a caller's `hasPrefix`.
    public static func idsOnVolume(_ volume: String, in sources: [FolderSource]) -> [String] {
        sources.filter { isOnVolume($0.path, volume: volume) }.map(\.id)
    }

    /// The folder-source list after the volume at `oldVolume` was renamed to `newVolume`. One folder
    /// still gets one row, so this is a list operation, not a `map`: if the user already re-added the
    /// volume under its new name, the stale source is removed instead of moved, and the one they
    /// added survives with whatever they have done to it. Only folder sources can be on a removable
    /// volume; discovered accounts live under `~/Library/CloudStorage`.
    ///
    /// - Returns: the new list, plus the ids that moved and the ids that were absorbed into an
    ///   existing source; the caller cleans up its per-id keys for the second group.
    public static func following(volumeRenameFrom oldVolume: String, to newVolume: String,
                                 in sources: [FolderSource])
        -> (sources: [FolderSource], moved: [String], absorbed: [String]) {
        var out: [FolderSource] = []
        var moved: [String] = []
        var absorbed: [String] = []
        for source in sources {
            guard let newPath = repathed(source.path, whenVolumeMovedFrom: oldVolume, to: newVolume),
                  newPath != source.path else {
                out.append(source)
                continue
            }
            // Checked only against sources that aren't moving: the rewrite is a prefix swap, so
            // two moving sources can't collide. One already at the destination was added under
            // the new name, so it is in this set.
            let stationary = sources.filter {
                $0.id != source.id
                    && repathed($0.path, whenVolumeMovedFrom: oldVolume, to: newVolume) == nil
            }
            if stationary.contains(where: { sameFolder($0.path, newPath) }) {
                absorbed.append(source.id)
                continue
            }
            var updated = source
            updated.path = newPath
            out.append(updated)
            moved.append(source.id)
        }
        return (out, moved, absorbed)
    }

    /// A tilde-expanded path with trailing slashes removed, keeping a bare `/`: the spelling the
    /// volume comparisons use. Not `abbreviated`, which resolves symlinks: the old mount point is
    /// already gone, so resolving it is a wasted `stat` per source.
    private static func expandedAndTrimmed(_ path: String) -> String {
        var out = (path as NSString).expandingTildeInPath
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
