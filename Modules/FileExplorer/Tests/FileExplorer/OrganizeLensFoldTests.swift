import Testing
@testable import FileExplorer

/// What must hold with the Names lens retired: its findings live in the Renames backlog and it has
/// no case, so no lens exists that the rail can't draw.
@Suite struct OrganizeLensFoldTests {

    /// A stored "Names" no longer decodes. `@AppStorage` takes its default when a raw value doesn't
    /// resolve, and this key's default is absent, meaning the overview.
    @Test func theRetiredRawValueNoLongerDecodes() {
        #expect(OrganizeLens(rawValue: "Names") == nil)
// The rest still decode, so this is about one retired case, not a lost conformance.
        #expect(OrganizeLens(rawValue: "Renames") == .renames)
        #expect(OrganizeLens(rawValue: "ToFile") == .toFile)
    }

    /// Every case is a place you can go. Order matters as much as membership: the rail a user sees
    /// must stay exactly as it was.
    @Test func theRailDrawsEveryLens() {
        #expect(OrganizeLens.railItems == [.toFile, .duplicates, .renames, .restructure, .rules,
                                           .storage])
        #expect(OrganizeLens.railItems.count == OrganizeLens.allCases.count,
                "a lens exists that the rail does not draw — the state this retirement ended")
    }
}
