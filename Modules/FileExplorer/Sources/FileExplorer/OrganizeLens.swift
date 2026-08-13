import Foundation

/// Which of Organize's lenses is on screen, or `nil` for the overview.
///
/// Organize is the one place that changes a single tree, and every way of changing it is a lens
/// here: the filing queue, duplicates, cloud-hostile names, the rename backlog, the structure
/// findings, and the rules that file without asking. Compare (two trees) and Storage (reads, never
/// writes) stay workspaces of their own; nothing else does.
///
/// ## Why a rail, when the chips worked
///
/// This replaces the retired `OrganizeFocus`, whose three chips were **absent at zero** — the argument being
/// that a rare finding announces itself when it happens and costs nothing when it does not. That
/// argument is still right about *badges*, and the badge rule below keeps it. It is wrong about
/// *places*, for a reason the chips could not have shown: **you cannot point at a chip that does
/// not exist yet.** "Organize this folder" — from a folder's context menu, from ⌘K — has to land
/// somewhere before any scan has found anything, and a chip that materialises only after a scan
/// has nowhere to land. So the rail item is permanent and the badge is not:
///
/// - **The item always exists.** Five of them — ``railItems``, in this order, whatever the counts
///   are. The enum carries six cases; `names` is folded into Renames and draws no rail item.
/// - **The badge is absent at zero** — not greyed, not "0". `badge(count:)` returns `nil`.
/// - **The overview is the unselected state**, not a sixth item. It is what the rail shows when
///   no lens is picked, so it needs no name of its own and cannot be "a tab you forget to visit".
///
/// ## No `effective` fallback any more
///
/// `OrganizeFocus` had to bounce you back to the queue when the list you were standing on
/// emptied, because the chip you were standing on had just vanished underneath you. A rail item
/// does not vanish, so an empty list is a place you can legitimately stand — it says "nothing
/// here" rather than becoming unreachable. Deleting that rule is the point of the change, not an
/// oversight: re-adding it would put back the one behaviour the rail exists to remove.
public enum OrganizeLens: String, CaseIterable, Identifiable, Sendable {

    /// Loose files and where they belong. Organize's default and the lens it opens on when a lens
    /// is opened at all.
    ///
    /// Named **"To File"**, not "File". Bare *File* is the menu; "to file" is the app's own noun
    /// for this list already — the summary row has said "24 to file" since the chips shipped — and
    /// it names the task rather than the object.
    case toFile = "ToFile"
    /// Identical content under different names or folders. A finding about one tree, which is why
    /// it stopped being a workspace: Compare's peer is another provider, not another list.
    case duplicates = "Duplicates"
    /// The names this provider will not accept.
    case names = "Names"
    /// Every name worth changing (ROADMAP 19), in three kinds: names this provider will not accept
    /// (the folded ``names`` lens), files that ignore the convention their folder keeps, and
    /// folders that have drifted from their own `NN. Mon YYYY` numbering. **The numbering is one
    /// of the three and the narrowest** — copy that names only it describes the pad section rather
    /// than the lens.
    case renames = "Renames"
    /// Where the tree disagrees with its own habits (ROADMAP 20).
    case restructure = "Restructure"
    /// The rules that file things without asking (ROADMAP 15). Configuration, not a finding —
    /// which is why ``carriesBadge`` says no for this one alone.
    case rules = "Rules"

    public var id: String { rawValue }

    /// Names folded into Renames (v4.0 polish P10): a provider-hostile name is one more kind of
    /// rename, both answers ride the same file-pass walk, and the backlog's "to fix" section is
    /// where the findings now live — present only when it reports, like every category there.
    ///
    /// **The case stays.** `rawValue` is persisted in ``defaultsKey``, so deleting it would turn
    /// a stored "Names" selection into silent data loss (the personIs lesson); and the scan
    /// machinery, counts and coverage questions still key on it. What folds is presentation:
    /// ``railItems`` omits it, and a stored `.names` selection resolves to `.renames`.
    public var isFoldedIntoRenames: Bool { self == .names }

    /// The items the rail draws — every lens that presents as its own place.
    public static var railItems: [OrganizeLens] { allCases.filter { !$0.isFoldedIntoRenames } }

    /// Where a selection of this lens actually lands — `.renames` for the folded lens, itself
    /// otherwise. The one migration seam for stored selections and programmatic routes alike.
    public var resolvedForPresentation: OrganizeLens {
        isFoldedIntoRenames ? .renames : self
    }

    /// The defaults key holding the rail selection. **Absent means the overview** — which is why
    /// the stored type is optional rather than carrying a seventh "overview" case: there is no
    /// value to write for "no lens picked", and inventing one would make the unselected state
    /// something you could fail to migrate.
    ///
    /// Declared here rather than beside `Workspace.defaultsKey` because `LensWorkspaceView` reads it
    /// directly — it owns the rail — and `MacApp` cannot be imported from this module.
    public static let defaultsKey = "selectedOrganizeLens"

    /// The rail's label.
    public var title: String {
        switch self {
        case .toFile: return "To File"
        case .duplicates: return "Duplicates"
        case .names: return "Names"
        case .renames: return "Renames"
        case .restructure: return "Restructure"
        case .rules: return "Rules"
        }
    }

    /// The rail item's glyph.
    ///
    /// **A glyph beside a number may not be a number.** `textformat.123` draws the literal digits
    /// `123`, which is why the rename backlog once rendered as "123 126 folders to rename"; that
    /// deny-list is still enforced by `OrganizeLensTests.noRailGlyphDrawsDigits`.
    public var symbol: String {
        switch self {
        case .toFile: return "doc"
        case .duplicates: return "doc.on.doc"
        case .names: return "character.cursor.ibeam"
        case .renames: return "folder.badge.gearshape"
        case .restructure: return "square.stack.3d.up"
        case .rules: return "wand.and.stars"
        }
    }

    /// Whether this lens can ever wear a count badge.
    ///
    /// **Rules cannot, and that is the whole distinction the badge draws.** Eight rules is a
    /// configuration you keep, not a result a scan turned up; a badge on it would report a
    /// standing number that never means "something needs you". Every other lens counts work.
    public var carriesBadge: Bool { self != .rules }

    /// The badge for a count: **`nil` at zero**, so a lens with nothing to report says nothing.
    ///
    /// This is the surviving half of the chips' argument. The item stays on the rail either way;
    /// what disappears is the claim that there is something to look at.
    public func badge(count: Int) -> Int? {
        guard carriesBadge, count > 0 else { return nil }
        return count
    }

    /// Whether Organize's scope narrows this lens — **false for Rules, and for the same reason
    /// ``carriesBadge`` is.**
    ///
    /// Five lenses report what a scan turned up *somewhere*, so "somewhere" is a narrowing that
    /// means something: scope To File to `Finance` and you get the loose files in Finance. Rules are
    /// configuration, and a rule's whole job is to move a file from where it is to somewhere else —
    /// **rules file into destinations all over the source.** Narrowing them by the folder you happen
    /// to be working leaves the standing configuration answering about a subtree it was never about.
    ///
    /// The concrete failure, which is what ROADMAP 15 calls the trap: Organize's overview offers the
    /// loose-files inbox as a one-click sticky scope ("Inbox (TODO) — 24 loose files"), and rules
    /// file *out of* that inbox into `Finance/…`, `Medical/…`, `Legal/…`. Scoped to `TODO`, **every
    /// rule's destination is outside the scope**, so the one rail item that is not allowed to say
    /// "nothing here" said exactly that with eight rules configured — and the only way to see them
    /// was to abandon the scope you were working, which is the one-way trip the item warns about.
    ///
    /// So opening Rules aims Organize back at the source root, and leaving it puts the scope back.
    /// **Nothing is written to do that** — the stored scope is untouched and merely goes unapplied
    /// while this lens is on screen — which is what makes "puts it back" unconditional rather than a
    /// restore step that some other exit path can skip. The chip stays on screen, suspended, so the
    /// scope is visibly parked rather than apparently lost.
    public var isScoped: Bool { self != .rules }
}

// MARK: - Scan provenance

extension OrganizeLens {

    /// Whether this lens's answer comes from the filing scan, and is therefore *stale while that
    /// scan runs*.
    ///
    /// Organize publishes `filingSuggestions`, `riskyNames` and `renamePlans` on completion, so
    /// mid-scan they still hold the previous answer — deliberately, so a cancelled rescan leaves
    /// the old results intact. A readout drawn from them during a scan is last scan's numbers over
    /// this scan's spinner.
    ///
    /// **Structure and rules are exempt, and that is not a detail.** Structure findings come from
    /// the folder profile with no disk read, and rules are configuration; neither goes stale
    /// because a filing scan is running. The old row gated the whole thing on `isSuggestingFiles`,
    /// which would have hidden a structure badge that was still perfectly true — the per-lens gate
    /// ROADMAP 20 asked for.
    public var goesStaleDuringFilingScan: Bool {
        switch self {
        case .toFile, .names, .renames: return true
        case .duplicates, .restructure, .rules: return false
        }
    }
}

// MARK: - Bridging to the lens apparatus

extension OrganizeLens {

    /// The ``WorkspaceLensKind`` whose search grammar, "N of M" readout and list apparatus this lens uses.
    ///
    /// The rail is the *vocabulary*; `WorkspaceLensKind` remains the *machinery* key — it owns the per-lens
    /// search grammars and scroll state, and those are keyed by apparatus rather than by rail item.
    /// Three rail items share `.filing`'s apparatus because their rows are filing rows; `.names`
    /// borrows `.rename`'s because that is where the risky-name grammar lives.
    ///
    /// `.restructure` has no apparatus of its own yet and answers `.filing`, so its query parks in
    /// the same slot rather than in a grammar that would read it differently.
    public var searchLens: WorkspaceLensKind {
        switch self {
        case .toFile, .renames, .restructure: return .filing
        case .duplicates: return .duplicates
        case .names: return .rename
        case .rules: return .automations
        }
    }

    /// The rail item a programmatic caller naming a ``WorkspaceLensKind`` is asking for.
    ///
    /// Not a strict inverse of ``searchLens`` and cannot be: three rail items share `.filing`, so
    /// this picks the one that *is* the filing queue. `.storage` answers `nil` — it is a workspace
    /// of its own, not a lens inside Organize, and a caller asking for it wants
    /// ``Workspace/storage``.
    ///
    /// **Never the folded case.** `.rename`'s findings live on the Renames rail item now, so it
    /// answers `.renames` directly — already resolved. A bridge that answered `.names` handed
    /// every caller a value that must not be stored or presented, and each one had to remember
    /// ``resolvedForPresentation`` for itself; `Workspace.destination(for:)` was that one caller,
    /// and now the resolution has one owner. Pinned by `LensFoldReachabilityTests`.
    public init?(_ lens: WorkspaceLensKind) {
        switch lens {
        case .filing: self = .toFile
        case .duplicates: self = .duplicates
        case .rename: self = .renames
        case .automations: self = .rules
        case .storage: return nil
        }
    }
}

// MARK: - What each item promises

extension OrganizeLens {

    /// What this item's tooltip says, in the state it is in.
    ///
    /// **On the lens rather than on the view, because it is the lens's own words** — the same place
    /// ``title``, ``symbol`` and ``carriesBadge`` live — and because a pure function of two enums
    /// can be asserted directly. It was a private method on `LensWorkspaceView` taking the *badge*, and
    /// `badge ?? 0` read a nil — which means "no number to show" — as zero, so a never-scanned queue
    /// said "0 loose files **this scan found**", asserting a scan that had not happened. That is
    /// exactly the conflation ``RailItemState`` splits apart, still being made by the words beside
    /// the states.
    ///
    /// Written to read correctly whether or not this is the selected item: selection is carried by
    /// the ring and by `.isSelected`, not by swapping the words. The description is one sentence
    /// per lens in every state, and only the leading count clause changes.
    func help(state: RailItemState) -> String {
        let what: String
        switch self {
        case .toFile:      what = "Loose files and where they belong."
        case .duplicates:  what = "Identical content under different names or folders."
        case .names:       what = "Names this provider will not accept, found on the filing scan. "
                                + "Shows the proposed fixes."
        case .renames:     what = "Names that need changing — to sync, to convention, to order: "
                                + "names this provider will not accept, files that ignore their "
                                + "folder's convention, and folders whose numbering has drifted."
        case .restructure: what = "Where the tree disagrees with its own habits — recurring folders "
                                + "that were shaped differently in different years."
        case .rules:       what = "The rules that file things without asking. Configuration, so "
                                + "this one never carries a count."
        }
        switch state {
        case .reporting(let count):
            // In full, unlike the badge — see `RailItemLabel.badgeText`, which abbreviates only
            // because six capsules share one row.
            return "\(count.formatted()) here. \(what)"
        case .clean:       return "Nothing here. \(what)"
        case .notScanned:  return "Not scanned here yet. \(what)"
        case .configuration: return what
        }
    }
}
