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
/// This replaces ``OrganizeFocus``, whose three chips were **absent at zero** — the argument being
/// that a rare finding announces itself when it happens and costs nothing when it does not. That
/// argument is still right about *badges*, and the badge rule below keeps it. It is wrong about
/// *places*, for a reason the chips could not have shown: **you cannot point at a chip that does
/// not exist yet.** "Organize this folder" — from a folder's context menu, from ⌘K — has to land
/// somewhere before any scan has found anything, and a chip that materialises only after a scan
/// has nowhere to land. So the rail item is permanent and the badge is not:
///
/// - **The item always exists.** Six of them, in this order, whatever the counts are.
/// - **The badge is absent at zero** — not greyed, not "0". `badge(count:)` returns `nil`.
/// - **The overview is the unselected state**, not a seventh item. It is what the rail shows when
///   no lens is picked, so it needs no name of its own and cannot be "a tab you forget to visit".
///
/// ## No `effective` fallback any more
///
/// ``OrganizeFocus`` had to bounce you back to the queue when the list you were standing on
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
    /// Folders that have drifted from their own `NN. Mon YYYY` convention (ROADMAP 19).
    case renames = "Renames"
    /// Where the tree disagrees with its own habits (ROADMAP 20).
    case restructure = "Restructure"
    /// The rules that file things without asking (ROADMAP 15). Configuration, not a finding —
    /// which is why ``carriesBadge`` says no for this one alone.
    case rules = "Rules"

    public var id: String { rawValue }

    /// The defaults key holding the rail selection. **Absent means the overview** — which is why
    /// the stored type is optional rather than carrying a seventh "overview" case: there is no
    /// value to write for "no lens picked", and inventing one would make the unselected state
    /// something you could fail to migrate.
    ///
    /// Declared here rather than beside `Workspace.defaultsKey` because `TidyView` reads it
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
    /// deny-list is still enforced by `OrganizeFocusTests.noFocusGlyphDrawsDigits`.
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

    /// The ``TidyLens`` whose search grammar, "N of M" readout and list apparatus this lens uses.
    ///
    /// The rail is the *vocabulary*; `TidyLens` remains the *machinery* key — it owns the per-lens
    /// search grammars and scroll state, and those are keyed by apparatus rather than by rail item.
    /// Three rail items share `.filing`'s apparatus because their rows are filing rows; `.names`
    /// borrows `.rename`'s because that is where the risky-name grammar lives.
    ///
    /// `.restructure` has no apparatus of its own yet and answers `.filing`, so its query parks in
    /// the same slot rather than in a grammar that would read it differently.
    public var searchLens: TidyLens {
        switch self {
        case .toFile, .renames, .restructure: return .filing
        case .duplicates: return .duplicates
        case .names: return .rename
        case .rules: return .automations
        }
    }

    /// The rail item a programmatic caller naming a ``TidyLens`` is asking for.
    ///
    /// Not a strict inverse of ``searchLens`` and cannot be: three rail items share `.filing`, so
    /// this picks the one that *is* the filing queue. `.storage` answers `nil` — it is a workspace
    /// of its own, not a lens inside Organize, and a caller asking for it wants
    /// ``Workspace/storage``.
    public init?(_ lens: TidyLens) {
        switch lens {
        case .filing: self = .toFile
        case .duplicates: self = .duplicates
        case .rename: self = .names
        case .automations: self = .rules
        case .storage: return nil
        }
    }
}
