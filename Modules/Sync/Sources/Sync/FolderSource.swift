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
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path {
            return "Home folder"
        }
        let name = (standardized as NSString).lastPathComponent
        // A volume root ("/Volumes/Backup") has a real last component; "/" does not.
        return name.isEmpty || name == "/" ? standardized : name
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
