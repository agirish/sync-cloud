import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// **A `people.json` with a repeated person id must not crash the app.**
///
/// `people.json` is written to be hand-edited, and nothing rejects a repeated `id`: `PeopleStore`
/// hands back exactly what was decoded, and only its own *add* path disambiguates. So a copy-pasted
/// person block whose id was not changed reaches `PeopleList` as two entries with one id — and
/// `PeopleList.allFacts` keyed them with `Dictionary(uniqueKeysWithValues:)`, which **traps** on a
/// duplicate key. On the main actor, while a settings pane renders. Keying tolerantly
/// (`uniquingKeysWith:`) is the fix; this is the regression test it shipped without.
///
/// **The honest limitation, stated because "it passes" would otherwise read as more than it is.**
/// The pre-fix failure is a Swift runtime trap, and a trap cannot be caught in-process — there is no
/// `#expect(throws:)` for it and no death-test facility in swift-testing. So this test does not
/// *observe* the trap; it drives the exact path that used to take it, in a real hosting view, so
/// that reinstating `uniqueKeysWithValues` kills the test process instead of leaving a green suite.
/// Verified that way: with the duplicate-tolerant keying reverted, this file's tests bring the run
/// down with `Fatal error: Duplicate values for key: '"girish"'`.
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

    /// The premise, asserted before anything is rendered: the duplicate really does reach the view.
    ///
    /// Without this the render below would prove nothing — a store that quietly deduplicated on load
    /// would hand `PeopleList` a one-person roster, `allFacts` would never see a repeated key, and
    /// the test would pass just as happily with the trapping keying restored.
    @Test func aHandEditedRosterKeepsBothCopiesOfARepeatedId() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try storeOverFile(Self.duplicated, in: dir)

        #expect(store.source == .file, "the file did not decode — this fixture is not a roster at all")
        #expect(store.people.map(\.id) == ["girish", "girish"],
                "the store deduplicated the repeated id, so nothing downstream can meet one")
        #expect(store.people.map(\.displayName) == ["Girish", "Girish K"],
                "the two entries are no longer distinguishable, so `last wins` is unobservable")
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

    /// The control, and it is what makes the number above mean something: the same measurement over
    /// a roster with **distinct** ids — the case that never trapped — lands in the same range. A
    /// duplicate id must cost the pane nothing visible, not merely fail to crash.
    ///
    /// **What the rendered pane actually shows, having looked at it.** Two rows, both drawn as the
    /// FIRST `girish` — SwiftUI's `ForEach` keys on `Person.id`, so the second record's name,
    /// relationship and full names never reach the screen. That is `ForEach`'s behaviour on a
    /// repeated id rather than anything this pane decides, and it is not what these tests are about;
    /// recorded because "it renders" would otherwise imply the second person is legible, and they
    /// are not. The roster is still readable, still editable and still saves — the file simply
    /// describes two people the list can only draw as one.
    @Test func aRepeatedIdDrawsTheSamePaneAsTwoDistinctPeople() throws {
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

        #expect(repeated.height == clean.height, """
                the repeated id changed the pane's height (\(repeated.height) vs \(clean.height)) — \
                one of its two rows is drawn differently
                """)
        // Both rosters draw two rows of near-identical text, so the ink counts should be close. A
        // generous band: this is a "the pane is all there" check, not a snapshot.
        #expect(abs(repeated.ink - clean.ink) < clean.ink / 4, """
                the repeated-id pane inked \(repeated.ink) pixels against \(clean.ink) for two \
                distinct people — a row is missing or drawn wrong
                """)
    }
}
