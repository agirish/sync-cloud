import Testing
@testable import FileExplorer

/// What must hold with the Names lens retired. Its findings live in the Renames backlog, and it has
/// no case: a stored "Names" is folded once, into the stored value, by
/// `Workspace.migrateOrganizeLens`, so no lens exists that the rail can't draw.
///
/// The migration itself is pinned in `WorkspaceTests` (it lives in `MacApp`, which this module
/// cannot import). What is pinned here is the half that makes the migration necessary.
@Suite struct OrganizeLensFoldTests {

    /// A stored "Names" no longer decodes, which is why the launch migration exists. `@AppStorage`
    /// takes its default when a raw value doesn't resolve, and this key's default is absent,
    /// meaning the overview: without the migration, someone who left the app in the rename backlog
    /// reopens it on the overview with nothing to explain the move.
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

    /// The `WorkspaceLensKind` bridge answers only lenses the rail draws: a caller storing what the
    /// bridge hands back must not end up selecting nothing.
    @Test func theBridgeAnswersOnlyRailItems() {
        for kind in WorkspaceLensKind.allCases {
            // The bridge is failable for a future kind added without a rail item; today every kind
            // maps to one.
            guard let item = OrganizeLens(kind) else { continue }
            #expect(OrganizeLens.railItems.contains(item),
                    "\(kind.rawValue) bridges to a lens the rail does not draw")
        }
    }
}
