import Testing
@testable import FileExplorer

/// Organize's rail rules: which items exist, which carry a badge, and what each one's apparatus is.
///
/// These are pure so they can be asserted directly. They can't see whether the view uses them,
/// which is why `OrganizeRailTests` mounts the header and reads pixels back.
@Suite struct OrganizeLensTests {

    // MARK: The property the rail exists for

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
