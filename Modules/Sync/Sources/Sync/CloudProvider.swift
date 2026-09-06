import Foundation

public struct CloudProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let imageName: String
    /// The source's **root** — the top of what this source covers, and the base every root-relative
    /// path in the app (a pane's focus, a stored tab position, a pinned folder) is measured from.
    ///
    /// For a cloud account this is the account folder itself (`~/Library/CloudStorage/OneDrive-X`),
    /// not the `Documents` inside it: the account folder is where the account's content actually
    /// begins, and everything beside `Documents` — `Teams Recordings`, `TODO`, a shared library —
    /// was unreachable while the root sat one level down. Discovered, never edited: there is one
    /// true root per account, so an editable one is only a way to misconfigure it. A folder source
    /// is its own root.
    ///
    /// iCloud's root is the iCloud Drive container, `~/Library/Mobile Documents/com~apple~CloudDocs`
    /// — what Finder shows as "iCloud Drive" — and it lands at `Documents`. **It was rooted at
    /// `~/Documents` until v5.3**, deliberately: with Desktop & Documents syncing on, macOS keeps
    /// the real trees at `~/Documents` and `~/Desktop` and leaves **hidden symlinks** named
    /// `Desktop` and `Documents` in the container, and this app walked links as links — so the
    /// container showed two folders out of four, and everything the app had stored about a file
    /// in Documents was spelled `~/Documents/…`, which the container's root would not contain.
    /// Both are answered by `PathBoundary.LinkedFolders`: the walk lists the two links as the
    /// real folders they point at, and root-relative paths compose through the link's name to
    /// the real tree — `Documents/Family` on this source IS `~/Documents/Family`, spelled the way
    /// every stored absolute path already spells it. The old root survives as a `root_override_`
    /// only on a Mac whose iCloud Drive has no such link, where `~/Documents` is not in the cloud
    /// at all and moving that source would have moved a user's positions out from under them —
    /// see `RootsMigration.moveICloudRoot`.
    public var rootPath: String
    /// The folder panes open at by default, **relative to `rootPath`**; `""` is the root itself.
    ///
    /// Separate from the root because the two answer different questions. The root is where the
    /// source *ends* — how far up navigation, scanning and coverage may reach. This is merely where
    /// a pane *starts*, a convenience the user sets from inside the root and can leave at any time
    /// by clicking a breadcrumb. Conflating them is what made every source's breadcrumb read
    /// `Documents` and put a ceiling one level below the content.
    public var openAt: String
    public let type: ProviderType

    /// Where a pane on this source opens: `rootPath` with `openAt` applied.
    ///
    /// Composed rather than stored, so the two halves can never disagree. `PathBoundary.join`
    /// carries the leading-slash rule — see there for why an absolute `openAt` yields the root.
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
        /// A plain folder the user added as a source — no account, no cloud behind it. Everything
        /// downstream of `CloudProvider` (panes, the lens workspaces, the diff engine, undo, history, automations,
        /// the CLI) treats it exactly like any other source; the case exists so the two places that
        /// *are* type-gated can tell the difference: name rules (a local volume accepts what a local
        /// volume accepts, see `ProviderNameRules.violation`) and the Google Drive date-noise
        /// filter, which simply never fires.
        case localFolder = "Folder"
    }

    /// Whether this source is a plain folder rather than a cloud account.
    public var isLocalFolder: Bool { type == .localFolder }

    /// The ruleset a name should be judged against for a source of `type`.
    ///
    /// Every type but `.localFolder` answers for itself. A folder has no rules of its own — it
    /// stores whatever the volume stores — so judging names against it reports nothing, which over
    /// a folder full of names OneDrive would reject is an empty all-clear rather than an answer.
    /// The useful question about a folder is *"would this survive being put on <somewhere>?"*, and
    /// only the user knows where; `folderRule` is their standing answer (Settings ▸ Sources,
    /// default `.oneDrive`, the strictest). Passing `.localFolder` as `folderRule` means "don't
    /// check", and this becomes the identity.
    public static func nameRuleType(
        for type: ProviderType,
        folderRule: ProviderType
    ) -> ProviderType {
        type == .localFolder ? folderRule : type
    }

    /// The provider type governing a bare filesystem path, inferred from the discovered providers
    /// whose roots contain it — nil when no provider claims it.
    ///
    /// The CLI accepts a `-L`/`-R` value as either a provider id or a plain path, and a path
    /// carries no provider identity of its own. But the destination guards that matter most are
    /// type-gated: `ProviderNameRules.violation(inRelativePath:for:)` refuses to write names the
    /// target provider cannot store, and the Google Drive date-noise filter keys off
    /// `.googleDrive`. Typing every path-addressed root as one fixed provider silently disables
    /// both for exactly the folders that need them — the same OneDrive folder would skip `CON.txt`
    /// when addressed by id and copy it when addressed by path.
    ///
    /// A provider claims the path when the path is its root or inside it, or inside the
    /// CloudStorage account folder its root sits under: `~/Library/CloudStorage/OneDrive-X/Photos`
    /// belongs to the same OneDrive account as the discovered `.../OneDrive-X/Documents` root even
    /// though it is a sibling of it, not a descendant. The longest matching root wins, so a
    /// provider nested inside another resolves to the more specific one.
    ///
    /// Matching folds case: on the default case-insensitive macOS volume the two spellings name
    /// one folder, and claiming is the safe direction — a wrong claim costs a skipped file the
    /// user is told about, a missed one costs an unsyncable file they are not.
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
    /// account folder that root sits under, when it has one. A provider whose path was overridden
    /// to somewhere outside CloudStorage contributes only its own root, which is the whole of what
    /// is known about it.
    private static func claimRoots(of provider: CloudProvider) -> [String] {
        // A folder source claims nothing, at any depth. A claim exists to carry a provider's
        // *stricter* rules onto a path that has no identity of its own, and `.localFolder` has no
        // rules to carry — so letting one claim can only ever REMOVE a guard. Concretely: a folder
        // source added inside a Dropbox root would win `inferredType`'s longest-root-wins rule and
        // type that subtree `.localFolder`, and a path-addressed CLI copy into it would stop
        // skipping the trailing-space names Dropbox cannot store. Claiming nothing leaves the
        // cloud truth underneath intact, and a path under a standalone folder source resolves
        // exactly as it did before folder sources existed (nothing claims it; the CLI falls back
        // to `.iCloud`'s empty rule set).
        guard !provider.isLocalFolder else { return [] }
        let components = URL(fileURLWithPath: provider.rootPath).standardizedFileURL.pathComponents
        // A provider's Location is user-settable to ANY folder, and a claim is not a harmless label:
        // it decides whether a path-addressed CLI root inherits that provider's name rules, which
        // decides whether files are silently skipped. Someone who points a provider at their home
        // folder must not thereby give every local folder OneDrive's reserved-name rules.
        //
        // The test is what the root CONTAINS, not how deep it is. A depth rule (`count > 3`) was
        // both too broad and too narrow: it also silenced `/Volumes/<mount>` — a perfectly ordinary
        // provider Location, and the shape Google Drive itself used to mount at — so that provider
        // stopped claiming even its OWN tree, and a path-addressed CLI root inside it fell back to
        // `.iCloud`'s empty rule set, losing exactly the name guard and date-noise filter the claim
        // exists to carry. Meanwhile it let `~/Documents` through, which swallows just as much
        // local ground as `~` does.
        guard !isHomeOrAbove(components) else { return [] }
        var roots = [provider.rootPath]
        // Widen to the CloudStorage ACCOUNT folder. A DISCOVERED root already *is* that folder, so
        // this now finds nothing to add for the ordinary case — it earns its place for a root the
        // migration pinned below the account level, which is what a pre-existing Location override
        // pointing at `.../OneDrive-X/Documents` becomes. Anchored on `Library/CloudStorage`
        // specifically, and on the LAST such pair: matching a bare "CloudStorage" component
        // anywhere claimed unrelated trees for anyone who happens to keep a folder by that name.
        for index in components.indices.dropLast().reversed()
        where components[index] == "Library" && components[index + 1] == "CloudStorage" {
            let accountIndex = index + 2
            guard accountIndex < components.count else { break }
            roots.append(NSString.path(withComponents: Array(components[0...accountIndex])))
            break
        }
        return roots
    }

    /// Whether these path components name a user's home directory or something above it — the
    /// roots a provider must never claim, because claiming one types every unrelated local folder
    /// beneath it.
    ///
    /// Structural rather than a comparison against `NSHomeDirectory()`, so it holds for any account
    /// on the machine and stays a pure function (the fixtures that pin it use `/Users/u`, which is
    /// nobody's real home). The real home is checked too, for the firmlinked spellings the shape
    /// rule cannot see.
    ///
    /// `/Volumes/<mount>` deliberately does NOT match: an external volume's root is a legitimate
    /// provider Location, and it contains only what the user put on that volume.
    private static func isHomeOrAbove(_ components: [String]) -> Bool {
        // "/", "/Users", "/Volumes" — a root this broad is never a provider folder.
        if components.count <= 2 { return true }
        // "/Users/<someone>" — a home directory. `/Volumes/<mount>` has the same depth and is fine.
        if components.count == 3, components[1] == "Users" { return true }
        let path = NSString.path(withComponents: components)
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return PathBoundary.contains(home, under: path)
    }
}
