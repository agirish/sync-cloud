import Foundation

/// One of Organize's scans, and the lenses whose answers it publishes. The overview groups its
/// offers by this, so it can only offer scans that exist: To File and Renames come from one walk
/// (`LensWorkspaceView.RailCounts` marks both from `hasSuggestedFiling`), so they get one offer.
///
/// ``lenses`` and ``init(producing:)`` state the mapping from both sides, and `OrganizePassTests`
/// pins them as inverses. Grouping by hand in the view would fail silently: a lens missing from
/// every pass is never offered a scan, which looks exactly like a lens that has already run.
enum OrganizePass: String, CaseIterable, Identifiable, Sendable {

    /// One walk of the tree, publishing two lenses' answers together: the filing queue and the
    /// rename backlog, whose to-fix rows are the risky names found on the same pass.
    case file

    /// Hashing. The only pass that reads file *contents* rather than the tree's shape, which is why
    /// a single unpriced "scan everything" button would not be honest.
    case duplicates

    /// The folder survey behind Restructure. Not a scan of the tree: Restructure reads what the
    /// survey already learned, so it can be reporting while every other lens has never run.
    case folderMemory

    var id: String { rawValue }

    /// The lenses this pass answers, in rail order.
    ///
    /// Rules and Storage are in no pass. Rules is configuration, not a scan result; Storage's
    /// report has its own lifecycle and its own Re-analyze verb, so a scan button could not produce
    /// it. That is the line ``OrganizeLens/carriesBadge`` already draws, so `countedLenses` needs
    /// no code to exclude either.
    var lenses: [OrganizeLens] {
        switch self {
        case .file: return [.toFile, .renames]
        case .duplicates: return [.duplicates]
        case .folderMemory: return [.restructure]
        }
    }

    /// Whether this pass answers exactly one lens, and can therefore be re-run from that lens's own
    /// row without ambiguity. This decides which finding rows carry a rescan.
    ///
    /// The file pass answers two lenses, so a rescan on each row would be two controls doing one
    /// thing; its rescan stays on row 2, for the whole walk. A property of the pass, not the data:
    /// "offer it when this row is the pass's only reporting lens" would make the button appear and
    /// vanish with the tree's contents. Duplicates always has its rescan; To File never does.
    var answersOneLens: Bool { lenses.count == 1 }

    /// The words for re-running a pass whose answer is already on screen.
    ///
    /// Not ``runTitle``, which offers a scan that has never happened here and names the pass. This
    /// one sits beside an answer, so it names the act.
    ///
    /// `.file`'s arm is unreachable: only a pass with ``answersOneLens`` is offered from a row. It
    /// exists because the switch is total; the file pass's one control stays on row 2.
    var rescanTitle: String {
        switch self {
        case .file, .duplicates: return "Rescan"
        // Restructure runs no walk, so "rescan" would name something that doesn't happen. The
        // Rescan menu uses the same word for the same action, so the two read as one feature.
        // Not "Update folder memory": that is house vocabulary, and narrower than what it restores.
        case .folderMemory: return "Refresh"
        }
    }

    /// What VoiceOver reads for that control. A bare verb beside five other rows doesn't say which
    /// one it belongs to, so a one-word title gets the lens's name; a phrase already has its
    /// object. Testing for a space, not a literal verb, keeps it right through a rename.
    func rescanAccessibilityLabel(for lens: OrganizeLens) -> String {
        let isBareVerb = !rescanTitle.contains(" ")
        return isBareVerb ? "\(rescanTitle) \(lens.title)" : rescanTitle
    }

    /// The pass that produces this lens's answer, or `nil` for Rules and Storage, which have none.
    /// Derived from ``lenses`` rather than a second hand-written table.
    init?(producing lens: OrganizeLens) {
        guard let pass = Self.allCases.first(where: { $0.lenses.contains(lens) }) else {
            return nil
        }
        self = pass
    }

    /// The offer's headline: this pass has not run *here*, under Organize's current scope, which
    /// is not the same claim as "has never run".
    var offerTitle: String {
        switch self {
        case .file: return "The file pass hasn’t run here"
        case .duplicates: return "The duplicate pass hasn’t run here"
        case .folderMemory: return "The documents here haven’t been read"
        }
    }

    /// One line saying what the click buys, and for the file pass that it buys more than one thing.
    /// "Both" counts the rows under it, which are ``lenses``; `theFileCardLedeCountsTheRows` pins
    /// the word to the list.
    var offerLede: String {
        switch self {
        case .file:
            return "One walk of the tree answers both."
        case .duplicates:
            return "Finds identical content sitting under different names or folders."
        case .folderMemory:
            return "Restructure reads what your folders already contain, and nothing has been read yet."
        }
    }

    /// What the pass costs, stated on the card rather than in a tooltip. Saying the file pass is
    /// free matters because the lens around it has the one paid action in Organize (refine), and
    /// an unstated cost invites the assumption that any pass with a model behind it bills.
    var offerCost: String {
        switch self {
        case .file: return "Free, and on-device."
        case .duplicates: return "Free — and the slow one: every file in scope is hashed."
        case .folderMemory: return "Reads only the folders that changed since the last survey."
        }
    }

    /// The run button's words. Self-standing, not "Run it": the button is also the accessibility
    /// element, and VoiceOver reads it without the heading above.
    var runTitle: String {
        switch self {
        case .file: return "Run the File Pass"
        case .duplicates: return "Find Duplicates"
        // The same words the document survey's offer card uses, so the two are one feature.
        case .folderMemory: return "Read My Documents"
        }
    }

    /// The offer's glyph, borrowed where there is a control to borrow from, so the card and the
    /// button that do the same thing look the same.
    ///
    /// Duplicates asks the rail item rather than restating its glyph, so the two can't drift. The
    /// file pass answers two lenses, so no one rail item is its picture, and borrowing either would
    /// say the walk is about that lens. `doc.text.magnifyingglass` names what it does, reading
    /// every file, and collides with no other glyph on the overview or the rail.
    var symbol: String {
        switch self {
        case .file: return "doc.text.magnifyingglass"
        case .duplicates: return OrganizeLens.duplicates.symbol
        case .folderMemory: return "brain"
        }
    }
}
