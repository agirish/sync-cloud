import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// What a `people.json` with a repeated person id does to the Settings pane. The file is
/// hand-edited and nothing rejects a repeated `id`. `PersonRegistry.init(people:)` collapses the
/// roster to one record per id, so these tests pin the collapse and what the pane draws: one row,
/// from the record that won. The no-crash guarantee is `PersonRegistryDuplicateIdTests`, in Sync,
/// where the dedup is.
///
/// `allFacts` still keys with `uniquingKeysWith:`, as a backstop: `uniqueKeysWithValues:` would
/// trap on the main actor if the dedup ever regressed, and a trap can't be caught in-process.
///
/// The two render tests are `.machinePinned(.pixelSampling)` because `renderedInk` reads painted
/// pixels back with `colorAt`; the two that sample nothing run unpinned.
@MainActor
@Suite struct PeopleDuplicateIdTests {

    /// Two people, one id, as a copy-pasted block leaves behind. The entries differ in every other
    /// field, so "last wins" is visible.
    private static let duplicated = """
    {"schemaVersion": 1, "people": [
      {"id": "elder", "displayName": "Elder", "relationship": "father",
       "fullNames": ["Elder Forebear"], "aliases": ["Dad"]},
      {"id": "elder", "displayName": "Elder F", "relationship": "father-in-law",
       "fullNames": ["Elder Kumar"]}]}
    """

    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("people-dup-\(UUID().uuidString)")
    }

    /// Writes `people.json` for profile `t` and opens a store over it: the real load path, because
    /// the duplicate has to survive decoding to matter.
    private func storeOverFile(_ json: String, in dir: URL) throws -> PeopleStore {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("t/people.json"))
        return PeopleStore(directory: dir, profileId: "t", profile: nil)
    }

    /// Lays the view out in a borderless window, as `PaneBarCustomizeSheetTests` does, and reads
    /// the result back as pixels. A window because the pane's colours and materials resolve through
    /// one; never ordered in, so nothing appears on screen.
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
        // The layout that evaluates `body`, and with it `allFacts`.
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

    /// Pins the backstop: `allFacts` keeps `uniquingKeysWith:`. No input can reach it with a
    /// repeated key, so reverting to `uniqueKeysWithValues:` would leave every other test green
    /// until the dedup broke too. A source scan, because a duplicate can no longer be driven there.
    @Test func theFactsMapStaysTolerantOfARepeatedKey() throws {
        let source = try settingsSource("SettingsView.swift")
        let facts = try #require(source.range(of: "private var allFacts:"),
                                 "`allFacts` is gone or renamed — this scan now proves nothing")
        let body = String(source[facts.lowerBound...].prefix(400))
        #expect(body.contains("uniquingKeysWith:"), """
                `allFacts` no longer keys tolerantly. It cannot trap today, because the roster is \
                collapsed before it — but that makes this the half that fails silently when the \
                other half regresses.
                """)
        #expect(!body.contains("uniqueKeysWithValues:"),
                "`allFacts` traps on a repeated key again")
    }

    /// The premise, before anything renders: the duplicate reaches the store, is collapsed there,
    /// and the survivor is the file's last entry. The two blocks differ in every field but the id,
    /// so the test can tell "last wins" from its opposite.
    @Test func aHandEditedRepeatedIdCollapsesToTheLastEntry() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try storeOverFile(Self.duplicated, in: dir)

        #expect(store.source == .file, "the file did not decode — this fixture is not a roster at all")
        #expect(store.people.map(\.id) == ["elder"],
                "the repeated id reached the store uncollapsed — `ForEach` would draw one row twice")
        #expect(store.people.map(\.displayName) == ["Elder F"],
                "the FIRST entry won, or the two were merged; the file's last block is the survivor")
        #expect(store.person(id: "elder")?.relationship == "father-in-law",
                "`person(id:)` still answers with the losing record")
        #expect(!store.rosterIsUnreadable, "a repeated id is valid JSON — it must not read as corrupt")
    }

    /// The pane renders a roster with a repeated id. `PeopleList`'s body computes `allFacts` (it
    /// feeds `PeopleTester`), so laying it out exercises the keying.
    @Test(.machinePinned(.pixelSampling)) func thePeoplePaneRendersARosterWithARepeatedId() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try storeOverFile(Self.duplicated, in: dir)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1)

        let drawn = renderedInk(
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: store, profile: nil, memory: nil,
                           vetoLog: vetoLog())
            }
            .padding(16),
            width: width)

        // Drew a pane, not an empty strip: a blank render would pass a bare "didn't crash" test.
        #expect(drawn.height > 100, "the pane laid out to \(drawn.height)pt — it drew almost nothing")
        #expect(drawn.ink > 2_000, "the pane rendered \(drawn.ink) inked pixels — it is blank")
    }

    /// A repeated id draws the surviving record, plus a note saying why edits won't save. Compared
    /// against the one-person roster it collapses to: the duplicated pane must be taller by about a
    /// line, not a row, and draw more ink. A comparison against a two-person roster can't separate
    /// "one row plus a note" from "two rows".
    @Test(.machinePinned(.pixelSampling)) func aRepeatedIdDrawsTheSurvivingRecordAndSaysEditsAreHeld() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The roster the duplicated one collapses to: the file's last `elder` block, alone, so any
        // difference between the two panes is the note.
        let equivalent = try storeOverFile("""
        {"schemaVersion": 1, "people": [
          {"id": "elder", "displayName": "Elder F", "relationship": "father-in-law",
           "fullNames": ["Elder Kumar"]}]}
        """, in: dir)
        let dupDir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dupDir) }
        let duplicated = try storeOverFile(Self.duplicated, in: dupDir)
        let width = SettingsSheetMetrics.contentWidth(textScale: 1)

        func pane(_ store: PeopleStore) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: store, profile: nil, memory: nil,
                           vetoLog: vetoLog())
            }
            .padding(16)
        }
        // The premise: one store holds back its edits and the other doesn't.
        #expect(duplicated.repeatedRosterIds == ["elder"])
        #expect(equivalent.repeatedRosterIds.isEmpty)

        let one = renderedInk(pane(equivalent), width: width)
        let repeated = renderedInk(pane(duplicated), width: width)

        // The harness renders at all, or the comparisons below could be two blank renders.
        #expect(one.ink > 2_000, "the one-person pane inked \(one.ink) pixels — it is blank")

        #expect(repeated.height > one.height, """
                the repeated-id pane (\(repeated.height)pt) is no taller than the same roster \
                without the duplicate (\(one.height)pt) — the note saying edits are held is missing
                """)
        // A note is a line of text, not a row: the bound fails if the dropped record is drawn again.
        #expect(repeated.height - one.height < 80, """
                the repeated-id pane is \(repeated.height - one.height)pt taller than the same \
                roster without the duplicate — that is more than a note; a row came back
                """)
        #expect(repeated.ink > one.ink, "the note draws no pixels")
    }
}
