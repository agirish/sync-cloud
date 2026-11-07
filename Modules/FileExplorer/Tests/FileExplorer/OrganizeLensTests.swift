import Testing
@testable import FileExplorer

/// Organize's rail rules: which items exist, which carry a badge, and what each one's apparatus is.
///
/// These are pure so they can be asserted directly. They can't see whether the view uses them,
/// which is why `OrganizeRailTests` mounts the header and reads pixels back.
@Suite struct OrganizeLensTests {

    // MARK: The property the rail exists for

    @Test func everyLensIsAlwaysAPlace() {
        // A rail item is never absent, even at zero, because "Organize this folder" has to land
        // somewhere before any scan has run. Filtering by count would leave it nowhere to go.
        #expect(OrganizeLens.allCases.count == 6)
        #expect(OrganizeLens.allCases.first == .toFile)
        // Storage is last: the rail runs from act-heavy to act-never, so the lens that only
        // reports sits at the far end.
        #expect(OrganizeLens.allCases.last == .storage)
    }

    @Test func aBadgeIsAbsentAtZeroRatherThanShowingZero() {
        // The place persists at zero; the badge does not. `nil`, not `0`, so the view has no zero
        // to render by accident.
        #expect(OrganizeLens.toFile.badge(count: 0) == nil)
        #expect(OrganizeLens.toFile.badge(count: 1) == 1)
        #expect(OrganizeLens.renames.badge(count: 17) == 17)
    }

    @Test func theTwoLensesThatCannotActNeverCarryABadge() {
        // A badge promises something here to act on, which two lenses can't keep. Each is asserted
        // at a non-zero count, where a rule that merely suppressed zeroes would pass and prove
        // nothing.
        //
        // Rules: eight rules is a configuration you keep, not a result a scan turned up.
        #expect(OrganizeLens.rules.carriesBadge == false)
        #expect(OrganizeLens.rules.badge(count: 8) == nil)
        // Storage: its numbers are true and large ("9.4 GB reclaimable"), but it has no verb to
        // spend them on, so a badge would be a to-do the lens can't execute.
        #expect(OrganizeLens.storage.carriesBadge == false)
        #expect(OrganizeLens.storage.badge(count: 62) == nil)
        for lens in OrganizeLens.allCases where lens != .rules && lens != .storage {
            #expect(lens.carriesBadge, "\(lens.rawValue) counts work and must be able to say so")
            #expect(lens.badge(count: 3) == 3)
        }
    }

    // MARK: The scope reaches five of the six — a different five from the badge's four

    @Test func rulesAreNotNarrowedByTheScopeAndEveryOtherLensIs() {
        // Rules file into destinations all over the source, so the folder you're working in is no
        // narrowing of the standing configuration. Scoped to the loose-files inbox, every rule's
        // destination is outside it, and Rules would say "nothing here" with rules set up.
        #expect(OrganizeLens.rules.isScoped == false)
        for lens in OrganizeLens.allCases where lens != .rules {
            #expect(lens.isScoped, "\(lens.rawValue) reports findings somewhere and must narrow to it")
        }
    }

    @Test func theBadgeRuleAndTheScopeRuleAreTwoDifferentDistinctions() {
        // `carriesBadge` and `isScoped` are different questions, and Storage separates them:
        //   - badgeless, because a badge promises something to act on and Storage only reports;
        //   - scoped, because a treemap of `~/Documents/Media` is an honest picture of the root it
        //     names, which narrowing can never be for a rule whose destinations lie all over the
        //     source.
        //
        // Each exemption is named with its own reason; a new lens exempt from either must come here
        // and say which.
        #expect(OrganizeLens.allCases.filter { !$0.carriesBadge } == [.rules, .storage],
                "a lens stopped carrying a badge without saying why — a badge means work to do, so the exemption is a claim about the lens, not a detail")
        #expect(OrganizeLens.allCases.filter { !$0.isScoped } == [.rules],
                "a lens stopped honouring the scope chip — Rules is exempt because its destinations lie outside any scope; nothing else has that shape")
        // The one case that proves they are different questions; if it ever agrees, the two rules
        // have quietly re-merged.
        #expect(OrganizeLens.storage.carriesBadge == false)
        #expect(OrganizeLens.storage.isScoped == true)
    }

    // MARK: Staleness is per lens, not per workspace

    @Test func onlyTheLensesTheFilingScanRepublishesGoStale() {
        // Staleness is per lens: hiding the whole summary while a filing scan runs would hide a
        // structure badge that is still true (structure comes from the profile with no disk read,
        // and rules are configuration).
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
        // `WorkspaceLensKind` is the machinery key: per-lens search grammars and parked queries
        // hang off it. Three rail items share `.filing`'s because their rows are filing-pass
        // output.
        #expect(OrganizeLens.toFile.searchLens == .filing)
        #expect(OrganizeLens.renames.searchLens == .filing)
        #expect(OrganizeLens.restructure.searchLens == .filing)
        #expect(OrganizeLens.duplicates.searchLens == .duplicates)
        #expect(OrganizeLens.rules.searchLens == .automations)
        // Storage keeps its own search grammar and "N of M" readout under this name.
        #expect(OrganizeLens.storage.searchLens == .storage)
    }

    @Test func aCallerNamingALensGetsTheRailItemThatIsThatLens() {
        // Not a strict inverse of `searchLens`, and can't be: three items share `.filing`, so this
        // picks the one that is the filing queue, not whichever shares its grammar.
        #expect(OrganizeLens(.filing) == .toFile)
        #expect(OrganizeLens(.duplicates) == .duplicates)
        #expect(OrganizeLens(.automations) == .rules)
        // Storage is a rail item, so a caller naming it gets the lens.
        #expect(OrganizeLens(.storage) == .storage)
    }

    // MARK: Persistence and presentation

    @Test func theRawValuesAreStableAndDistinct() {
        // Persisted via @AppStorage(OrganizeLens.defaultsKey); renaming one silently drops that
        // user onto the overview.
        #expect(OrganizeLens.toFile.rawValue == "ToFile")
        #expect(OrganizeLens.duplicates.rawValue == "Duplicates")
        // "Names" is retired and must not come back as a live raw value: `Workspace`'s launch
        // migration rewrites a stored one to "Renames", and a case re-minting it would race that.
        #expect(!OrganizeLens.allCases.map(\.rawValue).contains("Names"))
        #expect(OrganizeLens.renames.rawValue == "Renames")
        #expect(OrganizeLens.restructure.rawValue == "Restructure")
        #expect(OrganizeLens.rules.rawValue == "Rules")
        // Deliberately the same string the retired `Workspace.storage` case used, under a different
        // defaults key, so a user who quit on the Storage tab lands on the Storage lens rather than
        // the overview.
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
        // `textformat.123` draws the literal digits `123`, which beside a badge reads as "123 126".
        // A deny-list on the family, not an equality check on the chosen symbol, so swapping one
        // glyph for another in the same family still fails.
        let drawsDigits = ["textformat.123", "123.rectangle", "textformat.abc.dottedunderline"]
        for lens in OrganizeLens.allCases {
            #expect(!drawsDigits.contains(lens.symbol),
                    "\(lens.rawValue) wears a glyph that draws digits beside its own count")
        }
        let symbols = OrganizeLens.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
