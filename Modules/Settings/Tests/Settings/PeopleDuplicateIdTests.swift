import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// **What a `people.json` with a repeated person id does to the Settings pane.**
///
/// `people.json` is written to be hand-edited, and nothing rejects a repeated `id`. That used to
/// reach `PeopleList` as two entries with one id, where `allFacts` keyed them with
/// `Dictionary(uniqueKeysWithValues:)` and **trapped** on the duplicate — on the main actor, while
/// a settings pane rendered. Tolerant keying (`uniquingKeysWith:`) fixed the crash, and this file
/// was the regression test it shipped without.
///
/// **That crash is now unreachable from here, and this file changed shape because of it.**
/// `PersonRegistry.init(people:)` reduces the roster to one record per id before the store ever
/// sees it, so `allFacts` cannot meet a repeated key by any path a user can produce. The earlier
/// version of this suite asserted the opposite — that both copies survive — and said in as many
/// words that a store which deduplicated would make its own render test vacuous. It was right, so
/// the assertions below now pin the collapse instead of the duplication.
///
/// Two things follow, both deliberate:
///
/// - **`uniquingKeysWith:` stays** in `allFacts`. It is belt-and-braces now rather than the thing
///   standing between the user and a trap, and removing it would re-arm that trap the moment the
///   dedup above it regressed. A guard whose protection has moved upstream is not thereby wrong.
/// - **The crash guarantee lives in `PersonRegistryDuplicateIdTests`**, in the Sync package, where
///   the dedup is. What is tested *here* is what the pane draws — one row, from the record that
///   won — which is the part the Settings module owns.
///
/// The pre-fix failure was a Swift runtime trap, which cannot be caught in-process: there is no
/// `#expect(throws:)` for it and no death-test facility in swift-testing. Historically this file
/// drove the path in a real hosting view so that reinstating `uniqueKeysWithValues` killed the test
/// process rather than leaving a green suite; with the dedup in place that mutation is now caught
/// upstream instead, by the Sync suite, and no longer by this one.
@MainActor
@Suite struct PeopleDuplicateIdTests {

    /// Two people, one id — the shape a copy-pasted block leaves behind. The second entry differs in
    /// every other field, so "last wins" is a visible choice rather than a coincidence.
    private static let duplicated = """
    {"schemaVersion": 1, "people": [
      {"id": "girish", "displayName": "Girish", "relationship": "father",
       "fullNames": ["Girish Krishnamurthy"], "aliases": ["Dad"]},
      {"id": "girish", "displayName": "Girish K", "relationship": "father-in-law",
       "fullNames": ["Girish Kumar"]}]}
    """

    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("people-dup-\(UUID().uuidString)")
    }

    /// Writes `people.json` for profile `t` and opens a store over it — the real load path, not a
    /// roster handed in by hand, because the duplicate has to survive *decoding* to matter.
    private func storeOverFile(_ json: String, in dir: URL) throws -> PeopleStore {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("t/people.json"))
        return PeopleStore(directory: dir, profileId: "t", profile: nil)
    }

    /// Lays the view out in a real (never-ordered-in) borderless window — the same shape
    /// `PaneBarCustomizeSheetTests` uses — and reads the result back as pixels.
    ///
    /// A window rather than a bare hosting view because the pane's colours and materials resolve
    /// through one; never ordered in, so nothing appears on the machine running the tests.
    private func renderedInk(_ view: some View, width: CGFloat) -> (ink: Int, height: CGFloat) {
        let subject = view
            .frame(width: width, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: AnyView(subject))
        let height = max(1, host.fittingSize.height)
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = host
        // The layout that evaluates `body` — and with it `allFacts`, which is where the trap was.
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (0, height) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let background = rep.colorAt(x: 1, y: 1) else { return (0, height) }
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - background.redComponent),
                       max(abs(c.greenComponent - background.greenComponent),
                           abs(c.blueComponent - background.blueComponent))) > 0.04 { ink += 1 }
            }
        }
        return (ink, height)
    }

    private func vetoLog() -> PersonVetoLog {
        PersonVetoLog(userDefaults: ScratchDefaults("PeopleDuplicateIdTests"))
    }

    /// The premise, asserted before anything is rendered: the duplicate reaches the STORE, is
    /// collapsed there, and the survivor is the last entry the file listed.
    ///
    /// The fixture's two blocks differ in every field but the id, so "last wins" is a visible
    /// choice rather than a coincidence — a fixture whose two records agreed could not tell the
    /// rule from its opposite.
    @Test func aHandEditedRepeatedIdCollapsesToTheLastEntry() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try storeOverFile(Self.duplicated, in: dir)

        #expect(store.source == .file, "the file did not decode — this fixture is not a roster at all")
        #expect(store.people.map(\.id) == ["girish"],
                "the repeated id reached the store uncollapsed — `ForEach` would draw one row twice")
        #expect(store.people.map(\.displayName) == ["Girish K"],
                "the FIRST entry won, or the two were merged; the file's last block is the survivor")
        #expect(store.person(id: "girish")?.relationship == "father-in-law",
                "`person(id:)` still answers with the losing record")
        #expect(!store.rosterIsUnreadable, "a repeated id is valid JSON — it must not read as corrupt")
    }

    /// **The regression itself: the pane renders.** `PeopleList`'s body computes `allFacts` (it feeds
    /// `PeopleTester`), so laying this out is what used to trap.
    @Test func thePeoplePaneRendersARosterWithARepeatedId() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try storeOverFile(Self.duplicated, in: dir)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1)

        let drawn = renderedInk(
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: store, profile: nil, memory: nil,
                           providerRoot: nil, vetoLog: vetoLog())
            }
            .padding(16),
            width: width)

        // Survived — and drew a pane, rather than laying out to an empty strip. A crash never
        // reaches this line; a blank one would pass an "it did not crash" test and fail this.
        #expect(drawn.height > 100, "the pane laid out to \(drawn.height)pt — it drew almost nothing")
        #expect(drawn.ink > 2_000, "the pane rendered \(drawn.ink) inked pixels — it is blank")
    }

    /// **A repeated id draws ONE row, and that row is shorter than two distinct people's.**
    ///
    /// This assertion is the inverse of the one it replaces. Before the dedup, `ForEach` keyed on
    /// `Person.id` drew the first record *twice*, so a duplicated roster and a two-person roster
    /// laid out to the same height — which the earlier version of this test asserted, as a control
    /// for "a duplicate costs the pane nothing visible". It cost the pane a person: the second
    /// block's name, relationship and full names never reached the screen, and the row that did
    /// appear twice showed the FIRST record's name above the LAST record's facts, because
    /// `allFacts` resolved the id the other way round.
    ///
    /// Now the two rosters describe a different number of people and must not lay out alike. The
    /// height is measured rather than the ink, because it is the row COUNT that changed; the ink
    /// band below only guards against the one row having come out blank.
    @Test func aRepeatedIdDrawsOneRowFewerThanTwoDistinctPeople() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let distinct = try storeOverFile("""
        {"schemaVersion": 1, "people": [
          {"id": "girish", "displayName": "Girish", "relationship": "father",
           "fullNames": ["Girish Krishnamurthy"], "aliases": ["Dad"]},
          {"id": "girish-2", "displayName": "Girish K", "relationship": "father-in-law",
           "fullNames": ["Girish Kumar"]}]}
        """, in: dir)
        let dupDir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dupDir) }
        let duplicated = try storeOverFile(Self.duplicated, in: dupDir)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1)

        func pane(_ store: PeopleStore) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: store, profile: nil, memory: nil,
                           providerRoot: nil, vetoLog: vetoLog())
            }
            .padding(16)
        }
        let clean = renderedInk(pane(distinct), width: width)
        let repeated = renderedInk(pane(duplicated), width: width)

        #expect(repeated.height < clean.height, """
                the repeated-id pane is \(repeated.height)pt against \(clean.height)pt for two \
                distinct people — it is still drawing two rows for one person
                """)
        // The row that survived is really drawn, rather than the pane having collapsed to its
        // header: without this, deleting the row entirely would satisfy the height assertion above.
        #expect(repeated.ink > clean.ink / 3, """
                the repeated-id pane inked only \(repeated.ink) pixels against \(clean.ink) — the \
                surviving row is missing, not merely deduplicated
                """)
    }
}
