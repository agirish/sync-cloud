import Foundation

/// One of Organize's scans, and the lenses whose answers it publishes.
///
/// **The overview offered five scans, and there are three.** Its footer drew one
/// `Scan…` per unscanned lens — "To File — not scanned", "Names — not scanned",
/// "Renames — not scanned" — which reads as three independent pieces of work you could
/// choose between. They are one walk. `FileSyncManager+Filing.swift` says so at the site:
/// *"Names, on the pass that is already here"*, and `TidyView.RailCounts` flips two of the
/// three from a single flag:
///
/// ```swift
/// if syncManager.hasSuggestedFiling { ran.insert(.toFile); ran.insert(.renames) }
/// ```
///
/// There is no way to scan Names without scanning To File, so offering that choice was
/// offering something the machinery cannot do. This type is what the overview groups by, so
/// the screen can only ever offer scans that exist.
///
/// ## Why a type and not three literals in the view
///
/// The mapping is asserted from two directions — ``lenses`` names what a pass answers, and
/// ``init(producing:)`` names what answers a lens — and `OrganizePassTests` pins them as
/// inverses over every case. A view that grouped by hand would let the two drift the moment a
/// seventh lens arrives, and the failure would be silent: a lens missing from every pass
/// simply never gets offered a scan, which looks exactly like a lens that has already run.
enum OrganizePass: String, CaseIterable, Identifiable, Sendable {

    /// One walk of the tree, publishing **three** lenses' answers together: the filing queue,
    /// the risky names found on the same pass, and the folder-rename backlog.
    case file

    /// Hashing. The only pass that reads file *contents* rather than the tree's shape, and the
    /// reason a single unpriced "scan everything" button was never honest.
    case duplicates

    /// The folder survey behind Restructure. **Not a scan of the tree** — Restructure runs no
    /// walk of its own; it reads what the survey already learned, which is why the lens can be
    /// reporting while the other five have never run.
    case folderMemory

    var id: String { rawValue }

    /// The lenses this pass answers, in rail order.
    ///
    /// Rules appears in no pass and that is the whole of its difference: it is configuration you
    /// keep, never a result a scan turned up — the same distinction ``OrganizeLens/carriesBadge``
    /// draws, and the reason `overviewSections` returns `nil` for it.
    var lenses: [OrganizeLens] {
        switch self {
        case .file: return [.toFile, .names, .renames]
        case .duplicates: return [.duplicates]
        case .folderMemory: return [.restructure]
        }
    }

    /// The pass that produces this lens's answer, or `nil` for Rules — which has none.
    ///
    /// Deliberately the inverse of ``lenses`` rather than a second hand-written table; see the
    /// type's own note for why the two are pinned against each other.
    init?(producing lens: OrganizeLens) {
        guard let pass = Self.allCases.first(where: { $0.lenses.contains(lens) }) else {
            return nil
        }
        self = pass
    }

    /// The offer's headline, written for the state it is drawn in: this pass has not run
    /// **here** — under whatever scope Organize is pointed at, which is not the same claim as
    /// "has never run".
    var offerTitle: String {
        switch self {
        case .file: return "The file pass hasn’t run here"
        case .duplicates: return "The duplicate pass hasn’t run here"
        case .folderMemory: return "Folder memory hasn’t surveyed this tree"
        }
    }

    /// One line saying what the click buys, and — for the file pass — that it buys three things.
    var offerLede: String {
        switch self {
        case .file:
            return "One walk of the tree answers all three."
        case .duplicates:
            return "Finds identical content sitting under different names or folders."
        case .folderMemory:
            return "Restructure reads what your folders already contain, and nothing has been read yet."
        }
    }

    /// What the pass costs, stated on the card rather than in a tooltip.
    ///
    /// **The file pass is free.** That is worth stating because the surrounding lens spends: the
    /// refine control is the one paid action in Organize, and `TidyView.refineFilingSuggestions`
    /// is explicit that "the scan that produced these rows was free and on-device". A card that
    /// left the cost unsaid invites the assumption that any pass with a model behind it bills.
    var offerCost: String {
        switch self {
        case .file: return "Free, and on-device."
        case .duplicates: return "Free — and the slow one: every file in scope is hashed."
        case .folderMemory: return "Reads only the folders that changed since the last survey."
        }
    }

    /// The run button's words. **Self-standing**, not "Run it": the button is also the
    /// accessibility element, and a label that only makes sense beside the heading above it is a
    /// label VoiceOver reads as nothing at all.
    var runTitle: String {
        switch self {
        case .file: return "Run the file pass"
        case .duplicates: return "Find duplicates"
        case .folderMemory: return "Update folder memory"
        }
    }

    /// The offer's glyph — each borrowed from the control that already runs this pass elsewhere,
    /// so the card and the toolbar button that do the same thing look like the same thing.
    var symbol: String {
        switch self {
        case .file: return FilingGlyph.lens
        case .duplicates: return "wand.and.stars"
        case .folderMemory: return "brain"
        }
    }
}
