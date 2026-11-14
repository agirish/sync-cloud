import Foundation

/// The one subtree Organize is currently answering about.
///
/// Organize's rail presents its lenses as peers, so they must answer about one subject. The scope
/// is that subject, set by the user rather than left as a side effect of whichever scan last ran:
/// the pane proposes, the scope is explicit and sticky, and browsing never silently moves it.
///
/// ## Scope filters; it does not rescan
///
/// Filing, names and renames all come off one provider-wide walk and restructure reads the folder
/// profile, so narrowing all four is pure predicate work, free and instant. Only Duplicates needs
/// a scan of its own, and that cost already sits on its own rail item.
///
/// ## Normalizing the root is what keeps this one state
///
/// There is no separate "global" view: global is the absence of a scope, and the default. Pointing
/// at the provider root clears the scope rather than setting it to the root path, or the two would
/// be two encodings of one state, differing only in the chip. ``init(path:providerRoot:)`` is
/// failable for that reason and returns nil for the root.
public struct OrganizeScope: Equatable, Sendable, Hashable {

    /// Absolute path of the subtree. Never empty, never the provider root, always inside it.
    public let path: String

    /// The provider root this scope was resolved against, so a scope can be re-validated when the
    /// pane's provider changes and ``relativePath`` needs no second argument.
    public let providerRoot: String

    /// The leaf name, for the chip.
    public var name: String { (path as NSString).lastPathComponent }

    /// The scope relative to its provider root ("Finance/US"), for the chip's tooltip and any
    /// readout that should not leak the `/Users/<you>` prefix.
    public var relativePath: String {
        PathBoundary.relativize(path, under: providerRoot) ?? path
    }

    /// Resolves a scope, or nil for the provider root and for anything outside it.
    ///
    /// Nil is the global view, not an error: a caller handed the root (the context menu, ⌘K,
    /// "Scan '<folder>'") writes nil straight through and the chip disappears. Outside the root
    /// also answers nil rather than trapping: a provider can switch while a stale scope is
    /// persisted, and falling back to global beats filtering every lens to nothing.
    public init?(path: String, providerRoot: String) {
        let folder = (path as NSString).expandingTildeInPath
        let root = (providerRoot as NSString).expandingTildeInPath
        guard !folder.isEmpty, !root.isEmpty else { return nil }
        // `relativize` gives all three answers at once: nil for outside, "" for the root itself,
        // and a non-empty relative path for a subtree. Reusing it keeps the boundary rule (`/a/b`
        // must not claim `/a/bc`) in the one place that owns it.
        guard let relative = PathBoundary.relativize(folder, under: root), !relative.isEmpty else {
            return nil
        }
        self.path = folder
        self.providerRoot = root
    }

    /// What a chosen folder is stored as: the one owner of the write-side normalization.
    ///
    /// Returns the resolved absolute path, or `""` (the global view) for anything that is not a
    /// subtree of a live provider root: a nil or empty path, the root itself, a path outside it, a
    /// nil or empty root. Both writers of this persisted key come through here, so the global view
    /// keeps one encoding. A missing root and an empty one both mean no provider and so no scope,
    /// which is why the root is optional: `ContentView` passes `lensProviderRootExpanded` (`""` when
    /// there is no root), `LensWorkspaceView` a `String?`.
    ///
    /// The write is the read inverted, so the round trip can't drift:
    /// ``OrganizeScopeDefaults/scope(fromStored:providerRoot:)`` resolves the stored string at
    /// launch, and storing anything it would not hand back makes the chip and the filter disagree.
    public static func normalizedPath(_ path: String?, providerRoot: String?) -> String {
        OrganizeScopeDefaults.scope(fromStored: path, providerRoot: providerRoot)?.path ?? ""
    }
}

// MARK: - Where the scope is stored

/// The scope's persistence: one key. Builds 4.0 through 7.0 stamped it (`organizeScopePathStamp`)
/// and cleared a value no build of theirs had written; every 6.x install carries that stamp.
///
/// A stored value is not the in-memory default, and a test that only starts from `""` never
/// sees what a real launch reads off disk, so ``OrganizeScopeStorageTests`` builds every fixture
/// from a stored string.
public enum OrganizeScopeDefaults {

    /// The scope's absolute path. Empty (or absent) is the global view, the default; there is no
    /// separate "everything" value to migrate to or from.
    public static let pathKey = "organizeScopePath"

    /// The scope a stored path resolves to under a given provider root: the read half of the round
    /// trip, kept beside the write so the two can't drift. Nil for an empty path (the global view),
    /// for the provider root, and for another provider's path, so a stale scope degrades to global
    /// rather than filtering every lens to nothing.
    public static func scope(fromStored path: String?, providerRoot: String?) -> OrganizeScope? {
        guard let path, !path.isEmpty, let providerRoot, !providerRoot.isEmpty else { return nil }
        return OrganizeScope(path: path, providerRoot: providerRoot)
    }
}

// MARK: - Containment

extension OrganizeScope {

    /// Whether an absolute path is the scope itself or inside it.
    public func contains(_ absolutePath: String) -> Bool {
        PathBoundary.contains(absolutePath, under: path)
    }

    /// Whether an absolute path is a strict ancestor of the scope. Only Restructure needs it: its
    /// findings are about a family of siblings, and the family a scoped leaf sits in is an answer
    /// about that leaf, not a finding to drop.
    public func isAncestor(_ absolutePath: String) -> Bool {
        absolutePath != path && PathBoundary.contains(path, under: absolutePath)
    }
}

// MARK: - How a finding relates to the scope

/// Where one finding sits relative to the scope.
///
/// Three cases, not a Bool, because Restructure has three answers: at a leaf folder almost every
/// structure finding is about the family above, and dropping those would leave Restructure looking
/// broken under any narrow scope.
public enum ScopeRelation: Equatable, Sendable {
    /// The finding is the scope or sits under it.
    case inside
    /// The finding is about a folder the scope sits inside: shown, labelled, never dropped.
    case aboutAncestor
    /// Elsewhere in the tree. Filtered out.
    case outside
}

extension OrganizeScope {

    /// How an absolute path relates to this scope.
    public func relation(of absolutePath: String) -> ScopeRelation {
        if contains(absolutePath) { return .inside }
        if isAncestor(absolutePath) { return .aboutAncestor }
        return .outside
    }
}

// MARK: - Where Organize is currently aimed

/// What Organize is answering about right now, and whether the pane has wandered off it.
///
/// Kept out of `LensWorkspaceView.targetMoved(from:)` because the rule is a precedence, and one
/// buried in a `??` chain inside a private view method is one no test can reach.
public enum OrganizeAim {

    /// The folder Organize's current answers are about, in falling order of authority:
    ///
    /// 1. The scope, when one is set: the subject the user chose.
    /// 2. The scanned root, when a lens has run: what its list covers.
    /// 3. The provider root: with neither, Organize answers about everything. Without this rung
    ///    Organize has no subject before any scan, so it can't notice the pane leaving it and never
    ///    offers "Organize this".
    ///
    /// Nil only when all three are absent or empty.
    public static func subject(scope: OrganizeScope?, scannedRoot: String?,
                               providerRoot: String?) -> String? {
        for candidate in [scope?.path, scannedRoot, providerRoot] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// Whether `paneFolder` is somewhere other than ``subject(scope:scannedRoot:providerRoot:)``:
    /// the cue to offer re-aiming, never to re-aim, since browsing doesn't move the scope. False
    /// when no folder is focused or there is no subject to have moved away from.
    public static func paneMovedAway(paneFolder: String?, scope: OrganizeScope?,
                                     scannedRoot: String?, providerRoot: String?) -> Bool {
        guard let paneFolder, !paneFolder.isEmpty,
              let subject = subject(scope: scope, scannedRoot: scannedRoot,
                                    providerRoot: providerRoot) else { return false }
        return standardized(paneFolder) != standardized(subject)
    }

    /// The folder Duplicates' *Show them again* counts, forgets and rescans: the deeper of the
    /// scanned root and the scope, so all three act on the groups the list on screen can show.
    ///
    /// The list is the scan's groups narrowed by the scope, so its folder is whichever of the two
    /// sits inside the other. Counting under the scan root alone would forget groups the scope
    /// hides, and the rescan of the scope would never bring them back. Unrelated folders answer the
    /// scope, the subject the user chose; nil only when both are absent.
    public static func keptSeparateFolder(scannedRoot: String?, scope: OrganizeScope?) -> String? {
        let root = scannedRoot.flatMap { $0.isEmpty ? nil : $0 }
        guard let scope else { return root }
        guard let root, PathBoundary.contains(root, under: scope.path) else { return scope.path }
        return root
    }

    /// Whether a Storage report built at `reportRoot` may stay on screen under `scope`.
    ///
    /// Storage is the one lens whose scope is a re-analysis rather than a filter. Every other lens
    /// narrows a list it holds, so its rows stay true; a treemap is part-of-whole, and a subset
    /// would misstate every proportion, so Storage re-analyses the new root, and until it does the
    /// report in hand is about somewhere else.
    ///
    /// A nil scope answers true: the pane's own rules apply (the report persists while you browse,
    /// the chip names its root, and ``paneMovedAway(paneFolder:scope:scannedRoot:providerRoot:)``
    /// offers to re-aim). Clearing on every pane move would throw away a report the user never
    /// asked to lose.
    ///
    /// Compared through ``standardized(_:)``, not `==`: the scope is stored normalized but
    /// `storageLensRoot` is whatever `URL` the analysis was handed, and a raw compare would clear a
    /// correct report and re-analyse for nothing.
    public static func storageReportStandsUnder(scope: OrganizeScope?, reportRoot: String?) -> Bool {
        guard let scope, let reportRoot, !reportRoot.isEmpty else { return true }
        return standardized(reportRoot) == standardized(scope.path)
    }

    /// Tilde-expanded, `.`/`..` resolved, trailing slash dropped, so `~/Documents`,
    /// `/Users/you/Documents/` and `/Users/you/Documents` are one folder: the paths compared come
    /// from a persisted scope, a lens's scanned root and a settings value, not all expanded.
    ///
    /// Symlinks are deliberately not resolved: that touches the disk, and this runs in a view body
    /// on every render of the header. A symlinked pane path reads as moved, the safe direction: it
    /// offers a no-op re-aim rather than withholding a needed one.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

// MARK: - Per-lens predicates

/// The scope rules, one per lens: pure functions over a scope and a row.
///
/// Kept out of the view so they can be tested without mounting a header. They are the point, not
/// a detail: "a duplicate group is in scope if any member is" is a safety property.
///
/// Every function takes an optional scope, so the global view is the same code path with `nil`,
/// and `nil` always answers "in scope".
public enum OrganizeScopeFilter {

    // MARK: Whether an answer about the scope can be given at all

    /// Whether a recursive pass rooted at `scannedRoot` looked inside `subject`.
    ///
    /// `subject` is what the surface claims to describe: the scope when one is set, otherwise the
    /// provider root. Not ``OrganizeAim/subject(scope:scannedRoot:providerRoot:)``, whose second
    /// rung is the scanned root: that asks whether the scan covered itself, always yes, so a rescan
    /// of one browsed folder would be reported as the whole tree coming back clean.
    ///
    /// Filtering to zero and finding nothing are different answers, and only the second is
    /// "clean". The filters below narrow what a scan found but can't say whether it covered the
    /// subtree, and the scope moves without a scan (the inbox shortcut, Open on a single-source
    /// row, ⌘K), so a zero alone is no verdict.
    ///
    /// A scan of an ancestor covers the subject; a sibling or a descendant does not. With no
    /// subject (no scope, no provider) this answers whether a pass has a root at all.
    ///
    /// Only for passes that walk the whole subtree: the duplicate scan (`maxDepth: nil`) and the
    /// provider-wide taxonomy walk behind risky names and rename plans. A one-level pass needs
    /// ``looseFileScanCovers(subject:scannedFolder:)``; here a root-level scan would claim every
    /// subfolder it never listed.
    public static func scanCovers(subject: String?, scannedRoot: String?) -> Bool {
        guard let subject, !subject.isEmpty else { return scannedRoot != nil }
        guard let scannedRoot else { return false }
        return PathBoundary.contains(subject, under: scannedRoot)
    }

    /// Whether a one-level pass over `scannedFolder` can answer about `subject`.
    ///
    /// The filing pass lists the direct files of one folder (`maxDepth: 1`), so it can report only
    /// the loose files in `scannedFolder`, which answers about the subject only when the subject is
    /// that folder:
    ///
    /// - a descendant subject holds none of them (a direct child inside the subject would be a
    ///   folder, not a loose file);
    /// - an ancestor subject, the provider root included, holds them but also everything the pass
    ///   never listed, so a zero there is no clean bill either.
    ///
    /// Hence equality, decided through ``PathBoundary`` rather than `==` so a trailing slash on
    /// `scannedFolder` can't make the same folder read as two.
    public static func looseFileScanCovers(subject: String?, scannedFolder: String?,
                                           readSubfolders: Bool = false) -> Bool {
        guard let subject, !subject.isEmpty else { return scannedFolder != nil }
        guard let scannedFolder else { return false }
        // A scan that read the subfolders covers every folder below it too.
        guard let relative = PathBoundary.relativize(subject, under: scannedFolder) else { return false }
        return relative.isEmpty || readSubfolders
    }

    // MARK: To File / Names / Renames — the item is under the scope

    /// A loose file is in scope when the file itself is under it.
    public static func matches(_ suggestion: FilingSuggestion, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return scope.contains(suggestion.filePath)
    }

    /// A risky name is in scope when the offending node is under it. The node itself, not its
    /// parent: a risky *folder* name at the scope's own root is a finding about the scope.
    public static func matches(_ risky: RiskyName, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return scope.contains(risky.id)
    }

    /// A rename plan is in scope when the folder it renumbers is under it.
    public static func matches(_ plan: RenamePlan, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return scope.contains(plan.folderPath)
    }

    // MARK: Duplicates — ANY member, and the out-of-scope copies stay visible

    /// A duplicate group is in scope when any copy is.
    ///
    /// Any, not all: this is the feature's safety rule. The user acts on a group by choosing which
    /// copy survives, and showing only its in-scope half would present a two-copy decision as a
    /// one-copy one, which is how the wrong copy gets trashed. So the group is admitted whole, and
    /// ``isCopyInScope(_:scope:)`` lets the row label the copies outside rather than hide them.
    public static func matches(_ group: DuplicateGroup, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return group.copies.contains { scope.contains($0.path) }
    }

    /// Whether one copy of an in-scope group is itself inside the scope: the row's "outside this
    /// folder" label. True for every copy with no scope, so the label never shows in the global
    /// view.
    public static func isCopyInScope(_ copy: DuplicateCopy, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return scope.contains(copy.path)
    }

    // MARK: Restructure — inside, or about the folder above

    /// How a structure finding relates to the scope.
    ///
    /// A finding's paths are profile-relative, so this needs the profile root. A finding whose
    /// subject is `.` (the profile root itself) is an ancestor of any scope: `aboutAncestor`, not
    /// dropped.
    ///
    /// Reads the subject, not the family: for shape they are the same folder, but a backlog
    /// finding about `Health/Dental/2025` under a scope on exactly that folder is work inside the
    /// scope, and reading the family would demote it to an ancestor note about `Health/Dental`.
    public static func relation(of finding: StructureFinding, profileRoot: String,
                                scope: OrganizeScope?) -> ScopeRelation {
        guard let scope else { return .inside }
        let root = (profileRoot as NSString).expandingTildeInPath
        guard !root.isEmpty else { return .outside }
        // `subject == "."` is the profile root; `appendingPathComponent` would make it "<root>/."
        // and `PathBoundary` does no `..`/`.` resolution, so the root case is spelled out.
        let absolute = finding.subject == "."
            ? root
            : (root as NSString).appendingPathComponent(finding.subject)
        return scope.relation(of: absolute)
    }

    // MARK: Handoffs — when a pointed question must clear the scope

    /// Whether revealing `revealedPath` has to clear the scope first.
    ///
    /// A "Find duplicates of this" handoff is resolved against the whole group list, but the rows
    /// on screen come through the scope: for a file outside it, the group would be marked revealed
    /// and then filtered away, a silent "no other copies". Clearing follows the feature's rule that
    /// pointing at something re-aims Organize; narrowing to the file's folder would answer a
    /// question nobody asked. A file already inside the scope leaves the scope as the user set it.
    public static func revealClearsScope(revealedPath: String, scope: OrganizeScope?) -> Bool {
        guard let scope else { return false }
        return !scope.contains(revealedPath)
    }

    // MARK: Rules — no predicate, because the scope does not reach them

    // There is deliberately no `matches(_ rule: AutomationRule, …)` here: the scope narrows
    // findings, and rules are configuration. Filtering rules by destination would hide them all
    // under a scope like the `TODO` inbox, whose rules all write elsewhere. The distinction lives
    // on the lens, as `OrganizeLens.isScoped`, beside its twin `carriesBadge`.
}
