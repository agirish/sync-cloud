import Testing
@testable import FileExplorer

/// The Names→Renames fold (P10). What must hold: the case survives (its rawValue is persisted —
/// deleting it would turn a stored "Names" selection into silent data loss), the rail simply
/// stops drawing it, and every selection of it — stored or programmatic — lands on Renames.
@Suite struct OrganizeLensFoldTests {

    @Test func theCaseSurvivesForStoredSelections() {
        // A stored "Names" from before the fold must still decode…
        #expect(OrganizeLens(rawValue: "Names") == .names)
        // …and resolve to the lens that hosts its findings now.
        #expect(OrganizeLens.names.resolvedForPresentation == .renames)
        // Every other lens resolves to itself — the seam migrates one case, not a family.
        for lens in OrganizeLens.allCases where lens != .names {
            #expect(lens.resolvedForPresentation == lens)
        }
    }

    @Test func theRailDrawsEverythingButTheFoldedLens() {
        #expect(!OrganizeLens.railItems.contains(.names))
        #expect(OrganizeLens.railItems.count == OrganizeLens.allCases.count - 1)
        // Order is preserved — the fold removes one item, it does not reshuffle the rail.
        #expect(OrganizeLens.railItems == [.toFile, .duplicates, .renames, .restructure, .rules])
    }
}
