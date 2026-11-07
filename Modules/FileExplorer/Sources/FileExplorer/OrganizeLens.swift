import Foundation

/// Which of Organize's lenses is on screen, or `nil` for the overview.
///
/// Organize is everything the app concludes about a single tree. Most lenses act on their
/// conclusion (the filing queue, duplicates, the rename backlog, the structure findings); Rules
/// writes the standing instructions that act without asking; Storage only reports and never moves,
/// deletes or evicts a file. Being about the same tree is what makes a lens, not acting; Compare
/// (two trees) stays a workspace of its own. ``carriesBadge`` means "there is something here to act
/// on", so the two lenses that don't act don't badge.
///
/// ## A permanent rail, a vanishing badge
///
/// "Organize this folder", from a context menu or ⌘K, has to land somewhere before any scan has
/// found anything, so the rail item is permanent and the badge is not:
///
/// - The item always exists: ``railItems``, in this order, whatever the counts are.
/// - The badge is absent at zero, not greyed and not "0": `badge(count:)` returns `nil`.
/// - The overview is the unselected state, not a seventh item, so it needs no name of its own and
///   can't be a tab you forget to visit.
///
/// Because an item never vanishes, an empty list is a place you can stand: it says "nothing here".
/// There is deliberately no fallback that moves you off a lens when its list empties.
public enum OrganizeLens: String, CaseIterable, Identifiable, Sendable {

    /// Loose files and where they belong. Organize's default and the lens it opens on when a lens
    /// is opened at all.
    ///
    /// Named "To File", not "File": bare *File* is the menu, "to file" is the app's own noun for
    /// this list (the summary row says "24 to file"), and it names the task rather than the object.
    case toFile = "ToFile"
    /// Identical content under different names or folders. A finding about one tree, so a lens, not
    /// a workspace: Compare's peer is another provider, not another list.
    case duplicates = "Duplicates"
    /// Every name worth changing, in four sections in the order the list draws them: names that
    /// won't store cleanly (this provider's rules plus the invisible hazards `NameNormalizer` flags
    /// on every provider, which is why an iCloud or folder source fills this section too), then
    /// `RenameCategories.Category`'s three: files that don't follow their folder's convention,
    /// files renumbered to make room for one of those, and files whose one-digit ordinals gain a
    /// leading zero.
    ///
    /// What gets renamed is a file. `RenamePlan` is identified by a folder, but its `steps` each
    /// carry a file's current path, so the folder is the grouping, never the thing renamed. Copy
    /// about "folders that have drifted from their numbering" gets both the subject and the scope
    /// wrong.
    case renames = "Renames"
    /// Where the tree disagrees with its own habits.
    case restructure = "Restructure"
    /// The rules that file things without asking. Configuration, not a finding, which is why
    /// ``carriesBadge`` says no for this one.
    case rules = "Rules"
    /// Where the space goes: a treemap of one tree, the largest files, the untouched ones, and what
    /// could be reclaimed. A report, not a backlog: this lens never moves, deletes or evicts a
    /// file, which is why ``carriesBadge`` says no for it too. A "9.4 GB reclaimable" badge would
    /// read as a to-do the lens has no verb to execute.
    ///
    /// Last, because the rail runs act-heavy to act-never: To File through Restructure act, Rules
    /// configures the acting, Storage only looks.
    ///
    /// Its report is the one lens result restored across launches; see
    /// `FileSyncManager+StorageLens`.
    case storage = "Storage"

    public var id: String { rawValue }

    /// The items the rail draws: every case. Kept as a named list rather than `allCases` at the
    /// call sites, because "what the rail draws" is a question the rail should ask of this type,
    /// and a lens added without a rail item would be expressed here.
    public static var railItems: [OrganizeLens] { allCases }

    /// The defaults key holding the rail selection. Absent means the overview, which is why the
    /// stored type is optional rather than carrying an "overview" case: there is no value to write
    /// for "no lens picked", and inventing one would make the unselected state something you could
    /// fail to migrate.
    ///
    /// Declared here rather than beside `Workspace.defaultsKey` because `LensWorkspaceView`, which
    /// owns the rail, reads it directly, and `MacApp` can't be imported from this module.
    public static let defaultsKey = "selectedOrganizeLens"

    /// The rail's label.
    public var title: String {
        switch self {
        case .toFile: return "To File"
        case .duplicates: return "Duplicates"
        case .renames: return "Renames"
        case .restructure: return "Restructure"
        case .rules: return "Rules"
        case .storage: return "Storage"
        }
    }

    /// The rail item's glyph. A glyph beside a number must not draw digits: `textformat.123` draws
    /// a literal `123` beside the count. `OrganizeLensTests.noRailGlyphDrawsDigits` enforces this.
    public var symbol: String {
        switch self {
        case .toFile: return "doc"
        case .duplicates: return "doc.on.doc"
        case .renames: return "folder.badge.gearshape"
        case .restructure: return "square.stack.3d.up"
        case .rules: return "wand.and.stars"
        case .storage: return "chart.pie"
        }
    }

    /// Whether this lens can ever wear a count badge.
    ///
    /// A badge promises there is something here to act on, and two lenses can't keep that promise.
    /// Eight rules is a configuration you keep, not a result a scan turned up. Storage's numbers
    /// are true and large ("9.4 GB reclaimable"), but the lens has no verb to spend them, so a badge
    /// would be a to-do the app can't execute. The other four count work you can start.
    ///
    /// Not the same line ``isScoped`` draws: Rules is exempt from both, but Storage is exempt from
    /// this one and honours scope.
    public var carriesBadge: Bool {
        switch self {
        case .rules, .storage: return false
        case .toFile, .duplicates, .renames, .restructure: return true
        }
    }

    /// The badge for a count: `nil` at zero, so a lens with nothing to report says nothing. The
    /// item stays on the rail either way; what disappears is the claim that there is something to
    /// look at.
    public func badge(count: Int) -> Int? {
        guard carriesBadge, count > 0 else { return nil }
        return count
    }

    /// Whether Organize's scope narrows this lens: false for Rules alone.
    ///
    /// Not the same line ``carriesBadge`` draws. Storage is badgeless (it only reports) and yet
    /// scoped: a treemap of `~/Documents` and one of `~/Documents/Media` are both honest pictures
    /// of the root they name.
    ///
    /// For Storage, scope means re-analysis, never a filter: the analyzer re-runs at the scope root
    /// and the report describes that root. A treemap is a part-of-whole picture, so subsetting an
    /// existing report would misstate every proportion in it, the same reason search may not subset
    /// it. `storageLensRoot` records which root a report describes, so a restored one is never
    /// shown under a scope it wasn't built from.
    ///
    /// The four finding lenses report what a scan turned up somewhere, so scoping To File to
    /// `Finance` gives the loose files in Finance. Rules file into destinations all over the
    /// source, so narrowing them to the folder you're working in answers about a subtree they were
    /// never about. The trap: the overview offers the loose-files inbox as a sticky scope ("Inbox
    /// (TODO) — 24 loose files"), and rules file out of that inbox into `Finance/…`, `Medical/…`.
    /// Scoped to `TODO`, every rule's destination is outside the scope, and the Rules item would say
    /// "nothing here" with eight rules configured.
    ///
    /// So opening Rules aims Organize back at the source root, and leaving it puts the scope back.
    /// Nothing is written to do that: the stored scope just goes unapplied while this lens is on
    /// screen, so "puts it back" is unconditional and no exit path can skip a restore. The chip
    /// stays on screen, suspended, so the scope is visibly parked rather than apparently lost.
    public var isScoped: Bool { self != .rules }
}

// MARK: - Scan provenance

extension OrganizeLens {

    /// Whether this lens's answer comes from the filing scan, and so is stale while that scan runs.
    ///
    /// Organize publishes `filingSuggestions`, `riskyNames` and `renamePlans` on completion, so
    /// mid-scan they still hold the previous answer, deliberately, so a cancelled rescan leaves the
    /// old results intact. A readout drawn from them during a scan is last scan's numbers under
    /// this scan's spinner.
    ///
    /// Structure and rules are exempt: structure findings come from the folder profile with no disk
    /// read, and rules are configuration, so neither goes stale during a filing scan. Gating every
    /// lens on `isSuggestingFiles` would hide a structure badge that is still true.
    public var goesStaleDuringFilingScan: Bool {
        switch self {
        case .toFile, .renames: return true
        case .duplicates, .restructure, .rules, .storage: return false
        }
    }
}

// MARK: - Bridging to the lens apparatus

extension OrganizeLens {

    /// The ``WorkspaceLensKind`` whose search grammar, "N of M" readout and list apparatus this lens uses.
    ///
    /// The rail is the vocabulary; `WorkspaceLensKind` is the machinery key: it owns the per-lens
    /// search grammars and scroll state, keyed by apparatus rather than by rail item. Three rail
    /// items share `.filing`'s apparatus because their rows are filing rows, Renames' risky names
    /// included.
    ///
    /// `.restructure` has no apparatus of its own and answers `.filing`, so its query parks in the
    /// same slot rather than in a grammar that would read it differently.
    public var searchLens: WorkspaceLensKind {
        switch self {
        case .toFile, .renames, .restructure: return .filing
        case .duplicates: return .duplicates
        case .rules: return .automations
        case .storage: return .storage
        }
    }

    /// The rail item a programmatic caller naming a ``WorkspaceLensKind`` is asking for.
    ///
    /// Not a strict inverse of ``searchLens`` and can't be: three rail items share `.filing`, so
    /// this picks the one that is the filing queue. Every other kind answers the one rail item that
    /// owns it.
    ///
    /// Every kind bridges to a rail item today, so this never returns `nil`. It stays failable so
    /// an apparatus added without a rail item has somewhere to say so, the reason ``railItems`` is
    /// kept.
    public init?(_ lens: WorkspaceLensKind) {
        switch lens {
        case .filing: self = .toFile
        case .duplicates: self = .duplicates
        case .automations: self = .rules
        case .storage: self = .storage
        }
    }
}

// MARK: - What each item promises

extension OrganizeLens {

    /// What this item's tooltip says, in the state it is in.
    ///
    /// On the lens rather than the view because these are the lens's own words, beside ``title``,
    /// ``symbol`` and ``carriesBadge``, and a pure function of two enums can be asserted directly.
    /// It takes the state, not the badge: a nil badge means "no number to show", and reading it as
    /// zero would make a never-scanned lens claim a scan found nothing (``RailItemState`` keeps
    /// those apart).
    ///
    /// Written to read correctly whether or not this is the selected item: selection is carried by
    /// the ring and by `.isSelected`, not by the words. The description is one sentence per lens in
    /// every state, and only the leading count clause changes.
    func help(state: RailItemState) -> String {
        let what: String
        switch self {
        case .toFile:      what = "Loose files and where they belong."
        case .duplicates:  what = "Identical content under different names or folders."
        case .renames:     what = "Names that need changing — to sync, to convention, to order: "
                                + "names this provider rejects or any cloud would mangle, files "
                                + "that ignore their folder’s convention, and files whose "
                                + "numbering has to shift or pad."
        case .restructure: what = "Where the tree disagrees with its own habits — recurring folders "
                                + "that were shaped differently in different years."
        case .rules:       what = "The rules that file things without asking. Configuration, so "
                                + "this one never carries a count."
        case .storage:     what = "Where the space goes — the largest files, the ones nothing has "
                                + "touched, and what could be reclaimed. A report, so this one "
                                + "never carries a count and never moves, deletes, or evicts a "
                                + "file."
        }
        switch state {
        case .reporting(let count):
            // In full, unlike the badge: see `RailItemLabel.badgeText`, which abbreviates only
            // because six capsules share one row.
            return "\(count.formatted()) here. \(what)"
        case .clean:       return "Nothing here. \(what)"
        case .notScanned:  return "Not scanned here yet. \(what)"
        case .configuration: return what
        }
    }
}
