import Testing
@testable import FileExplorer

/// What must hold with the Names lens retired. Its findings live in the Renames backlog, and it has
/// no case, so no lens exists that the rail can't draw. Builds 4.0 through 7.0 rewrote a stored
/// "Names" to Renames at launch.
@Suite struct OrganizeLensFoldTests {

    /// A stored "Names" no longer decodes. `@AppStorage` takes its default when a raw value doesn't
    /// resolve, and this key's default is absent, meaning the overview.
    @Test func theRetiredRawValueNoLongerDecodes() {
        #expect(OrganizeLens(rawValue: "Names") == nil)
        // The rest still do, so this is a statement about one retired case rather than about the
        // type having lost its `RawRepresentable` conformance.
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
