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
///
/// **`.machinePinned(.pixelSampling)`** — `renderedInk` below reads painted pixels back out of a
/// live renderer (`bitmapImageRepForCachingDisplay` + `cacheDisplay` + `colorAt`), which is the
/// declared meaning of that reason, so this suite has to stand down wherever its siblings do.
/// It shipped as a bare `@Suite` under a commit message that claimed otherwise. There is no
/// consequence while CI is this same Mac and excludes only `referenceImages,liveProfile` — but
/// the day the runner moves, the undeclared suite is the one still sampling an uncalibrated
/// renderer while every suite that declared itself correctly steps aside.
///
/// The trait is applied to the whole suite, as every pinned suite in this repo applies it, which
/// does take the two members that sample nothing — the source scan and the collapse assertions —
/// down with it. That is the accepted cost of the one-token declaration: a per-test gate is the
/// shape that gets forgotten by a renamer, which is the gap `MachinePinnedReason` was minted to
/// close.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct PeopleDuplicateIdTests {

    /// Two people, one id — the shape a copy-pasted block leaves behind. The second entry differs in
    /// every other field, so "last wins" is a visible choice rather than a coincidence.
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

    /// **The guard this suite says stays, enforced rather than asserted in prose.**
    ///
    /// The header above records a decision: `allFacts` keeps `uniquingKeysWith:` even though the
    /// collapse upstream means no user input can now reach it with a repeated key. A guard kept for
    /// a regression that has not happened yet is exactly the kind that gets "tidied" — and with no
    /// test naming it, reverting that one call to `Dictionary(uniqueKeysWithValues:)` leaves the
    /// entire repository green, because the trap is unreachable until the day the dedup breaks, at
    /// which point both halves are gone at once.
    ///
    /// A source scan rather than a behavioural test, deliberately: there is no longer a way to
    /// *drive* a duplicate into `allFacts`, so there is nothing to assert about. What is left worth
    /// pinning is the text of the decision.
    @Test func theFactsMapStaysTolerantOfARepeatedKey() throws {
        let source = try Self.settingsSource()
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

    /// Reads `SettingsView.swift` off disk. `#filePath` walks up from the test file rather than
    /// hardcoding a checkout location, so it works in any worktree.
    private static func settingsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)          // …/Tests/Settings/PeopleDuplicateIdTests.swift
            .deletingLastPathComponent()                     // …/Tests/Settings
            .deletingLastPathComponent()                     // …/Tests
            .deletingLastPathComponent()                     // …/Settings (module)
            .appendingPathComponent("Sources/Settings/SettingsView.swift")
        return try String(contentsOf: root, encoding: .utf8)
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
        #expect(store.people.map(\.id) == ["elder"],
                "the repeated id reached the store uncollapsed — `ForEach` would draw one row twice")
        #expect(store.people.map(\.displayName) == ["Elder F"],
                "the FIRST entry won, or the two were merged; the file's last block is the survivor")
        #expect(store.person(id: "elder")?.relationship == "father-in-law",
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
                           vetoLog: vetoLog())
            }
            .padding(16),
            width: width)

        // Survived — and drew a pane, rather than laying out to an empty strip. A crash never
        // reaches this line; a blank one would pass an "it did not crash" test and fail this.
        #expect(drawn.height > 100, "the pane laid out to \(drawn.height)pt — it drew almost nothing")
        #expect(drawn.ink > 2_000, "the pane rendered \(drawn.ink) inked pixels — it is blank")
    }

    /// **A repeated id draws the surviving record, and says why edits will not save.**
    ///
    /// Two earlier versions of this test are worth knowing about, because both measured the wrong
    /// thing. The first asserted that a duplicated roster and a two-person roster lay out to the
    /// SAME height — a control for "a duplicate costs the pane nothing visible", true only because
    /// `ForEach` keyed on `Person.id` drew the first record twice. The second inverted it after the
    /// collapse landed: one row must be shorter than two. That one died the moment `PeopleList`
    /// grew the note below, which makes the duplicated pane the TALLER of the two — so height
    /// stopped separating "one row plus a note" from "two rows" altogether.
    ///
    /// Its ink limb was worse than wrong, it was inert: `repeated.ink > clean.ink / 3` expands to
    /// `2C + R > 0` once the shared chrome `C` is written out, which holds for every value
    /// including a row that drew nothing at all.
    ///
    /// So this compares the duplicated roster against **the one-person roster it is equivalent to**
    /// — the surviving record, alone — and asserts the only two things that are now true and worth
    /// having: the rows match pixel for pixel, and the duplicated pane is taller, by the note that
    /// tells the user their file still holds a record this list is not showing.
    @Test func aRepeatedIdDrawsTheSurvivingRecordAndSaysEditsAreHeld() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The roster the duplicated one collapses TO: the file's last `elder` block, alone. Same
        // bytes the survivor carries, so the rows below must draw identically.
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
        // The premise: one store is holding back its edits and the other is not, so the difference
        // measured below is the note and nothing else.
        #expect(duplicated.repeatedRosterIds == ["elder"])
        #expect(equivalent.repeatedRosterIds.isEmpty)

        let one = renderedInk(pane(equivalent), width: width)
        let repeated = renderedInk(pane(duplicated), width: width)

        // The harness can report a difference at all — without this every equality below could be
        // two identical failures to render.
        #expect(one.ink > 2_000, "the one-person pane inked \(one.ink) pixels — it is blank")

        #expect(repeated.height > one.height, """
                the repeated-id pane (\(repeated.height)pt) is no taller than the same roster \
                without the duplicate (\(one.height)pt) — the note saying edits are held is missing
                """)
        // A note is a line of text, not a second row: bounding it keeps this from passing if the
        // pane started drawing the dropped record again underneath the note.
        #expect(repeated.height - one.height < 80, """
                the repeated-id pane is \(repeated.height - one.height)pt taller than the same \
                roster without the duplicate — that is more than a note; a row came back
                """)
        #expect(repeated.ink > one.ink, "the note draws no pixels")
    }
}
