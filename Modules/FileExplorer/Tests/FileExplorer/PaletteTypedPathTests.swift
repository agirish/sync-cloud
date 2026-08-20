import Testing
import Foundation
@testable import FileExplorer

/// Go to Folder — Finder's ⇧⌘G as a behaviour rather than a surface.
///
/// **The split this suite exists to hold.** `typedPath(in:)` decides whether the user is typing a
/// path and what path it is; it does NOT decide whether that path exists, because the router is
/// pure and a `fileExists` inside it would make the whole routing table answer differently on two
/// machines. The existence check lives in `CommandPaletteState.resolvedDirectory(for:)`. So these
/// tests can assert the parse exhaustively without a filesystem, which is the point.
@Suite struct PaletteTypedPathTests {

    @Test(arguments: ["/", "/Users", "/Users/abhishek/Documents", "~", "~/Documents"])
    func anAbsoluteOrTildePathIsRecognised(query: String) {
        #expect(PaletteRouter.typedPath(in: query) != nil, "\(query) is a path and was not read as one")
    }

    /// **A bare name is not a path**, and this is the discriminating case. Treating `Documents` as
    /// one would shadow every recent and pinned folder the moment somebody typed a word that
    /// happens to be a directory in their home — the fuzzy matcher's whole job.
    @Test(arguments: ["Documents", "legal", "income tax", "organize legal", ""])
    func aBareNameIsNotAPath(query: String) {
        #expect(PaletteRouter.typedPath(in: query) == nil, "\(query) was read as a path")
    }

    @Test func tildeExpands() throws {
        let home = NSHomeDirectory()
        #expect(PaletteRouter.typedPath(in: "~") == home)
        #expect(PaletteRouter.typedPath(in: "~/Documents") == home + "/Documents")
    }

    /// A trailing slash is how people type a directory; `/Users/` and `/Users` are one place, and
    /// two rows for one folder is what a de-duplicating pass would otherwise have to clean up.
    @Test func aTrailingSlashIsTheSamePlace() {
        #expect(PaletteRouter.typedPath(in: "/Users/") == PaletteRouter.typedPath(in: "/Users"))
    }

    /// Root survives the trailing-slash trim rather than becoming the empty string — the one input
    /// where dropping the last character removes the whole path.
    @Test func rootStaysRoot() {
        #expect(PaletteRouter.typedPath(in: "/") == "/")
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(PaletteRouter.typedPath(in: "  /Users  ") == "/Users")
    }

    // MARK: The row it produces

    /// A resolved path outranks the best possible fuzzy match, because it is a statement of intent
    /// rather than a guess about one. `exact` is 400; the path row is 500.
    @Test func aResolvedPathOutranksEveryNameMatch() throws {
        let index = PaletteIndex(providers: [], providerRoot: "/Users/x/Documents",
                                 folders: ["Legal"], recentFolders: [], pinnedFolders: [])
        let rows = PaletteRouter.rows(query: "/Users", index: index, resolvedPath: "/Users")
        let first = try #require(rows.first, "no rows at all")
        #expect(first.route == .folder(path: "/Users"))
        #expect(first.score == 500)
    }

    /// **Without a resolved path, no path row** — the caller said the directory is not there, and a
    /// row that flickered in and out while someone typed a path would be worse than none.
    @Test func anUnresolvedPathOffersNoPathRow() {
        let index = PaletteIndex(providerRoot: "/Users/x/Documents", folders: ["Legal"])
        let rows = PaletteRouter.rows(query: "/nope", index: index, resolvedPath: nil)
        #expect(!rows.contains { $0.id.hasPrefix("path.") },
                "a path row was offered for a path the caller did not resolve")
    }

    /// The default keeps every existing call site honest: omitting `resolvedPath` must behave
    /// exactly as the router did before it existed.
    @Test func omittingTheArgumentOffersNoPathRow() {
        let index = PaletteIndex(providerRoot: "/Users/x/Documents", folders: ["Legal"])
        #expect(!PaletteRouter.rows(query: "/Users", index: index)
            .contains { $0.id.hasPrefix("path.") })
    }
}
