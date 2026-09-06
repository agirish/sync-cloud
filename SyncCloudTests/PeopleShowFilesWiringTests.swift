import Testing
import Foundation
import Settings
import Sync
@testable import SyncCloud

/// Settings ▸ People's "Show Their Files" — the button that takes a person from the roster to the
/// documents the row is counting.
///
/// **The whole feature is a closure passed across a package wall**, and neither end can see the
/// other. `SettingsView` takes `onShowPerson` and would render a row with no button if the app
/// passed nil; `ContentView` owns `acceptPersonScope`, which is a method on a SwiftUI `View`
/// struct holding a sync manager and an `@AppStorage` pair, so no test can call it. Between them
/// is exactly the shape this repo keeps shipping broken: an offer whose accept does nothing.
///
/// So this scans the one call site. `MacApp` belongs to no SPM package — only the app target
/// compiles it — so a Settings-side test could not see it at all, which is the coverage gap
/// `SettingsTab.cloudRefineSetup` was minted for.
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

    /// The sheet hands People's button the gather, and closes itself first.
    ///
    /// **Both halves matter.** Without `onShowPerson` the row draws no button and the feature is
    /// invisible; without `showSettings = false` the gather lands in the pane *behind* a modal
    /// sheet, so the user clicks, the sheet stays, and nothing appears to happen — which is the
    /// same "nothing happened" with a different cause.
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

    /// It goes through `acceptPersonScope`, which is the ONE door onto STARTING a gather.
    ///
    /// That method holds the double-accept race's cancellation, the last-write-wins guard, and the
    /// "no survey on this Mac" message. A second path that set `personScope` by hand would have
    /// none of them, and would be indistinguishable in a screenshot.
    ///
    /// A count, because the alternative — proving each write sits inside one of three named
    /// functions — is a brace-matching parser, and this is a canary rather than a proof. Five
    /// writes, all accounted for: two in `acceptPersonScope` (the no-survey refusal and
    /// `.gathering`), two in its task body (`.ready` and the failure), and one in
    /// `recordPersonVerdict`, which rewrites a scope already on screen rather than starting one.
    /// A sixth is a new door and has to justify itself here.
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
