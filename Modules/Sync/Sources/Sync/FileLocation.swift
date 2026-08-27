import Foundation

/// Where the file at one path lives — the pure half of the Info inspector's *Where it lives* row
/// and of the `⌂ on this Mac only` row badge.
///
/// ## The question this answers, and the one it does not
///
/// It answers **how many places hold THIS file at THIS path**. The possible answers are exactly:
/// this Mac, the one provider whose synced folder contains the path, both, or — for a dataless
/// placeholder — the provider alone.
///
/// It is **not** an inventory of everywhere the same content might exist. That is a content
/// question, answerable only by hashing every source tree (the roadmap's cross-provider duplicate
/// detection), and nothing here may be worded as though it had been asked. `thisMacOnly` means
/// *the path is inside no cloud-synced folder* — never "no copy of this exists anywhere". Time
/// Machine, an external clone, and the same bytes under another name in a cloud folder are all
/// invisible from here, so the words this type hands to the UI stay factual: no "unprotected", no
/// "unsafe", no count of copies.
///
/// ## Two signals, crossed
///
/// **Containment** is pure string math over the provider list — see `outsideEveryCloudFolder`,
/// which reaches the filesystem nowhere at all. That is what lets the badge ride every visible row
/// for free, where the ☁ badge it mirrors has to buy each answer with an `lstat`.
///
/// **Materialization** is that `lstat`: `MaterializationStatus.isCloudOnlyIfKnown`, the same
/// syscall that already draws ☁. It answers three ways, and the third is kept — see
/// `verdict(forPath:in:isCloudOnly:)` for why `nil` is its own outcome rather than a folded-in
/// `false`.
public enum FileLocation {

    // MARK: The covered ground

    /// One cloud source's covered ground: the name to put in an answer, and the roots a path must
    /// be under to count as covered by it.
    public struct CloudRoot: Equatable, Sendable {
        public let providerId: String
        /// The provider's real display name, user renames included — this is what the inspector
        /// row says out loud ("This Mac · iCloud"), so it must be the name the user sees everywhere
        /// else rather than a type name.
        public let displayName: String
        /// Every root this source covers, normalized by `FileLocation.normalize`. Plural because a
        /// provider's configured root is usually a *subfolder* of its account folder — see
        /// `coveredPaths(ofRootPath:)`.
        public let paths: [String]

        public init(providerId: String, displayName: String, paths: [String]) {
            self.providerId = providerId
            self.displayName = displayName
            self.paths = paths
        }
    }

    /// Every cloud source's covered ground, resolved once per source-list change.
    ///
    /// A value (and `Equatable`) so a memo can invalidate by comparing it rather than by a
    /// hand-maintained counter bumped at each call site — the same trade `PaneActionDelegate`'s
    /// `ignoreStateToken` makes, and for the same reason: a generation is one forgotten bump away
    /// from serving an answer about a provider that no longer exists.
    public struct Coverage: Equatable, Sendable {
        public let roots: [CloudRoot]

        public init(roots: [CloudRoot]) { self.roots = roots }

        /// No cloud sources at all: every absolute path is outside every cloud folder.
        ///
        /// **Named `empty`, not `none`, and that is not a style choice.** This type is passed as
        /// an `Optional` wherever "the coverage is not known here" has to be distinguishable from
        /// "there are no cloud folders" — the Info inspector's parameter, for one. Swift resolves
        /// `.none` against `Optional` first, so `Coverage.none` written at such a call site
        /// silently becomes `nil`: a positive claim turns into an absent one, with no diagnostic.
        /// That cost an afternoon here, and it would have shipped as an inspector row that never
        /// appeared for anyone whose files are outside every cloud folder — the exact case the
        /// row exists for.
        public static let empty = Coverage(roots: [])
    }

    /// The cloud ground the discovered sources cover.
    ///
    /// Two rules live here, both from ROADMAP's *Saying only what can be proved*, and both stated
    /// in code rather than in a comment at the call site so that changing one fails a named test.
    ///
    /// **A folder source is never coverage.** It is the thing being asked about, not a cloud —
    /// a plain folder the user added as a source has no second copy behind it, so counting one as
    /// coverage would answer "this file is in two places" about a file that is in one.
    /// (`CloudProvider.claimRoots` excludes folder sources too, but for an unrelated reason — a
    /// claim there carries a provider's *name rules* onto a path, and a folder has none to carry.
    /// This is not that logic and does not call it.)
    ///
    /// - Parameter disabledProviderIds: **Deliberately unread.** Taken so the second rule is
    ///   stated in the signature: *a disabled provider still counts as coverage.* Its folder is on
    ///   disk whether or not the user has the source switched on in Settings, so a file inside it
    ///   still has a second copy; filtering here would manufacture risk that is not there. Anyone
    ///   who "tidies up" the unused parameter by filtering on it fails
    ///   `aDisabledProvidersFolderStillCounts`.
    public static func coverage(
        of providers: [CloudProvider],
        disabledProviderIds: Set<String>
    ) -> Coverage {
        Coverage(roots: providers.compactMap { provider in
            guard !provider.isLocalFolder else { return nil }
            // An empty path is the ABSENCE of a root, not the volume root — the same hazard
            // `PathBoundary.relativize` guards, arriving here from a provider dropped from
            // settings while its stale row is still on screen. Dropping it entirely is stricter
            // than relying on that guard, and says so.
            let paths = coveredPaths(ofRootPath: provider.rootPath)
            guard !paths.isEmpty else { return nil }
            return CloudRoot(providerId: provider.id,
                             displayName: provider.displayName,
                             paths: paths)
        })
    }

    /// The coverage a pane rooted at `providerId` resolves the `⌂` badge against, or **nil where
    /// the badge never applies** — which is every pane whose source is not a plain folder.
    ///
    /// Inside a cloud source's own pane every row is covered by definition, so a badge there would
    /// be a mark on everything and say nothing. Folding the gate into the value the pane needs
    /// anyway means the pane carries one thing, not a flag and a table that can disagree.
    ///
    /// **This lives here, in the tested layer, rather than in `ContentView`.** The gate is one
    /// `if` and it is tempting to leave it at the call site — but `MacApp` has no unit tests that
    /// can reach a `View`'s methods, so a gate written there is a rule nothing checks. It is the
    /// call site, not the helper, that decides whether the badge appears at all.
    ///
    /// A provider id that resolves to nothing answers nil: an unresolved source is not a folder
    /// source, and marking every row of a pane whose provider vanished is the last thing it needs.
    public static func badgeCoverage(
        forProviderId providerId: String,
        among providers: [CloudProvider],
        disabledProviderIds: Set<String>
    ) -> Coverage? {
        guard providers.first(where: { $0.id == providerId })?.isLocalFolder == true else { return nil }
        return coverage(of: providers, disabledProviderIds: disabledProviderIds)
    }

    /// The roots one provider's configured path covers: the path itself, plus the CloudStorage
    /// account folder it sits under when it has one.
    ///
    /// **The account folder is not padding — without it this feature lies.** Discovery configures a
    /// provider at a *subfolder* of its account folder (`…/OneDrive-<acct>/Documents`,
    /// `…/GoogleDrive-<acct>/My Drive/Documents`, `…/Dropbox/Documents`). A Home-folder pane lists
    /// `~/Library/CloudStorage` like any other folder, so a plain test against the configured root
    /// alone would stamp *This Mac only* on `…/OneDrive-<acct>/Photos/a.jpg` — a file that plainly
    /// is in OneDrive. That is the inverse of the false reassurance ROADMAP warns about: it
    /// manufactures risk that is not there, which is the same failure as dropping a disabled
    /// provider, and it would also put ⌂ and ☁ on one row at once.
    ///
    /// Anchored on a `Library/CloudStorage` pair specifically, and on the LAST such pair, so a
    /// folder someone happens to have named "CloudStorage" claims nothing. A provider whose
    /// Location was overridden to somewhere outside CloudStorage contributes only its own root,
    /// which is the whole of what is known about it.
    ///
    /// Deliberately keeps no home-or-above guard, unlike `CloudProvider.claimRoots`: there the
    /// guard stops a broad Location silently imposing one provider's *name rules* on unrelated
    /// files, which is a cost. Here a user who points a provider at a broad folder has told us
    /// that ground is synced, and believing them only ever *removes* a ⌂ — it cannot invent one.
    ///
    /// Pure string math. `NSString.pathComponents` and `NSString.path(withComponents:)` do not
    /// reach the filesystem, which `URL(fileURLWithPath:)` — unhinted — does.
    static func coveredPaths(ofRootPath rootPath: String) -> [String] {
        let normalized = normalize(rootPath)
        guard !normalized.isEmpty, normalized.hasPrefix("/") else { return [] }
        var paths = [normalized]
        let components = (normalized as NSString).pathComponents
        for index in components.indices.dropLast().reversed()
        where components[index] == "library" && components[index + 1] == "cloudstorage" {
            let accountIndex = index + 2
            guard accountIndex < components.count else { break }
            paths.append(NSString.path(withComponents: Array(components[0...accountIndex])))
            break
        }
        return paths
    }

    /// The one spelling every path in here is compared in: tilde expanded, case folded.
    ///
    /// **Case is folded, deliberately, and it is the safe direction.** The two sides have different
    /// lineage — a row's path descends from the pane's own root string, a provider's root from
    /// discovery or a hand-typed Location override — so unlike `CloudOnlyBadgeCache`'s memo keys
    /// they carry no promise of agreeing on spelling, and on the default case-insensitive macOS
    /// volume the two spellings name one folder. Folding can only ever *find* coverage, never
    /// invent absence, and absence is the claim this feature must not get wrong.
    ///
    /// No `standardizedFileURL`, no `NSString.standardizingPath`: the first stats the path when
    /// built without an `isDirectory:` hint, and the second resolves symlinks under `/tmp` and
    /// `/var`. Both would put a syscall in the containment half — see `outsideEveryCloudFolder`.
    /// Every path reaching here is already absolute and lexically standard, produced by a tree walk
    /// descending from a root or by provider discovery.
    static func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath.lowercased()
    }

    // MARK: Containment — the syscall-free half

    /// The cloud source whose synced folder contains `path`, or nil when none does.
    ///
    /// **No filesystem access, at all.** This is what the ⌂ badge asks, eagerly, for every visible
    /// row of a pane that may hold tens of thousands of them; the ☁ badge it mirrors buys each of
    /// its answers with a detached `lstat` and needs a memo to survive scrolling. `FileLocationTests`
    /// pins the guarantee two ways: every containment fixture uses paths that **do not exist**, and
    /// a source check asserts this file names no filesystem-touching API.
    ///
    /// First match wins rather than longest-root-wins. The answer is *which name to print*, and two
    /// discovered cloud roots do not nest in practice; `CloudProvider.inferredType` needs the
    /// longest-wins rule because a wrong pick there silently changes which name rules govern a
    /// write, where a wrong pick here at worst names the outer of two providers that both hold the
    /// file — and both statements, "this file is also in the cloud" and the name, stay true.
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

    /// Whether `path` sits inside no cloud source's folder — the ⌂ badge's whole question.
    ///
    /// Containment only, so it costs no syscall and lands with the row rather than after it. The
    /// *badge* additionally requires the file not to be a dataless placeholder, which is what makes
    /// ⌂ and ☁ mutually exclusive; that half is composed where both answers are already in hand,
    /// in `FileRowAccessories`, rather than made a precondition here — a precondition would put an
    /// `lstat` back in front of every row.
    public static func outsideEveryCloudFolder(path: String, in coverage: Coverage) -> Bool {
        covering(path: path, in: coverage) == nil
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
        /// "This Mac only" is literal — the path is inside no cloud-synced folder — and stops
        /// there on purpose. It is never "unprotected", never "unsafe", and never a count of
        /// copies: see the type doc for what this feature cannot see.
        public var label: String {
            switch self {
            case .thisMacOnly: return "This Mac only"
            case .thisMacAndCloud(let name): return "This Mac · \(name)"
            case .cloudOnly(let name): return "\(name) only"
            }
        }

        /// Whether the content is on this Mac. Read by the inspector's supporting "On this Mac"
        /// row, so the verdict reads as the conclusion of a fact shown directly above it rather
        /// than as an oracle.
        public var isOnThisMac: Bool {
            switch self {
            case .thisMacOnly, .thisMacAndCloud: return true
            case .cloudOnly: return false
            }
        }
    }

    /// Containment crossed with materialization, or nil when there is nothing honest to say.
    ///
    /// **`isCloudOnly` is an Optional for a reason and it is kept as one.**
    /// `MaterializationStatus.isCloudOnlyIfKnown` answers nil when the path cannot be statted at
    /// all — "not dataless" and "not there" are opposite facts `lstat` reports through the same
    /// failure — and a file deleted mid-download must not be reported as materialized. Folding nil
    /// into `false` here would print "This Mac only" over a file that is not on this Mac in any
    /// sense. So nil is its own outcome: the inspector row shows nothing rather than guessing, and
    /// the badge stays absent.
    ///
    /// **Dataless *outside* every cloud folder answers nil too, and that is not an oversight.**
    /// It means some File Provider this app never discovered holds the content — real (Box,
    /// Proton, a provider whose account folder was moved), and not a state this can explain.
    /// `thisMacOnly` would be a plain lie there (the bytes are elsewhere), and there is no provider
    /// to name. Showing nothing is the same answer this gives to every other question it cannot
    /// prove. The shipped ☁ badge is unaffected — it asks only whether the file is dataless — so
    /// such a row still says so; it simply gets no *Where it lives* verdict to go with it.
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
