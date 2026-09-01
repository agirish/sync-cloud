import Testing
@testable import FileExplorer

/// Organize's rail rules — which items exist, which carry a badge, and what each one's apparatus
/// is.
///
/// These are pure so they can be asserted directly. What they cannot see is whether the view uses
/// them at all, which is why `OrganizeRailTests` mounts the header and reads pixels back: a rule
/// extracted for testability is one revert away from being decorative.
@Suite struct OrganizeLensTests {

    // MARK: The property the rail exists for

    @Test func everyLensIsAlwaysAPlace() {
        // The whole change from chips to a rail. A chip was absent at zero; a rail item is not,
        // because "Organize this folder" has to land somewhere before any scan has run. If this
        // ever starts filtering by count, pointed invocation loses its destination.
        #expect(OrganizeLens.allCases.count == 6)
        #expect(OrganizeLens.allCases.first == .toFile)
        // Storage is last, and the order is the argument: the rail runs act-heavy to act-never,
        // so the lens that only reports sits at the far end of it.
        #expect(OrganizeLens.allCases.last == .storage)
    }

    @Test func aBadgeIsAbsentAtZeroRatherThanShowingZero() {
        // The surviving half of the chips' argument: the place persists, the claim does not.
        // `nil` and not `0`, so the view cannot render a "0" by accident — there is no zero to
        // render.
        #expect(OrganizeLens.toFile.badge(count: 0) == nil)
        #expect(OrganizeLens.toFile.badge(count: 1) == 1)
        #expect(OrganizeLens.renames.badge(count: 17) == 17)
    }

    @Test func theTwoLensesThatCannotActNeverCarryABadge() {
        // A badge promises there is something HERE TO ACT ON. Two lenses cannot keep that promise,
        // for the same reason one step apart, and each is asserted at a NON-zero count — where a
        // rule that merely suppressed zeroes would pass and prove nothing.
        //
        // Rules: eight rules is a configuration you keep, not a result a scan turned up.
        #expect(OrganizeLens.rules.carriesBadge == false)
        #expect(OrganizeLens.rules.badge(count: 8) == nil)
        // Storage: its numbers are true and large — "9.4 GB reclaimable" — and it has no verb to
        // spend them on. A badge would be a to-do the lens cannot execute, which is exactly the
        // misread the badge rule exists to prevent.
        #expect(OrganizeLens.storage.carriesBadge == false)
        #expect(OrganizeLens.storage.badge(count: 62) == nil)
        for lens in OrganizeLens.allCases where lens != .rules && lens != .storage {
            #expect(lens.carriesBadge, "\(lens.rawValue) counts work and must be able to say so")
            #expect(lens.badge(count: 3) == 3)
        }
    }

    // MARK: The scope reaches five of the six — a different five from the badge's four

    @Test func rulesAreNotNarrowedByTheScopeAndEveryOtherLensIs() {
        // ROADMAP 15's trap. Rules file into destinations all over the source, so the folder you
        // happen to be working is not a narrowing of the standing configuration — and the concrete
        // failure was total: scoped to the loose-files inbox, every rule's destination is outside
        // it, so the one item that cannot say "nothing here" said exactly that with rules set up.
        #expect(OrganizeLens.rules.isScoped == false)
        for lens in OrganizeLens.allCases where lens != .rules {
            #expect(lens.isScoped, "\(lens.rawValue) reports findings somewhere and must narrow to it")
        }
    }

    @Test func theBadgeRuleAndTheScopeRuleAreTwoDifferentDistinctions() {
        // **This test used to assert the opposite, and the change is the point.** While Rules was
        // the only lens exempt from either rule, `carriesBadge` and `isScoped` described the same
        // set, and the old assertion — that they agree case for case — read as one distinction
        // said twice. It was a coincidence of there being a single exception, not a law.
        //
        // Storage separates them, deliberately:
        //   - badgeless, because a badge promises something to act on and Storage only reports;
        //   - scoped, because a treemap of `~/Documents/Media` is an honest picture of the root it
        //     names, so narrowing MEANS something here in a way it never can for a rule whose
        //     destinations lie all over the source.
        //
        // So the invariant is no longer agreement. It is that each exemption is named, with its
        // own reason — and a NEW lens exempt from either must come here and say which.
        #expect(OrganizeLens.allCases.filter { !$0.carriesBadge } == [.rules, .storage],
                "a lens stopped carrying a badge without saying why — a badge means work to do, so the exemption is a claim about the lens, not a detail")
        #expect(OrganizeLens.allCases.filter { !$0.isScoped } == [.rules],
                "a lens stopped honouring the scope chip — Rules is exempt because its destinations lie outside any scope; nothing else has that shape")
        // The one case that proves they are different questions. If this ever passes by agreement
        // again, the two rules have quietly re-merged and the reasons above have been lost.
        #expect(OrganizeLens.storage.carriesBadge == false)
        #expect(OrganizeLens.storage.isScoped == true)
    }

    // MARK: Staleness is per lens, not per workspace

    @Test func onlyTheLensesTheFilingScanRepublishesGoStale() {
        // The gate ROADMAP 20 asked for. The old row hid the whole summary while a filing scan
        // ran, which would have hidden a structure badge that was still perfectly true — structure
        // comes from the profile with no disk read, and rules are configuration.
        #expect(OrganizeLens.toFile.goesStaleDuringFilingScan)
        #expect(OrganizeLens.renames.goesStaleDuringFilingScan)
        #expect(!OrganizeLens.duplicates.goesStaleDuringFilingScan)
        #expect(!OrganizeLens.restructure.goesStaleDuringFilingScan)
        #expect(!OrganizeLens.rules.goesStaleDuringFilingScan)
        // Storage's report comes from its own analyzer pass over the tree, not from the filing
        // scan's published arrays, so a filing scan running does not make it stale.
        #expect(!OrganizeLens.storage.goesStaleDuringFilingScan)
    }

    // MARK: The apparatus bridge

    @Test func eachLensBorrowsTheApparatusThatFitsItsRows() {
        // `WorkspaceLensKind` is the machinery key — per-lens search grammars and parked queries hang off
        // it. Three rail items share `.filing`'s because their rows are filing rows; names borrows
        // Renames shares it too: its to-fix rows are filing-pass output like the rest.
        #expect(OrganizeLens.toFile.searchLens == .filing)
        #expect(OrganizeLens.renames.searchLens == .filing)
        #expect(OrganizeLens.restructure.searchLens == .filing)
        #expect(OrganizeLens.duplicates.searchLens == .duplicates)
        #expect(OrganizeLens.rules.searchLens == .automations)
        // Storage's apparatus already existed under this name while it was a workspace, so the
        // fold inherits its search grammar and "N of M" readout rather than minting one.
        #expect(OrganizeLens.storage.searchLens == .storage)
    }

    @Test func aCallerNamingALensGetsTheRailItemThatIsThatLens() {
        // Not a strict inverse of `searchLens` and cannot be — three items share `.filing`, so
        // this has to pick the one that IS the filing queue rather than whichever shares its
        // grammar.
        #expect(OrganizeLens(.filing) == .toFile)
        #expect(OrganizeLens(.duplicates) == .duplicates)
        #expect(OrganizeLens(.automations) == .rules)
        // Storage IS a rail item now. This assertion used to read `== nil`, on the grounds that
        // Storage was a workspace of its own and a caller naming it wanted `Workspace.storage`;
        // the fold is what inverted it.
        #expect(OrganizeLens(.storage) == .storage)
    }

    // MARK: Persistence and presentation

    @Test func theRawValuesAreStableAndDistinct() {
        // Persisted via @AppStorage(OrganizeLens.defaultsKey); renaming one silently drops that
        // user onto the overview.
        #expect(OrganizeLens.toFile.rawValue == "ToFile")
        #expect(OrganizeLens.duplicates.rawValue == "Duplicates")
        // "Names" is retired and must NOT come back as a live raw value — `Workspace`'s launch
        // migration rewrites a stored one to "Renames", and a case re-minting it would race that.
        #expect(!OrganizeLens.allCases.map(\.rawValue).contains("Names"))
        #expect(OrganizeLens.renames.rawValue == "Renames")
        #expect(OrganizeLens.restructure.rawValue == "Restructure")
        #expect(OrganizeLens.rules.rawValue == "Rules")
        // Deliberately the SAME string the retired `Workspace.storage` case used. The two live
        // under different defaults keys, so there is no collision — and matching it is what lets a
        // user who quit on the Storage tab land on the Storage lens rather than the overview.
        #expect(OrganizeLens.storage.rawValue == "Storage")
        let raws = OrganizeLens.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for lens in OrganizeLens.allCases {
            #expect(OrganizeLens(rawValue: lens.rawValue) == lens)
        }
        #expect(OrganizeLens(rawValue: "Overview") == nil)
    }

    @Test func theQueueIsCalledToFileRatherThanFile() {
        // "File" alone reads as the menu; "to file" is the app's own noun for this list and names
        // the task. Pinned because it is a wording decision someone will otherwise "tidy up".
        #expect(OrganizeLens.toFile.title == "To File")
        let titles = OrganizeLens.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(!titles.contains(""))
    }

    @Test func noRailGlyphDrawsDigits() {
        // `textformat.123` draws the literal digits `123`, so beside its own badge the rename item
        // rendered as "123 126". A deny-list on the FAMILY rather than an equality check on the
        // chosen symbol, so swapping one glyph for another in the same family still fails.
        let drawsDigits = ["textformat.123", "123.rectangle", "textformat.abc.dottedunderline"]
        for lens in OrganizeLens.allCases {
            #expect(!drawsDigits.contains(lens.symbol),
                    "\(lens.rawValue) wears a glyph that draws digits beside its own count")
        }
        let symbols = OrganizeLens.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
