import Events
import Foundation
import Testing
@testable import Sync

/// Three outcomes that used to happen with nothing in `~/sync-cloud.log` to account for them.
///
/// Each one is a state a reader can *observe* — a pane that reloaded when only the other was asked
/// for, a household where one person's names stopped matching, a tree with neither a profile nor an
/// index entry — while the log offered no cause. A log line is only worth adding if something would
/// notice it going away, so each is pinned here, and the pair that must stay *silent* is pinned in
/// the same tests as the absence half of the rule.
///
/// `Logger.shared` is a process-wide singleton and this suite runs alongside every other, so every
/// fixture carries a token unique to its own run: an assertion matching on "some profile was rolled
/// back" would be reading another test's line.
@Suite struct LoggingGapTests {

    /// The shared logger's most recent entry containing `fragment`, or nil. Awaiting a fresh log
    /// task first guarantees everything enqueued before it is visible in `entries`.
    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await Logger.shared.debug("logging-gap flush marker").value
        return Logger.shared.entries.last { $0.message.contains(fragment) }?.message
    }

    private static func token() -> String { String(UUID().uuidString.prefix(8)) }

    // MARK: - A one-pane refresh that quietly becomes a two-pane one

    /// **A left-pane tab switch that walks the right pane has to say why.**
    ///
    /// `refreshTreesAndScan` unions its requested scope with whatever is in flight, so a
    /// `.leftOnly` switch arriving during a `.both` load widens to `.both` — deliberately, or the
    /// narrower refresh would cancel the wider one and leave the other pane blank. The cost is that
    /// the log then carries a `[load] right … start` line under a request that named only the left,
    /// and nothing connected the two.
    ///
    /// The control is the second half: an *undisputed* refresh must not claim to have widened
    /// anything, or the line would appear under every ordinary load and mean nothing.
    ///
    /// **Neither half lets a refresh finish between the line and the assertion**, and that is not an
    /// economy — it is measured. `Logger.entries` keeps the last 1000 lines, and the rest of this
    /// package running in parallel logs past that window while even an empty two-pane refresh is
    /// being scheduled on a loaded machine: the first version of this test awaited the refresh and
    /// reported a missing line for a line that had been written. The decision under test is taken
    /// synchronously at the top of `refreshTreesAndScan`, before any walk, so both halves read the
    /// log as soon as it has been taken — the first by arranging for the call to dedupe and return
    /// at once, the second by starting it as a task and waiting only for the decision's own
    /// observable.
    @MainActor
    @Test func wideningAOnePaneRefreshSaysSo() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logging-gap-widen-\(Self.token())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        for dir in [left, right] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let l = CloudProvider(id: "L", displayName: "L", imageName: "folder",
                              path: left.path, type: .localFolder)
        let r = CloudProvider(id: "R", displayName: "R", imageName: "folder",
                              path: right.path, type: .localFolder)

        // A refresh with a scope this one disagrees with, standing in for one still in flight —
        // the key is the only part of it this decision reads.
        let m = FileSyncManager()
        m.activeRefreshKey = m.makeRefreshKey(left: l, right: r, reloading: .both)
        await m.refreshTreesAndScan(left: l, right: r, reloading: .leftOnly)

        let line = await loggedLine(containing: "Widening a leftOnly refresh")
        #expect(line != nil, "a one-pane refresh was widened to both panes with nothing in the log")
        #expect(line?.contains("both refresh was already in flight") == true,
                "the line has to name what it was widened by: \(line ?? "nil")")

        // The control, and it is the one that keeps the line honest: a `.both` request also
        // disagrees with a narrower refresh in flight and also takes this branch — but nothing was
        // widened, so announcing one would put the line under ordinary loads too.
        //
        // This half cannot dedupe — the widened key carries `.both` and the one in flight carries
        // `.leftOnly`, so they can never match — which is why the refresh is started as a task and
        // read as soon as the decision is taken rather than awaited to completion. `activeRefreshKey`
        // is assigned immediately after the decision, so *moving off* the planted key is the
        // observable that says the branch has run. Moving off it rather than landing on the widened
        // one, because the refresh releases the key again when it finishes: a fast refresh would
        // pass through the widened value between two polls and the wait would never see it. The
        // marker goes in FIRST, so it is older than any line the branch could write: if it is still
        // in the window, so is anything written after it.
        let m2 = FileSyncManager()
        let inFlight = m2.makeRefreshKey(left: l, right: r, reloading: .leftOnly)
        m2.activeRefreshKey = inFlight
        let marker = "logging-gap control marker \(Self.token())"
        await Logger.shared.debug(marker).value
        let control = Task { await m2.refreshTreesAndScan(left: l, right: r, reloading: .both) }
        await waitUntil("the control refresh reaches its scope decision") {
            m2.activeRefreshKey != inFlight
        }
        control.cancel()

        #expect(await loggedLine(containing: marker) != nil,
                "the log window rolled past this test's own marker, so the silence below is vacuous")
        #expect(await loggedLine(containing: "Widening a both refresh") == nil,
                "a `.both` request is already as wide as this goes and must not claim a widening")
        _ = await control.value
    }

    // MARK: - A household with a repeated id

    /// Writes a `people.json` holding `people`, and returns the directory and profile id.
    private static func roster(_ people: String) throws -> (dir: URL, id: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logging-gap-people-\(token())", isDirectory: true)
        let id = "profile-\(token())"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        try #"{"schemaVersion": 1, "people": [\#(people)]}"#
            .write(to: dir.appendingPathComponent("\(id)/people.json"), atomically: true,
                   encoding: .utf8)
        return (dir, id)
    }

    /// **A repeated person id is tolerated by everything and announced by nothing.**
    ///
    /// The id is the roster's primary key everywhere except in the file, and each consumer resolves
    /// a repeat differently — the registry's token index keeps the last record, an id lookup returns
    /// the first. Nothing fails; a full name simply stops matching. Copying a record to add a
    /// spelling and leaving its `id` alone is how it happens.
    ///
    /// The control below is the half that gives this one teeth: an ordinary roster must load in
    /// silence, or the warning would be noise on every launch.
    @MainActor
    @Test func aRepeatedPersonIdIsWarnedAboutOnceAtLoad() async throws {
        let dup = "shweta-\(Self.token())"
        let (dir, id) = try Self.roster("""
            {"id": "\(dup)", "displayName": "Shweta", "fullNames": ["Shweta Dani"]},
            {"id": "\(dup)", "displayName": "Shweta", "fullNames": ["Shweta R Dani"]}
            """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PeopleStore(directory: dir, profileId: id, profile: nil)
        #expect(store.people.count == 2, "the fixture roster did not load, so it proves nothing")

        let line = await loggedLine(containing: dup)
        #expect(line != nil, "a roster repeating a person id loaded with nothing in the log")
        #expect(line?.contains("LAST entry") == true,
                "the line has to say which of the two records wins: \(line ?? "nil")")
    }

    /// The control: a roster whose ids are unique says nothing at all.
    @MainActor
    @Test func anOrdinaryRosterLoadsWithoutAWarning() async throws {
        let mark = Self.token()
        let (dir, id) = try Self.roster("""
            {"id": "shweta-\(mark)", "displayName": "Shweta"},
            {"id": "abhishek-\(mark)", "displayName": "Abhishek"}
            """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PeopleStore(directory: dir, profileId: id, profile: nil)
        #expect(store.people.count == 2, "the fixture roster did not load, so the silence below is free")
        #expect(store.source == .file, "the roster has to have come from the file")

        // Matched on the profile id rather than on `mark`: the id is in the file path the warning
        // prints, so this catches a warning that fires with an EMPTY list of repeats too — which is
        // exactly what a guard that stopped guarding would produce.
        #expect(await loggedLine(containing: id) == nil, "an ordinary roster was warned about")
        #expect(mark != id)
    }

    // MARK: - A profile that was written and then taken away again

    /// **The rollback is the one thing in the write path that logs, and the one thing no thrown
    /// error carries.**
    ///
    /// The profile lands first and `profiles.json` second; when the second fails the first is
    /// removed again, because a profile nothing points at is one every retry refuses. What
    /// propagates is the index write's own error, which says nothing about a profile having existed
    /// for a moment — so a reader who finds neither profile nor index entry had no account of
    /// either.
    ///
    /// The second half is the rule that removed the line this replaces: **the store throws and the
    /// caller logs**, so a refusal writes nothing here. `profileExists` used to log *and* throw
    /// while its two siblings threw in silence, which taught a reader of the log that the other two
    /// refusals do not happen.
    @MainActor
    @Test func theRollbackIsLoggedAndTheRefusalIsNot() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logging-gap-rollback-\(Self.token())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rolled = "rolled-\(Self.token())"
        let url = FilingProfileStore.profileURL(id: rolled, in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // The index write fails because its directory does not exist, which is where the rollback
        // actually lives (see `land` — the older fixture stopped reaching it).
        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: url,
                                        index: Data("{}".utf8),
                                        at: dir.appendingPathComponent("no-such-dir/profiles.json"))
        }
        let line = await loggedLine(containing: rolled)
        #expect(line != nil, "a profile was written and removed again with nothing in the log")
        #expect(line?.contains("removed again") == true,
                "the line has to say the profile went away, not merely that a write failed: \(line ?? "nil")")

        // And now the silent half. A refusal carries its whole sentence in the error, so the store
        // does not also write it — but the fact still has to be *available*, which is the
        // presence assertion the absence below needs.
        let refused = "refused-\(Self.token())"
        let profile = FolderProfile(profileId: refused, root: "~/Documents",
                                    folders: [:], personTokens: [])
        try FilingProfileStore.writeProfile(profile, in: dir)
        let thrown = #expect(throws: FilingProfileStore.WriteRefusal.self) {
            try FilingProfileStore.writeProfile(profile, in: dir)
        }
        #expect(thrown == .profileExists(id: refused))
        #expect(thrown?.description.contains(refused) == true,
                "the refusal has to carry the id, since it is the caller that will print it")
        #expect(await loggedLine(containing: refused) == nil,
                "the store logged a refusal it also threw — the same fact twice, once where nobody chose the wording")
    }
}
