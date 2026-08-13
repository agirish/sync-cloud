import Testing
@testable import FileExplorer

/// **The Names lens is retired, and this is what must hold now that it is.**
///
/// It was a rail item until the v4.0 polish folded its findings into the Renames backlog (P10), and
/// for a while after that it was a *case without a place*: kept only so a stored "Names" selection
/// would decode, with `resolvedForPresentation` folding it at every point of use. That arrangement
/// cost more than it bought — the pass card went on listing it as a destination for a whole
/// release, because `OrganizePass.lenses` correctly still named a lens the screen had no room for —
/// so the case is gone and the fold happens once, in `Workspace.migrateOrganizeLens`, into the
/// stored value.
///
/// The migration itself is pinned in `WorkspaceTests` (it lives in `MacApp`, which this module
/// cannot import). What is pinned here is the half that makes the migration necessary.
@Suite struct OrganizeLensFoldTests {

    /// A stored "Names" no longer decodes — which is exactly why the launch migration exists.
    ///
    /// **This is the failure mode, not a triviality.** `@AppStorage` takes its default when a raw
    /// value does not resolve, and this key's default is *absent*, meaning the overview. Without
    /// the migration, someone who left the app in the rename backlog reopens it on the overview
    /// with nothing to explain the move.
    @Test func theRetiredRawValueNoLongerDecodes() {
        #expect(OrganizeLens(rawValue: "Names") == nil)
        // The rest still do, so this is a statement about one retired case rather than about the
        // type having lost its `RawRepresentable` conformance.
        #expect(OrganizeLens(rawValue: "Renames") == .renames)
        #expect(OrganizeLens(rawValue: "ToFile") == .toFile)
    }

    /// Every case is a place you can go, which was not true for the whole of P10.
    ///
    /// Order matters as much as membership: the retirement removes an item that was already
    /// undrawn, so the rail a user sees must be byte-for-byte the rail they saw yesterday.
    @Test func theRailDrawsEveryLens() {
        #expect(OrganizeLens.railItems == [.toFile, .duplicates, .renames, .restructure, .rules])
        #expect(OrganizeLens.railItems.count == OrganizeLens.allCases.count,
                "a lens exists that the rail does not draw — the state this retirement ended")
    }

    /// The `WorkspaceLensKind` bridge answers only lenses the rail draws.
    ///
    /// Inherited from the retired `LensFoldReachabilityTests`, which pinned the same rule while the
    /// bridge could still mint the folded case: a caller storing what the bridge hands back must
    /// not end up selecting nothing.
    @Test func theBridgeAnswersOnlyRailItems() {
        for kind in WorkspaceLensKind.allCases {
            guard let item = OrganizeLens(kind) else { continue }   // `.storage` is a workspace
            #expect(OrganizeLens.railItems.contains(item),
                    "\(kind.rawValue) bridges to a lens the rail does not draw")
        }
    }
}
