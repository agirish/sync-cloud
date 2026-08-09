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
/// been; `TidyView.targetMoved(from:)` exists precisely because that gap was already felt.
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

    // MARK: Rules — the one genuine non-scoper

    /// Whether a rule could ever file into, or out of, the scope.
    ///
    /// **Rules are configuration, not findings, and the list stays global** — this filters what is
    /// *shown* while every edit still writes the one global list. So the test is deliberately
    /// generous: a rule is shown when its destination is comparable with the scope in either
    /// direction.
    ///
    /// A destination template is provider-relative and may carry `{year}`-style tokens, which makes
    /// the exact destination undecidable without a file. Everything from the first token onwards is
    /// therefore dropped and the **literal prefix** is compared:
    ///
    /// - `Finance/US/Income Tax/{year}` under scope `Finance/US` → inside. Shown.
    /// - `Finance/{year}` under scope `Finance/US` → the prefix `Finance` is an *ancestor* of the
    ///   scope, so this rule may well file into it once the token resolves. Shown, because the
    ///   direction that hides a rule which is about to write into the folder you are looking at is
    ///   the expensive one.
    /// - `Medical/Bills` under scope `Finance/US` → neither. Hidden.
    ///
    /// A rule with an empty destination has nowhere to file and is shown under every scope: it is
    /// incomplete configuration, and hiding it is how an unfinished rule becomes invisible.
    public static func matches(_ rule: AutomationRule, scope: OrganizeScope?) -> Bool {
        guard let scope else { return true }
        let literal = literalPrefix(of: rule.destinationTemplate)
        guard !literal.isEmpty else { return true }
        let absolute = (scope.providerRoot as NSString).appendingPathComponent(literal)
        return scope.relation(of: absolute) != .outside
    }

    /// The token-free head of a destination template, as path components.
    ///
    /// Truncates at the first component containing `{`, rather than at the first `{` character:
    /// `Tax/{year}-forms` names an unknown child of `Tax`, and keeping the partial component would
    /// invent a folder called `{year}-forms`'s literal prefix that is not a path component at all.
    static func literalPrefix(of template: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        var kept: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if component.contains("{") { break }
            kept.append(String(component))
        }
        return kept.joined(separator: "/")
    }
}
