import Foundation

/// Where the file at one path lives: the pure half of the Info inspector's *Where it lives* row.
///
/// It answers how many places hold this file at this path: this Mac, the provider whose synced
/// folder contains it, both, or (for a dataless placeholder) the provider alone. It is not an
/// inventory of copies: Time Machine, a clone, or the same bytes under another name are invisible
/// here. So `thisMacOnly` means "inside no cloud-synced folder", and the words stay factual: no
/// "unprotected", no "unsafe", no count of copies.
///
/// Two signals are crossed. Containment is pure string math (`covering(path:in:)`), free for any
/// number of paths. Materialization is the `lstat` behind ☁
/// (`MaterializationStatus.isCloudOnlyIfKnown`), whose `nil` stays its own outcome
/// (`verdict(forPath:in:isCloudOnly:)`).
public enum FileLocation {

    // MARK: The covered ground

    /// One cloud source's covered ground: the name to put in an answer, and the roots a path must
    /// be under to count as covered by it.
    public struct CloudRoot: Equatable, Sendable {
        public let providerId: String
        /// The provider's display name, user renames included, since the row says it out loud
        /// ("This Mac · iCloud").
        public let displayName: String
        /// Every root this source covers, normalized by `FileLocation.normalize`. Plural because a
        /// configured root can be a subfolder of its account folder; see `coveredPaths(ofRootPath:)`.
        public let paths: [String]

        public init(providerId: String, displayName: String, paths: [String]) {
            self.providerId = providerId
            self.displayName = displayName
            self.paths = paths
        }
    }

    /// Every cloud source's covered ground, resolved once per source-list change.
    ///
    /// `Equatable` so a memo invalidates by comparing it, not by a counter bumped at each call site
    /// (as `PaneActionDelegate`'s `ignoreStateToken` does): one forgotten bump would serve an answer
    /// about a provider that no longer exists.
    public struct Coverage: Equatable, Sendable {
        public let roots: [CloudRoot]

        public init(roots: [CloudRoot]) { self.roots = roots }

        /// No cloud sources at all: every absolute path is outside every cloud folder.
        ///
        /// **Named `empty`, never `none`.** This type is passed as an `Optional` where "coverage
        /// unknown" must differ from "no cloud folders", and Swift resolves `.none` against
        /// `Optional` first, so `.none` would silently become `nil` and the inspector row would
        /// vanish for files outside every cloud folder.
        public static let empty = Coverage(roots: [])
    }

    /// The cloud ground the discovered sources cover.
    ///
    /// Two rules, each pinned by a named test. A folder source is never coverage: a plain folder
    /// has no second copy behind it. (`CloudProvider.claimRoots` excludes folder sources for an
    /// unrelated reason, name rules, and this doesn't call it.)
    ///
    /// - Parameter disabledProviderIds: Deliberately unread, so the signature states the second
    ///   rule: a disabled provider still counts, since its folder still syncs. Filtering on it would
    ///   invent risk and fails `aDisabledProvidersFolderStillCounts`.
    public static func coverage(
        of providers: [CloudProvider],
        disabledProviderIds: Set<String>
    ) -> Coverage {
        Coverage(roots: providers.compactMap { provider in
            guard !provider.isLocalFolder else { return nil }
            // An empty path is no root, not the volume root (the hazard `PathBoundary.relativize`
            // guards), as from a provider dropped from settings while its row is still on screen.
            let paths = coveredPaths(ofRootPath: provider.rootPath)
            guard !paths.isEmpty else { return nil }
            return CloudRoot(providerId: provider.id,
                             displayName: provider.displayName,
                             paths: paths)
        })
    }

    /// The roots one provider's configured path covers: the path itself, plus the CloudStorage
    /// account folder it sits under when it has one.
    ///
    /// The account folder matters when the root is a subfolder of it (a `root_override_` from
    /// `RootsMigration`, or a folder source inside an account): without it a file elsewhere in the
    /// account would read "This Mac only". A discovered root is already its account folder, so it
    /// is listed once. Anchored on the last `Library/CloudStorage` pair, so a folder merely named
    /// "CloudStorage" claims nothing. No home-or-above guard, unlike `CloudProvider.claimRoots`: a
    /// broad Location can only remove a "This Mac only", never invent one.
    ///
    /// A folder the root links in from outside is covered too, where it really lives (iCloud
    /// Drive's `Documents` is `~/Documents`). The table is `PathBoundary.discoveredLinkedFolders`;
    /// a test passes its own. Pure string math: `NSString` path calls don't reach the filesystem,
    /// where an unhinted `URL(fileURLWithPath:)` does.
    static func coveredPaths(ofRootPath rootPath: String,
                             links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [String] {
        let normalized = normalize(rootPath)
        guard !normalized.isEmpty, normalized.hasPrefix("/") else { return [] }
        var paths = [normalized]
        for target in PathBoundary.linkedFolders(atRoot: rootPath, in: links).values.sorted() {
            let covered = normalize(target)
            if !paths.contains(covered) { paths.append(covered) }
        }
        let components = (normalized as NSString).pathComponents
        for index in components.indices.dropLast().reversed()
        where components[index] == "library" && components[index + 1] == "cloudstorage" {
            let accountIndex = index + 2
            guard accountIndex < components.count else { break }
            // A discovered source's root already is this folder; don't list it twice.
            let account = NSString.path(withComponents: Array(components[0...accountIndex]))
            if account != normalized { paths.append(account) }
            break
        }
        return paths
    }

    /// The one spelling every path in here is compared in: tilde expanded, case folded.
    ///
    /// Case is folded because a row's path and a provider's root come from different sources and
    /// may differ in case, which names one folder on a case-insensitive volume. Folding can only
    /// find coverage, never invent absence, the claim this must not get wrong.
    ///
    /// No `standardizedFileURL` or `NSString.standardizingPath`: the first stats an unhinted path
    /// and the second resolves symlinks, a syscall either way (see `covering(path:in:)`). Paths
    /// reaching here are already absolute and lexically standard.
    static func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath.lowercased()
    }

    // MARK: Containment — the syscall-free half

    /// The cloud source whose synced folder contains `path`, or nil when none does.
    ///
    /// No filesystem access at all, so it can be asked of any number of paths without a memo.
    /// `FileLocationTests` pins this with fixtures that don't exist and a scan of this file for
    /// filesystem APIs.
    ///
    /// First match wins: cloud roots don't nest in practice, and a wrong pick only names the outer
    /// of two providers that both hold the file. (`CloudProvider.inferredType` needs longest-wins,
    /// since there the pick decides which name rules govern a write.)
    public static func covering(path: String, in coverage: Coverage) -> CloudRoot? {
        let target = normalize(path)
        guard !target.isEmpty else { return nil }
        for root in coverage.roots {
            for base in root.paths where PathBoundary.contains(target, under: base) {
                return root
            }
        }
        return nil
    }

    /// What the inspector says about where a folder is: "In ⟨source⟩" inside a cloud source's
    /// folder, "This Mac only" outside every one. Containment alone, no syscall: a folder has no
    /// content of its own to download, and its files answer for themselves through the verdict.
    public static func folderLabel(forPath path: String, in coverage: Coverage) -> String {
        covering(path: path, in: coverage).map { "In \($0.displayName)" } ?? "This Mac only"
    }

    // MARK: The verdict

    /// What the inspector says about one file.
    public enum Verdict: Equatable, Sendable {
        /// The path is inside no cloud source's folder, and its content is on this Mac.
        case thisMacOnly
        /// The path is inside a cloud source's folder and its content is on this Mac too.
        case thisMacAndCloud(providerName: String)
        /// The path is inside a cloud source's folder and its content is not downloaded.
        case cloudOnly(providerName: String)

        /// The words the row shows.
        ///
        /// "This Mac only" means only that the path is inside no cloud-synced folder; never
        /// "unprotected" or a count of copies (see the type doc).
        public var label: String {
            switch self {
            case .thisMacOnly: return "This Mac only"
            case .thisMacAndCloud(let name): return "This Mac · \(name)"
            case .cloudOnly(let name): return "\(name) only"
            }
        }
    }

    /// Containment crossed with materialization, or nil when there is nothing honest to say.
    ///
    /// `isCloudOnly` stays Optional: `MaterializationStatus.isCloudOnlyIfKnown` answers nil when
    /// the path can't be statted, and folding that into `false` would print "This Mac only" over a
    /// file deleted mid-download. So nil shows nothing.
    ///
    /// Dataless outside every cloud folder answers nil too: some undiscovered File Provider holds
    /// the content (Box, Proton, a moved account folder), `thisMacOnly` would be false, and there is
    /// no provider to name. The ☁ badge still shows for such a row.
    public static func verdict(
        forPath path: String,
        in coverage: Coverage,
        isCloudOnly: Bool?
    ) -> Verdict? {
        guard let isCloudOnly else { return nil }
        guard let root = covering(path: path, in: coverage) else {
            return isCloudOnly ? nil : .thisMacOnly
        }
        return isCloudOnly
            ? .cloudOnly(providerName: root.displayName)
            : .thisMacAndCloud(providerName: root.displayName)
    }
}
