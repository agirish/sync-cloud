import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The flat workspace selection.
@Suite struct WorkspaceTests {

    // MARK: Reading a default from source

    /// The workspace case named at the end of the one line matching `anchor` in `MacApp/<name>`:
    /// an `@AppStorage` default on `ContentView`, which cannot be mounted, is reachable no other way.
    static func workspaceCase(inFile name: String, after anchor: String) throws -> String {
        let text = try macAppFile(name)
        let start = try #require(text.range(of: anchor),
                                 "\(name) no longer contains “\(anchor)” — the declaration moved or was reworded, and this test is now measuring nothing")
        // Exactly once: `range(of:)` returns the first match, so a doc comment quoting the
        // declaration would silently be read instead of the code.
        let occurrences = text.components(separatedBy: anchor).count - 1
        try #require(occurrences == 1,
                     "“\(anchor)” appears \(occurrences)× in \(name); this reads the first, which may not be the declaration")
        // The rest of that line, then the token after its first `.`: `.browse` from `= .browse`.
        let line = text[start.upperBound...].prefix { $0 != "\n" }
        let dot = try #require(line.firstIndex(of: "."), "no case named after “\(anchor)”")
        let caseName = line[line.index(after: dot)...]
            .prefix { $0.isLetter }
        let found = String(caseName)
        // Non-vacuity: an empty parse would compare "" to "" and pass.
        try #require(Workspace.allCases.map { String(describing: $0) }.contains(found),
                     "parsed “\(found)”, which is not a Workspace case")
        return found
    }

    // MARK: Persistence format

    @Test func testRestoresFromStoredRawValue() {
        for workspace in Workspace.allCases {
            #expect(Workspace(rawValue: workspace.rawValue) == workspace)
        }
        // An unrecognised stored value must fail the RawRepresentable init, which is what makes
        // @AppStorage fall back to its default rather than crash.
        #expect(Workspace(rawValue: "NotAWorkspace") == nil)
    }

    // MARK: The five-segment bar

    @Test func testTheBarIsFiveKindsOfPlace() {
        // Browse shows one tree, Compare holds two, Organize changes one, and Editor changes what is
        // inside one file. Everything else that moves a file in one tree is a lens inside Organize.
        #expect(Workspace.allCases.count == 4)
        #expect(Workspace.allCases.map(\.title)
                == ["Browse", "Compare", "Organize", "Edit"])
        // The raw values are the persistence format (`@AppStorage(Workspace.defaultsKey)`):
        // renaming one silently drops that user onto the default, which is why `title` is separate
        // and `Editor` stays though the title is "Edit".
        #expect(Workspace.allCases.map(\.rawValue)
                == ["Browse", "Differences", "Filing", "Editor"])
    }

    @Test func testEverySegmentHasItsOwnGlyph() {
        // At narrow widths the glyph is the only thing naming a workspace, so two sharing one
        // would be two unlabelled segments a user cannot tell apart.
        let symbols = Workspace.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains(""))
    }

    // MARK: Lens slots

    @Test func testEveryLensResolvesToSomewhereReachable() {
        #expect(Workspace.filing.lens == .filing)
        // Organize is the only workspace with a lens slot.
        #expect(Workspace.allCases.filter { $0.lens != nil } == [.filing])
    }
}
