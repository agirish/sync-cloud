import Testing
import Foundation
import Settings
import Sync
@testable import SyncCloud

/// Organize ▸ People's "Show Their Files", the button that takes a person from the roster to the
/// documents the row counts. The feature is a closure passed across a package wall: `SettingsView`
/// draws no button if `onShowPerson` is nil, and `ContentView.acceptPersonScope` lives on a
/// SwiftUI `View` no test can call. So this scans the one call site; `MacApp` is in no SPM package,
/// so a Settings-side test can't see it.
@Suite struct PeopleShowFilesWiringTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scans would be near-vacuous")
        return text
    }

    /// The sheet hands People's button the gather, and closes itself first. Without `onShowPerson`
    /// the row has no button; without `showSettings = false` the gather lands behind the modal sheet
    /// and the click appears to do nothing.
    @Test func theSettingsSheetHandsPeopleTheGather() throws {
        let content = try Self.source("ContentView.swift")
        let code = sourceCodeOnly(content)
        #expect(code.contains("onShowPerson:"),
                "SettingsView is built without onShowPerson — People's rows draw no Show Their Files button")
        let call = try #require(code.range(of: "onShowPerson:"))
        let after = String(code[call.upperBound...].prefix(220))
        #expect(after.contains("showSettings = false"),
                "the sheet is not closed first — the gather would land behind the Settings panel")
        #expect(after.contains("acceptPersonScope(person)"),
                "People's button no longer reaches acceptPersonScope — the same gather ⌘K's People rows use")
    }

    /// It goes through `acceptPersonScope`, the one way to start a gather, which holds the
    /// double-accept cancellation, the last-write-wins guard and the "no survey on this Mac"
    /// message. A path that set `personScope` by hand would skip all three.
    ///
    /// A count, a canary rather than a proof. The five writes: two in `acceptPersonScope` (the
    /// no-survey refusal and `.gathering`), two in its task body (`.ready` and the failure), and
    /// one in `recordPersonVerdict`, which rewrites a scope already on screen. A sixth must justify
    /// itself here.
    @Test func thereIsStillOnlyOneDoorOntoTheGather() throws {
        let content = try Self.source("ContentView.swift")
        let code = sourceCodeOnly(content)
        #expect(code.contains("func acceptPersonScope"),
                "stripping comments emptied the file — the count below would be meaningless")
        let writes = code.components(separatedBy: "personScope = PersonScope(").count - 1
        #expect(writes == 5, """
            \(writes) places construct a PersonScope, not 5. Every one has to be inside \
            acceptPersonScope, its task body, or recordPersonVerdict — a new writer elsewhere is a \
            gather without the cancellation and the last-write-wins guard.
            """)
    }
}
