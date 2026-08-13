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
        #expect(OrganizeLens.allCases.last == .rules)
    }

    @Test func aBadgeIsAbsentAtZeroRatherThanShowingZero() {
        // The surviving half of the chips' argument: the place persists, the claim does not.
        // `nil` and not `0`, so the view cannot render a "0" by accident — there is no zero to
        // render.
        #expect(OrganizeLens.toFile.badge(count: 0) == nil)
        #expect(OrganizeLens.toFile.badge(count: 1) == 1)
        #expect(OrganizeLens.names.badge(count: 17) == 17)
    }

    @Test func rulesNeverCarryABadgeEvenWithRules() {
        // Eight rules is a configuration you keep, not a result a scan turned up. A badge there
        // would report a standing number that never means "something needs you" — and this is the
        // one distinction the badge draws, so it is asserted at a NON-zero count where a
        // count-only rule would pass.
        #expect(OrganizeLens.rules.carriesBadge == false)
        #expect(OrganizeLens.rules.badge(count: 8) == nil)
        for lens in OrganizeLens.allCases where lens != .rules {
            #expect(lens.carriesBadge, "\(lens.rawValue) counts work and must be able to say so")
            #expect(lens.badge(count: 3) == 3)
        }
    }

    // MARK: The scope reaches five of the six

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

    @Test func theTwoRulesAboutRulesAreTheSameDistinction() {
        // `carriesBadge` and `isScoped` are the same claim — this item is configuration, not a
        // result — said about two different surfaces. They are separate members because they are
        // read in different places, and asserting the agreement here is what would catch a third
        // lens being made unscoped without anyone re-asking whether it should still wear a badge.
        for lens in OrganizeLens.allCases {
            #expect(lens.carriesBadge == lens.isScoped,
                    "\(lens.rawValue) counts work but is unscoped (or the reverse) — decide which it is")
        }
    }

    // MARK: Staleness is per lens, not per workspace

    @Test func onlyTheLensesTheFilingScanRepublishesGoStale() {
        // The gate ROADMAP 20 asked for. The old row hid the whole summary while a filing scan
        // ran, which would have hidden a structure badge that was still perfectly true — structure
        // comes from the profile with no disk read, and rules are configuration.
        #expect(OrganizeLens.toFile.goesStaleDuringFilingScan)
        #expect(OrganizeLens.names.goesStaleDuringFilingScan)
        #expect(OrganizeLens.renames.goesStaleDuringFilingScan)
        #expect(!OrganizeLens.duplicates.goesStaleDuringFilingScan)
        #expect(!OrganizeLens.restructure.goesStaleDuringFilingScan)
        #expect(!OrganizeLens.rules.goesStaleDuringFilingScan)
    }

    // MARK: The apparatus bridge

    @Test func eachLensBorrowsTheApparatusThatFitsItsRows() {
        // `TidyLens` is the machinery key — per-lens search grammars and parked queries hang off
        // it. Three rail items share `.filing`'s because their rows are filing rows; names borrows
        // `.rename`'s because that is where the risky-name grammar lives.
        #expect(OrganizeLens.toFile.searchLens == .filing)
        #expect(OrganizeLens.renames.searchLens == .filing)
        #expect(OrganizeLens.restructure.searchLens == .filing)
        #expect(OrganizeLens.duplicates.searchLens == .duplicates)
        #expect(OrganizeLens.names.searchLens == .rename)
        #expect(OrganizeLens.rules.searchLens == .automations)
    }

    @Test func aCallerNamingALensGetsTheRailItemThatIsThatLens() {
        // Not a strict inverse of `searchLens` and cannot be — three items share `.filing`, so
        // this has to pick the one that IS the filing queue rather than whichever shares its
        // grammar.
        #expect(OrganizeLens(.filing) == .toFile)
        #expect(OrganizeLens(.duplicates) == .duplicates)
        // `.renames`, not the folded `.names`: the bridge answers the PRESENTED rail item, so no
        // caller can mint the folded case — see `TidyLensFoldReachabilityTests`.
        #expect(OrganizeLens(.rename) == .renames)
        #expect(OrganizeLens(.automations) == .rules)
        // Storage is still a workspace of its own, so it is NOT a rail item. A non-nil answer here
        // would mean Storage had been quietly folded in too.
        #expect(OrganizeLens(.storage) == nil)
    }

    // MARK: Persistence and presentation

    @Test func theRawValuesAreStableAndDistinct() {
        // Persisted via @AppStorage(OrganizeLens.defaultsKey); renaming one silently drops that
        // user onto the overview.
        #expect(OrganizeLens.toFile.rawValue == "ToFile")
        #expect(OrganizeLens.duplicates.rawValue == "Duplicates")
        #expect(OrganizeLens.names.rawValue == "Names")
        #expect(OrganizeLens.renames.rawValue == "Renames")
        #expect(OrganizeLens.restructure.rawValue == "Restructure")
        #expect(OrganizeLens.rules.rawValue == "Rules")
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
