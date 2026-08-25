import Foundation

/// A plain folder the user added as a source, as persisted.
///
/// Deliberately its own record rather than a `CloudProvider`: the cloud providers are *discovered*
/// (their identity and default root come from `~/Library/CloudStorage` on every launch, and the
/// only persisted parts are the user's overrides), while a folder source exists solely because the
/// user said so. It is the curated list, so it is what gets written to disk, and
/// `SettingsManager.mapProviders` turns each entry into a `CloudProvider` alongside the discovered
/// ones — after them, so the existing picker is visually untouched.
///
/// The app is **not sandboxed** (`codesign -d --entitlements` on the installed build shows only
/// `get-task-allow`), so a chosen path is just a path: no security-scoped bookmark to mint, stash,
/// or resolve-and-find-stale later. That is most of what would normally make this expensive, and it
/// is why this record is three strings.
public struct FolderSource: Codable, Equatable, Sendable, Identifiable {
    /// Provider id, unique and stable across renames and path edits. Prefixed so it can never
    /// collide with a discovered account's id (those are CloudStorage folder names — `Dropbox`,
    /// `OneDrive-Personal` — or the literal `iCloud`), and so a folder source is recognisable as
    /// one from the id alone, which is what the CLI shows and what override keys are built from.
    public let id: String
    /// The absolute path, tilde-abbreviated when it is inside the home directory (`~/Projects`), so
    /// the stored list survives the home directory itself moving — and reads as the user thinks of
    /// it. Expanded wherever it is used, exactly like the iCloud default path.
    public var path: String

    /// Prefix on every folder-source id. `:` cannot appear in a CloudStorage folder name, so no
    /// discovered account can ever produce an id that starts with this.
    public static let idPrefix = "folder:"

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }

    /// A new source for `path`, with a fresh id.
    ///
    /// The id is random rather than derived from the path: a path-derived id would change when the
    /// user edits the Location, taking the name override and enabled state with it — the source
    /// would silently become a different source. Duplicate paths are prevented by
    /// `SettingsManager.addFolderSource`, which looks the path up before minting anything.
    public static func new(path: String) -> FolderSource {
        FolderSource(id: idPrefix + UUID().uuidString, path: abbreviated(path))
    }

    /// Whether an id names a folder source.
    public static func isFolderSourceId(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// The name shown when the user hasn't renamed the source: the folder's own name, or
    /// "Home folder" for the home directory itself — whose last path component is the account's
    /// short name (`abhishek`), which reads as a person, not a place.
    public var defaultDisplayName: String {
        Self.defaultDisplayName(forPath: path, volumeName: Self.volumeName(of:))
    }

    /// The rule, with the one thing it cannot compute injected.
    ///
    /// **The startup disk is the case this exists for.** Every other path answers from its own last
    /// component — `/Volumes/Backup` is "Backup" — but `/` has no last component, and the fallback
    /// was the path itself. That is what a source over the startup disk was called: `/`. It reached
    /// further than the sidebar row that produced it, because a tab sitting at a provider root
    /// wears the *source's* name (`PaneTab.displayName(providerName:)`), so the tab strip, the pane
    /// header capsule, ⌘K and Settings all read `/` too.
    ///
    /// `volumeName` is injected rather than read here so the rule is testable without a disk, and
    /// so this stays a pure function — the same reason `FolderJumpStore.reachable` takes its
    /// `isDirectory`.
    static func defaultDisplayName(forPath path: String, volumeName: (String) -> String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path {
            return "Home folder"
        }
        let name = (standardized as NSString).lastPathComponent
        guard name.isEmpty || name == "/" else { return name }
        // Still the path if the volume will not name itself — a name that is merely unhelpful beats
        // one that is missing, and this is the shape the app had before the volume lookup existed.
        return volumeName(standardized).flatMap { $0.isEmpty ? nil : $0 } ?? standardized
    }

    /// What the filesystem calls the volume at `path`.
    ///
    /// Only ever consulted for a path with no last component — in practice `/` — so this is one
    /// resource read per source at discovery, on the one source that needs it, against a value the
    /// OS keeps cached.
    static func volumeName(of path: String) -> String? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    /// `path` with the home directory folded back to `~`. `NSString.abbreviatingWithTildeInPath`
    /// alone is not enough: it leaves a trailing-slash or `..`-bearing path un-abbreviated, and
    /// NSOpenPanel hands back `/System/Volumes/Data/Users/…` firmlink spellings on some machines,
    /// which standardizing resolves first.
    public static func abbreviated(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return (standardized as NSString).abbreviatingWithTildeInPath
    }

    /// Two paths naming the same folder. Case-folded, because the default macOS volume is
    /// case-insensitive and the two spellings are one folder there — offering to add
    /// `~/projects` when `~/Projects` is already a source would create a second row for one folder.
    public static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        }
        return key(lhs) == key(rhs)
    }
}
