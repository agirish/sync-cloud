import Foundation

public struct CloudProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let imageName: String
    /// The source's root: the top of what it covers, and the base every root-relative path in the
    /// app (a pane's focus, a stored tab position, a pinned folder) is measured from.
    ///
    /// For a cloud account this is the account folder itself (`~/Library/CloudStorage/OneDrive-X`),
    /// not the `Documents` inside it, so everything beside `Documents` is reachable. Discovered,
    /// never edited: there is one true root per account. A folder source is its own root.
    ///
    /// iCloud's root is the iCloud Drive container, `~/Library/Mobile Documents/com~apple~CloudDocs`,
    /// and it lands at `Documents`. With Desktop & Documents syncing on, macOS keeps the real trees
    /// at `~/Documents` and `~/Desktop` and leaves hidden symlinks by those names in the container.
    /// `PathBoundary.LinkedFolders` lists them as the real folders, and root-relative paths compose
    /// through the link: `Documents/Family` here is `~/Documents/Family`, as stored paths spell it.
    /// On a Mac without those links, builds 5.3 through 7.0 kept the source at `~/Documents` with a
    /// `root_override_`.
    public var rootPath: String
    /// The folder panes open at by default, **relative to `rootPath`**; `""` is the root itself.
    ///
    /// Separate from the root: the root is where the source *ends* (how far navigation, scanning and
    /// coverage may reach); this is only where a pane *starts*, which the user can leave by a
    /// breadcrumb.
    public var openAt: String
    public let type: ProviderType

    /// Where a pane on this source opens: `rootPath` with `openAt` applied.
    ///
    /// Composed, not stored, so the two halves can't disagree. `PathBoundary.join` carries the
    /// leading-slash rule (why an absolute `openAt` yields the root).
    public var landingPath: String {
        PathBoundary.join(root: rootPath, relative: openAt)
    }

    public init(id: String, displayName: String, imageName: String,
                rootPath: String, openAt: String = "", type: ProviderType) {
        self.id = id
        self.displayName = displayName
        self.imageName = imageName
        self.rootPath = rootPath
        self.openAt = openAt
        self.type = type
    }

    public enum ProviderType: String, Sendable {
        case iCloud = "iCloud"
        case oneDrive = "OneDrive"
        case dropBox = "Dropbox"
        case googleDrive = "Google Drive"
        /// A plain folder the user added as a source, with no account or cloud behind it. Everything
        /// downstream treats it like any other source; the case exists for the two type-gated
        /// places: name rules (a local volume accepts what it accepts, `ProviderNameRules.violation`)
        /// and the Google Drive date-noise filter, which never fires for it.
        case localFolder = "Folder"
    }

    /// Whether this source is a plain folder rather than a cloud account.
    public var isLocalFolder: Bool { type == .localFolder }

    /// The ruleset a name should be judged against for a source of `type`.
    ///
    /// Every type but `.localFolder` answers for itself. A folder has no rules of its own, so
    /// judging against it would give an empty all-clear. The useful question is "would this survive
    /// being put somewhere?", and `folderRule` is the user's answer (Settings ▸ Sources, default
    /// `.oneDrive`, the strictest). `.localFolder` as `folderRule` means "don't check".
    public static func nameRuleType(
        for type: ProviderType,
        folderRule: ProviderType
    ) -> ProviderType {
        type == .localFolder ? folderRule : type
    }

    /// The provider type governing a bare filesystem path, inferred from the discovered providers
    /// whose roots contain it; nil when none claims it.
    ///
    /// The CLI's `-L`/`-R` take a provider id or a plain path, and a path has no provider identity.
    /// But the key destination guards are type-gated
    /// (`ProviderNameRules.violation(inRelativePath:for:)` and the Google Drive date-noise filter),
    /// so without this the same OneDrive folder would skip `CON.txt` when addressed by id and copy
    /// it when addressed by path.
    ///
    /// A provider claims its root and what's inside, and anything inside the CloudStorage account
    /// folder its root sits under (`…/OneDrive-X/Photos` beside a `…/OneDrive-X/Documents` root).
    /// The longest matching root wins. Matching folds case, the safe direction: a wrong claim costs
    /// a skipped file the user is told about, a missed one an unsyncable file they aren't.
    public static func inferredType(forPath path: String, among providers: [CloudProvider]) -> ProviderType? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        var best: (rootLength: Int, type: ProviderType)?
        for provider in providers {
            for root in claimRoots(of: provider) {
                let base = URL(fileURLWithPath: root).standardizedFileURL.path.lowercased()
                guard PathBoundary.contains(target, under: base) else { continue }
                if base.count > (best?.rootLength ?? -1) {
                    best = (base.count, provider.type)
                }
            }
        }
        return best?.type
    }

    /// The roots a provider claims: its own (possibly user-overridden) root, plus the CloudStorage
    /// account folder that root sits under, when there is one.
    private static func claimRoots(of provider: CloudProvider) -> [String] {
        // A folder source claims nothing. A claim carries a provider's stricter rules onto a path,
        // and `.localFolder` has none, so its claim could only remove a guard: a folder source
        // inside a Dropbox root would win the longest-root rule, and a CLI copy into it would stop
        // skipping names Dropbox can't store. Unclaimed, the CLI falls back to `.iCloud`'s empty
        // rule set.
        guard !provider.isLocalFolder else { return [] }
        let components = URL(fileURLWithPath: provider.rootPath).standardizedFileURL.pathComponents
        // A provider's Location can be any folder, and a claim decides whether files are silently
        // skipped. A provider pointed at the home folder must not give every local folder
        // OneDrive's reserved-name rules. The test is whether the root contains the home folder,
        // not its depth, so `/Volumes/<mount>`, an ordinary Location, still claims its own tree.
        guard !isHomeOrAbove(components) else { return [] }
        var roots = [provider.rootPath]
        // Widen to the CloudStorage account folder. A discovered root already is that folder; this
        // is for a Location override below it (`…/OneDrive-X/Documents`). Anchored on the last
        // `Library/CloudStorage` pair, so a folder merely named "CloudStorage" claims nothing.
        for index in components.indices.dropLast().reversed()
        where components[index] == "Library" && components[index + 1] == "CloudStorage" {
            let accountIndex = index + 2
            guard accountIndex < components.count else { break }
            roots.append(NSString.path(withComponents: Array(components[0...accountIndex])))
            break
        }
        return roots
    }

    /// Whether these path components name a user's home directory or something above it: roots a
    /// provider must never claim, since that would type every unrelated local folder beneath.
    /// Structural, so it holds for any account and for test fixtures like `/Users/u`; the real home
    /// is checked too, for firmlinked spellings. `/Volumes/<mount>` does not match: an external
    /// volume's root is a legitimate Location.
    private static func isHomeOrAbove(_ components: [String]) -> Bool {
        // "/", "/Users", "/Volumes": a root this broad is never a provider folder.
        if components.count <= 2 { return true }
        // "/Users/<someone>": a home directory. `/Volumes/<mount>` has the same depth and is fine.
        if components.count == 3, components[1] == "Users" { return true }
        let path = NSString.path(withComponents: components)
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return PathBoundary.contains(home, under: path)
    }
}
