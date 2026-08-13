import Foundation

/// The one subtree Organize is currently answering about.
///
/// ## Why this type exists
///
/// Organize's rail presents six lenses as peers, which implies they answer about the same subject.
/// They did not. To File answered about the scanned folder (or, worse, about the `TODO` inbox
/// whenever the pane happened to sit at the provider root), Duplicates about the pane's folder at
/// the moment its scan ran, and Names, Renames and Restructure about the whole provider tree —
/// four different territories behind one row of peers. Measured on the real profile: with the left
/// pane at `Documents/Legal`, the Renames badge read 126 folders / 611 renames, every one of them
/// outside what the user was looking at.
///
/// The second half of the defect was that scope was a **side-effect of whichever scan last ran**
/// rather than something the user set. Navigating away left the list answering about where you had
/// been; `LensWorkspaceView.targetMoved(from:)` exists precisely because that gap was already felt.
///
/// So scope becomes a first-class thing Organize owns: **the pane proposes, the scope is explicit
/// and sticky, and browsing never silently moves it.**
///
/// ## Scope filters; it does not rescan
///
/// Filing, names and renames all come off one provider-wide walk and restructure reads the folder
/// profile, so narrowing all four is pure predicate work — free and instant. Only Duplicates needs
/// a scan of its own, and that cost already sits on its own rail item.
///
/// ## Normalizing the root is what keeps this one state
///
/// **There is no separate "global" view: global is the absence of a scope, and it is the default.**
/// Pointing at the provider root therefore *clears* the scope rather than setting it to the root
/// path — otherwise `scope = provider root` and `scope = cleared` become two encodings of one
/// state, identical in every result and different only in the chip, which is exactly the kind of
/// distinction a user cannot see and a test cannot justify. ``init(path:providerRoot:)`` is
/// failable for that reason and returns nil for the root.
public struct OrganizeScope: Equatable, Sendable, Hashable {

    /// Absolute path of the subtree. Never empty, never the provider root, always inside it.
    public let path: String

    /// The provider root this scope was resolved against — kept so a scope can be re-validated when
    /// the pane's provider changes underneath it, and so ``relativePath`` can be rendered without
    /// the caller having to re-supply it.
    public let providerRoot: String

    /// The leaf name, for the chip.
    public var name: String { (path as NSString).lastPathComponent }

    /// The scope relative to its provider root — "Finance/US", for the chip's tooltip and for any
    /// readout that should not leak the `/Users/<you>` prefix.
    public var relativePath: String {
        PathBoundary.relativize(path, under: providerRoot) ?? path
    }

    /// Resolves a scope, or **nil for the provider root and for anything outside it**.
    ///
    /// Nil is not an error path — it is the global view. A caller that has just been handed the
    /// root (from the context menu, from ⌘K, from the "Scan '<folder>'" affordance) writes that nil
    /// straight through and the chip disappears, which is the whole normalization rule above.
    ///
    /// Outside-the-root also answers nil rather than trapping: a provider can be switched while a
    /// stale scope is still persisted, and the honest resolution of "that subtree is not in this
    /// tree" is to fall back to the global view rather than to filter every lens to nothing.
    public init?(path: String, providerRoot: String) {
        let folder = (path as NSString).expandingTildeInPath
        let root = (providerRoot as NSString).expandingTildeInPath
        guard !folder.isEmpty, !root.isEmpty else { return nil }
        // `relativize` gives all three answers at once: nil for outside, "" for the root itself,
        // and a non-empty relative path for a genuine subtree. Reusing it here is what keeps the
        // boundary rule — `/a/b` must not claim `/a/bc` — in the one place that already owns it.
        guard let relative = PathBoundary.relativize(folder, under: root), !relative.isEmpty else {
            return nil
        }
        self.path = folder
        self.providerRoot = root
    }

    /// **The one owner of the write-side normalization: what a chosen folder is STORED as.**
    ///
    /// Returns the resolved absolute path, or `""` — the global view — for everything that is not
    /// a genuine subtree of a live provider root: a nil or empty path, the provider root itself, a
    /// path outside it, and a nil or empty root.
    ///
    /// **Why this is a function rather than a rule each writer spells for itself.** It was spelled
    /// twice — once in `ContentView.setOrganizeScope(_:)` and once in
    /// `LensWorkspaceView.setScope(_:)` — under two doc comments that each claimed to be the only
    /// one, on two different shapes of provider root (one non-optional, one optional). They agreed,
    /// but nothing made them agree: this writes **persisted** user state under a single key, so two
    /// copies of one normalization is one edit away from two encodings of the global view, which is
    /// the exact state ``init(path:providerRoot:)`` is failable to prevent.
    ///
    /// **A missing root and an empty root mean the same thing — no provider, therefore no scope —
    /// and that is why the parameter is optional here even though one caller cannot produce nil.**
    /// `ContentView` hands over `lensProviderRootExpanded`, a non-optional string that is `""` when
    /// settings hold no path for the pane's provider; `LensWorkspaceView` holds `String?` and gets
    /// nil for the same condition. Both spellings already cleared the scope for their own flavour
    /// of "no root" — measured, by running both of them over every input in
    /// ``OrganizeScopeNormalizationTests`` before this function existed — so collapsing them loses
    /// nothing and gives the absent case one answer instead of two.
    ///
    /// **The write is defined as the read, inverted**, so the round trip cannot drift:
    /// ``OrganizeScopeDefaults/scope(fromStored:providerRoot:)`` is what a launch resolves the
    /// stored string back through, and storing anything it would not hand back is how a chip and a
    /// filter come to disagree about one string.
    public static func normalizedPath(_ path: String?, providerRoot: String?) -> String {
        OrganizeScopeDefaults.scope(fromStored: path, providerRoot: providerRoot)?.path ?? ""
    }
}

// MARK: - Where the scope is stored

/// The scope's persistence: one key, one stamp, and the migration between them.
///
/// **Scope is persisted, so it is a user-arrangeable value and gets the treatment one.** The
/// hazard this guards is not the one a collection has (a new case in a persisted enum taking the
/// whole blob down with it) — a scope is a single string. It is the quieter one: **a stored value
/// is not the in-memory default**, and a test that only ever starts from `""` never exercises what
/// a real launch reads off disk. ``OrganizeScopeStorageTests`` builds every fixture from a stored
/// string for exactly that reason.
public enum OrganizeScopeDefaults {

    /// The scope's absolute path. **Empty (or absent) is the global view**, which is the default —
    /// there is no separate "everything" value to migrate to or from.
    public static let pathKey = "organizeScopePath"

    /// The format stamp. Absent means "never migrated".
    public static let stampKey = "organizeScopePathStamp"

    /// What ``pathKey`` currently holds: an absolute, tilde-expanded folder path.
    public static let currentStamp = 1

    /// Brings stored scope state up to ``currentStamp``, once.
    ///
    /// At stamp 0 — the state every existing install is in — **nothing has ever written
    /// `pathKey`**, so anything sitting there came from somewhere this code does not know about
    /// and is cleared rather than trusted. That is the cheap, safe direction: the cost of clearing
    /// is one re-scope, and the cost of trusting a foreign value is a lens list filtered by a path
    /// nobody chose.
    ///
    /// Idempotent, and safe to call on every launch: once the stamp is current this returns having
    /// touched nothing.
    @discardableResult
    public static func migrate(defaults: UserDefaults = .standard) -> Bool {
        let stamp = defaults.integer(forKey: stampKey)   // absent → 0
        guard stamp < currentStamp else { return false }
        if stamp == 0 { defaults.removeObject(forKey: pathKey) }
        defaults.set(currentStamp, forKey: stampKey)
        return true
    }

    /// The scope a stored path resolves to under a given provider root — the read half of the
    /// round trip, kept beside the write so the two cannot drift.
    ///
    /// Returns nil for an empty path (the global view), for the provider root, and for a path that
    /// belongs to some other provider — a stale scope degrades to global rather than filtering
    /// every lens to nothing.
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

    /// Whether an absolute path is a strict *ancestor* of the scope — the folder above this one.
    ///
    /// Restructure needs this and nothing else does: its findings are about a family of siblings,
    /// and the family that a scoped-to leaf sits inside is a genuine answer about that leaf's
    /// surroundings rather than a finding to be dropped.
    public func isAncestor(_ absolutePath: String) -> Bool {
        absolutePath != path && PathBoundary.contains(path, under: absolutePath)
    }
}

// MARK: - How a finding relates to the scope

/// Where one finding sits relative to the scope.
///
/// Three cases and not a Bool, because Restructure genuinely has three answers and collapsing the
/// middle one loses the honest half of them: at a leaf folder almost every structure finding is
/// about the family *above*, and dropping those would leave Restructure looking permanently broken
/// under any narrow scope — which is one of the three reasons live-binding scope to the pane was
/// rejected in the first place.
public enum ScopeRelation: Equatable, Sendable {
    /// The finding is the scope or sits under it.
    case inside
    /// The finding is about a folder the scope sits inside — surfaced, labelled, never dropped.
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
/// Split out of `LensWorkspaceView.targetMoved(from:)` because the rule has a **precedence** in it, and a
/// precedence buried in a `??` chain inside a private view method is a rule no test can reach. The
/// three-deep chain is the whole content of the answer, so it is stated here and asserted directly.
public enum OrganizeAim {

    /// The folder Organize's current answers are *about*, in falling order of authority.
    ///
    /// 1. **The scope**, when one is set — the subject the user chose. With a scope the scanned
    ///    root is an implementation detail of how the answer was computed.
    /// 2. **The scanned root**, when a lens has run — what its list actually covers.
    /// 3. **The provider root.** With neither of the above, Organize is answering about *everything*,
    ///    and everything is the tree's top. This rung is the one that was missing: the old chain
    ///    stopped at 2 and returned nil, so before any scan Organize had no opinion about its own
    ///    subject and could not notice the pane leaving it. The user browsed to a folder, got no
    ///    "Organize this" offer anywhere, and nothing on screen said why.
    ///
    /// nil only when all three are absent or empty — no provider, nothing to be aimed at.
    public static func subject(scope: OrganizeScope?, scannedRoot: String?,
                               providerRoot: String?) -> String? {
        for candidate in [scope?.path, scannedRoot, providerRoot] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// Whether `paneFolder` is somewhere other than ``subject(scope:scannedRoot:providerRoot:)`` —
    /// the cue to *offer* re-aiming.
    ///
    /// An offer and never an act: browsing does not move the scope, which is the rule
    /// ``OrganizeScope`` exists to keep. False when the pane is nowhere (no folder focused) or when
    /// there is no subject to have moved away from.
    public static func paneMovedAway(paneFolder: String?, scope: OrganizeScope?,
                                     scannedRoot: String?, providerRoot: String?) -> Bool {
        guard let paneFolder, !paneFolder.isEmpty,
              let subject = subject(scope: scope, scannedRoot: scannedRoot,
                                    providerRoot: providerRoot) else { return false }
        return standardized(paneFolder) != standardized(subject)
    }

    /// Tilde-expanded, `.`/`..` resolved, trailing slash dropped — so `~/Documents`,
    /// `/Users/you/Documents/` and `/Users/you/Documents` are one folder. The comparison is between
    /// paths from three different sources — a persisted scope, a lens's scanned root, a settings
    /// value — and only one of them was ever guaranteed expanded.
    ///
    /// **Symlinks are deliberately not resolved.** `standardizedFileURL` is a pure string
    /// operation; `resolvingSymlinksInPath` touches the disk, and this runs inside a view body on
    /// every render of the header. A symlinked pane path would read as moved, which is the safe
    /// direction: it offers a re-aim that is a no-op rather than withholding one that is needed.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

// MARK: - Per-lens predicates

/// The scope rules, one per lens — pure functions over a scope and a row.
///
/// **Kept out of the view deliberately.** A rule that lives in a `filter` closure inside a body
/// cannot be asserted without mounting a header, and the per-lens semantics here are the deliverable
/// rather than an implementation detail: "a duplicate group is in scope if *any* member is" is a
/// safety property, not a filtering convenience.
///
/// Every function is total and takes an **optional** scope, so the global view is the same code path
/// with `nil` rather than a second branch at each call site. `nil` always answers "in scope" — the
/// absence of a scope filters nothing.
public enum OrganizeScopeFilter {

    // MARK: Whether an answer about the scope can be given at all

    /// Whether a **recursive** pass rooted at `scannedRoot` looked inside `subject`.
    ///
    /// **`subject` is what the surface CLAIMS to describe — the scope when one is set, otherwise the
    /// provider root.** It is deliberately NOT ``OrganizeAim/subject(scope:scannedRoot:providerRoot:)``,
    /// whose second rung is the scanned root: that rung is right for "where should the re-aim offer
    /// point", and circular here. Feeding the scanned root in as the subject asks whether the scan
    /// covered itself, which is always yes, and that is exactly the hole this pair exists to close —
    /// with no scope set, browsing into `Photos/2024` and pressing Rescan made the overview report
    /// *"Nothing to do here. Every check that has run came back clean."* about the whole tree.
    ///
    /// **Filtering to zero and finding nothing are different answers, and only one of them is
    /// "clean".** Every filter below narrows a list the scan produced; none of them can say whether
    /// the scan covered the subtree being narrowed to. Often it did not, and the overview read that
    /// zero as a verdict — "Nothing to do in Legal. Every check that has run came back clean."
    /// about a subtree nothing had opened, reachable through three ordinary doors that move the
    /// scope without scanning (the inbox shortcut, Open on a single-source row, ⌘K).
    ///
    /// A scan of an ANCESTOR covers the subject; a sibling or a descendant does not. With no
    /// subject at all — no scope and no provider — the question falls back to whether a pass has a
    /// root, because there is nothing to have covered.
    ///
    /// **Only for passes that walk the whole subtree** — the duplicate scan (`maxDepth: nil`), and
    /// the provider-wide taxonomy walk that produces risky names and rename plans. A pass that
    /// enumerates ONE level needs ``looseFileScanCovers(subject:scannedFolder:)`` instead; using
    /// this one for it re-opens the same bug, because a root-level scan would claim to cover every
    /// subfolder while having enumerated none of them.
    public static func scanCovers(subject: String?, scannedRoot: String?) -> Bool {
        guard let subject, !subject.isEmpty else { return scannedRoot != nil }
        guard let scannedRoot else { return false }
        return PathBoundary.contains(subject, under: scannedRoot)
    }

    /// Whether a **one-level** pass over `scannedFolder` can answer about `subject`.
    ///
    /// The filing pass enumerates the direct files of one folder (`maxDepth: 1`), so the set it
    /// could possibly report is exactly "the loose files in `scannedFolder`". That set intersects a
    /// subject only when the subject *is* that folder:
    ///
    /// - a **descendant** subject holds none of them (a direct child of the folder that is itself
    ///   inside the subject would have to be a folder, not a loose file);
    /// - an **ancestor** subject — including the provider root — contains them, but also contains
    ///   everything else the pass never enumerated, so a zero there is not a clean bill either.
    ///   This is the case ancestry gets wrong in both directions: scan the provider root and scope
    ///   to `Legal`, or scan one browsed folder with no scope at all, and the count is zero by
    ///   construction while ancestry would call it covered.
    ///
    /// Hence equality, decided through ``PathBoundary`` rather than `==` so that a trailing slash
    /// or a `.` segment cannot make the same folder read as two.
    public static func looseFileScanCovers(subject: String?, scannedFolder: String?) -> Bool {
        guard let subject, !subject.isEmpty else { return scannedFolder != nil }
        guard let scannedFolder else { return false }
        return PathBoundary.relativize(subject, under: scannedFolder) == ""
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

    /// A duplicate group is in scope when **any** copy is.
    ///
    /// **Any, not all, and this is the safety rule of the whole feature.** A group is a claim about
    /// several paths at once, and the user acts on it by choosing which copy survives. Showing only
    /// the in-scope half of a group would present a two-copy decision as a one-copy one — which is
    /// precisely how the wrong copy gets trashed. So the group is admitted whole, and
    /// ``isCopyInScope(_:scope:)`` lets the row *label* the copies that live outside rather than
    /// hide them.
    public static func matches(_ group: DuplicateGroup, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return group.copies.contains { scope.contains($0.path) }
    }

    /// Whether one copy of an in-scope group is itself inside the scope.
    ///
    /// Drives the "outside this folder" label on the row. Answers `true` for every copy when there
    /// is no scope, so the label never renders in the global view.
    public static func isCopyInScope(_ copy: DuplicateCopy, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        return scope.contains(copy.path)
    }

    // MARK: Restructure — inside, or about the folder above

    /// How a structure finding relates to the scope.
    ///
    /// `family` is **profile-relative**, so this needs the profile root to say anything at all —
    /// which is also why the restructure rule could not just be dropped into `filteredRows` beside
    /// the other four without threading that root through.
    ///
    /// A finding whose family is `.` (the profile root itself) relativizes to the root path and is
    /// therefore an ancestor of any scope — reported as `aboutAncestor`, not dropped.
    public static func relation(of finding: StructureFinding, profileRoot: String,
                                scope: OrganizeScope?) -> ScopeRelation {
        guard let scope else { return .inside }
        let root = (profileRoot as NSString).expandingTildeInPath
        guard !root.isEmpty else { return .outside }
        // `family == "."` is the profile root; `appendingPathComponent` would make it "<root>/."
        // and `PathBoundary` does no `..`/`.` resolution, so the root case is spelled out.
        let absolute = finding.family == "."
            ? root
            : (root as NSString).appendingPathComponent(finding.family)
        return scope.relation(of: absolute)
    }

    // MARK: Handoffs — when a pointed question must clear the scope

    /// Whether revealing `revealedPath` has to **clear** the scope first.
    ///
    /// A "Find duplicates of this" handoff names one file, and the answer is resolved against the
    /// *whole* group list while the rows on screen come through the scope. Point at a file outside
    /// the scope and the two disagree: the resolver says *revealed*, writes a query naming the file
    /// and marks its group — and then the group is filtered away before it can be drawn. The user
    /// asked "are there other copies of this?" and got a silent no.
    ///
    /// Three answers were available and only one is honest. *Leave the scope alone* keeps the wrong
    /// answer. *Narrow to the file's folder* answers a question nobody asked. **Clear** matches the
    /// rule the rest of the feature already follows — pointing at something re-aims Organize — and
    /// it is the only one that can show what was asked about.
    ///
    /// Deliberately conditional: a reveal for a file already inside the scope leaves it exactly
    /// where the user put it, so browsing a scoped list and asking about one of its own rows does
    /// not throw the scope away.
    public static func revealClearsScope(revealedPath: String, scope: OrganizeScope?) -> Bool {
        guard let scope else { return false }
        return !scope.contains(revealedPath)
    }

    // MARK: Rules — no predicate, because the scope does not reach them

    // There is deliberately **no `matches(_ rule: AutomationRule, …)` here.** One existed, and it
    // was a careful thing: it dropped a destination template at its first `{token}` and admitted a
    // rule whose literal prefix was inside the scope *or an ancestor of it*, on the argument that
    // hiding a rule about to write into the folder you are looking at is the expensive direction.
    //
    // It answered the wrong question. Scoped to the loose-files inbox — the sticky one-click scope
    // Organize's own overview offers — every rule's destination is `Finance/…`, `Medical/…`,
    // `Legal/…`, none of which is comparable with `TODO`, so the generous predicate hid all eight
    // rules and the one rail item that cannot say "nothing here" said it. The scope narrows
    // *findings*, and rules are configuration; that distinction now lives on the lens itself, as
    // `OrganizeLens.isScoped`, beside the `carriesBadge` rule it is the twin of. See ROADMAP 15.
}
