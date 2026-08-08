import Foundation

/// Which of Organize's lists is on screen.
///
/// Organize is one scan with more than one answer in it — the filing queue, and the cloud-hostile
/// names the same scan turned up on the way. This is which of them you are looking at. It is **not**
/// a lens selection: the header keeps saying Organize either way, because you have not gone
/// anywhere.
///
/// ## Why a selection and not a Bool
///
/// This replaces `showingRiskyNames`, which was correct for two states and does not survive a third.
/// Restructure's structure findings are that third (ROADMAP 20), and the moment there are two
/// findings beside the queue, two independent toggles can both be on and "back to the queue" stops
/// being a single well-defined move. A selection cannot disagree with itself, and adding the next
/// finding is a case here rather than another Bool that has to be kept out of step with this one.
///
/// The rules below are static and pure so they can be tested without mounting anything — but a rule
/// extracted for testability is one revert away from being unused, so `OrganizeFocusChipTests`
/// asserts the call site *paints* what they decide.
enum OrganizeFocus: String, CaseIterable, Identifiable {
    /// The filing queue: loose files and where they belong. Organize's default and its home.
    case queue
    /// The names this provider will not accept, found by the same scan.
    case names
    /// Folders that have drifted from their own `NN. Mon YYYY` convention, and the renames that
    /// would bring them back (ROADMAP 19). The third case this enum's doc comment was written for.
    case renames

    var id: String { rawValue }

    /// The chip's noun. The count is supplied because only the plural depends on it.
    func label(count: Int) -> String {
        switch self {
        case .queue: return "to file"
        case .names: return count == 1 ? "risky name" : "risky names"
        // The count is FOLDERS, not files — the unit of review and the unit of apply. A number that
        // said "38 to rename" beside a list of nine rows would be counting something the user
        // cannot point at.
        case .renames: return count == 1 ? "folder to rename" : "folders to rename"
        }
    }
}

extension OrganizeFocus {

    /// The focus actually on screen, given what the scan currently holds.
    ///
    /// A focus whose list has emptied falls back to `.queue`. Fixing the last risky name has to drop
    /// you into the queue rather than strand you on an empty list whose only way out is a chip that
    /// no longer exists — the invariant the old Bool carried inline as `&& !riskyNames.isEmpty`, kept
    /// because it is the one that makes this safe to store.
    static func effective(_ selected: OrganizeFocus, riskyNameCount: Int,
                          renamePlanCount: Int) -> OrganizeFocus {
        switch selected {
        case .names: return riskyNameCount == 0 ? .queue : .names
        case .renames: return renamePlanCount == 0 ? .queue : .renames
        case .queue: return .queue
        }
    }

    /// The chips Organize's summary row draws, in reading order.
    ///
    /// The queue leads because it is the place; a finding follows because it is what the scan turned
    /// up on the way there. **A finding at zero is absent** — not greyed, not "0" — which is the
    /// whole argument for reporting a rare condition on this row instead of giving it a tab of its
    /// own: a tab you have to remember to visit is a check nobody runs.
    ///
    /// The queue is the one member exempt from that, and only while a finding sits beside it. An
    /// empty queue with 17 risky names is a real state — the files are filed, the names are still
    /// wrong — and the radio group needs its first button on screen to be selectable back to. Alone
    /// and empty it draws nothing, exactly as today's results-gated pills do.
    static func chips(queueCount: Int, riskyNameCount: Int, renamePlanCount: Int) -> [OrganizeFocus] {
        var findings: [OrganizeFocus] = []
        if riskyNameCount > 0 { findings.append(.names) }
        if renamePlanCount > 0 { findings.append(.renames) }
        guard !findings.isEmpty else { return queueCount > 0 ? [.queue] : [] }
        return [.queue] + findings
    }

    /// The number a chip carries: **the whole list it names, never the filtered view of it.**
    ///
    /// A chip is a destination and its number is that destination's size. Two reasons it does not
    /// track the query. A chip for the list you are *not* looking at would otherwise be filtered by
    /// a query you cannot see — `searchQueries` is per-lens, so the other list's query is parked but
    /// still live. And navigation that renumbers itself as you type is a moving target.
    ///
    /// This is a deliberate change for the queue: "24 to file" used to be part of the filter's
    /// readout. That readout is not lost — the pills after these chips (`ready`, `unsure`, and the
    /// names' `folders`) still count the rows on screen, and `N of M` at the row's trailing edge
    /// still says how much the query hid. What moves is only the number that doubles as a signpost.
    static func count(_ focus: OrganizeFocus, queueCount: Int, riskyNameCount: Int,
                      renamePlanCount: Int) -> Int {
        switch focus {
        case .queue: return queueCount
        case .names: return riskyNameCount
        case .renames: return renamePlanCount
        }
    }
}
