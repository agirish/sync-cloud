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

    /// The shared logger's most recent ENTRY containing `fragment`, or nil. Awaiting a fresh log
    /// task first guarantees everything enqueued before it is visible in `entries`.
    ///
    /// The whole entry rather than its message, because a line's **level** is part of what this
    /// suite pins — see `wideningAOnePaneRefreshSaysSo`. `loggedLine` below keeps the text-only
    /// reading for the assertions that only care what was said.
    @MainActor
    private func loggedEntry(containing fragment: String) async -> LogEntry? {
        await Logger.shared.debug("logging-gap flush marker").value
        return Logger.shared.entries.last { $0.message.contains(fragment) }
    }

    /// The message of the above, for the assertions that read only the wording.
    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await loggedEntry(containing: fragment)?.message
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
    /// There are **two** controls, and the second is the one this test used to be built on top of:
    ///
    /// - An *undisputed* refresh must not claim to have widened anything, or the line would appear
    ///   under every ordinary load and mean nothing.
    /// - A refresh that widens and is then **deduped** must not claim it either. When the refresh in
    ///   flight is `.both` for the SAME target, a one-pane request widens to `.both`, the widened key
    ///   equals `activeRefreshKey`, and the call returns having started nothing — so a line written
    ///   above that return credited a widening to a call that did no work. That was the only
    ///   scenario the presence half exercised: it planted a `.both` key for the same target
    ///   precisely to make the call dedupe and return at once, which is to say the one case the
    ///   line was pinned in was the one case it was wrong in.
    ///
    /// **No half lets a refresh finish between the line and the assertion**, and that is not an
    /// economy — it is measured. `Logger.entries` keeps the last 1000 lines, and the rest of this
    /// package running in parallel logs past that window while even an empty two-pane refresh is
    /// being scheduled on a loaded machine: the first version of this test awaited the refresh and
    /// reported a missing line for a line that had been written. The decision under test is taken
    /// synchronously at the top of `refreshTreesAndScan`, before any walk, so each half reads the log
    /// as soon as the decision has been taken — the deduping half by returning at once, the two that
    /// really run by starting the refresh as a task and waiting only for the decision's own
    /// observable.
    ///
    /// **The scope PAIR in each fixture is chosen to be unique in this package.** `Logger.shared` is
    /// process-wide and the line names only the two scopes, so a fragment another suite can write is
    /// not this test's to assert on: `PaneReloadScopeTranscript` widens a `.leftOnly` under a
    /// `.both`, which is why the presence half plants `.rightOnly` and matches the whole sentence,
    /// and why the dedupe half requests `.rightOnly` — nothing else in the package does.
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

        // A refresh with a scope this one disagrees with, standing in for one still in flight — the
        // key is the only part of it this decision reads. `.rightOnly` rather than `.both`, and that
        // is the whole point of this half: the widened key carries `.both` and so differs from the
        // planted one, which means the refresh is not deduped and really runs. Under a planted
        // `.both` for the same target — what this half used to plant — the widened key MATCHES, the
        // call returns at the dedupe two statements later, and the line would be describing a walk
        // that never happened. That case is now the third half, below.
        //
        // Started as a task and read at the decision's own observable, for the window reason in the
        // note above: `activeRefreshKey` moves off the planted key immediately after the line is
        // written, so a key that has moved means the line is already in the buffer.
        let m = FileSyncManager()
        let planted = m.makeRefreshKey(left: l, right: r, reloading: .rightOnly)
        m.activeRefreshKey = planted
        let widening = Task { await m.refreshTreesAndScan(left: l, right: r, reloading: .leftOnly) }
        await waitUntil("the widened refresh reaches its scope decision") {
            m.activeRefreshKey != planted
        }
        widening.cancel()

        // The WHOLE sentence, not "Widening a leftOnly refresh": `PaneReloadScopeTranscript` widens
        // a `.leftOnly` under a `.both` in the same process, so the shorter fragment would find that
        // suite's line and this one would pass with nothing of its own written.
        let entry = await loggedEntry(
            containing: "Widening a leftOnly refresh to both panes: a rightOnly refresh was already in flight")
        #expect(entry != nil,
                "a one-pane refresh was widened to both panes, and really ran, with nothing in the log")
        // **The LEVEL, and it is not decoration.** `.debug` is dropped entirely at Settings ▸
        // Advanced ▸ Info, and this is the only account of a user-VISIBLE event — the other pane
        // reloading under a request that named one. The reader who has turned the noise down is
        // exactly the reader filing "why did my right pane reload?", so a line that answers it at
        // `.debug` answers nobody. `e1ae7b9e` raised it from `.debug` and nothing pinned it: every
        // assertion in this suite read `\.message`, so the raise was one revert from being undone
        // in silence.
        #expect(entry?.level == .info,
                "the widening line is back at \(entry?.level.rawValue ?? "no") level — at .debug it is dropped for exactly the reader who turned the noise down to ask why their other pane reloaded")
        _ = await widening.value

        // The first control, and it is the one that keeps the line honest: a `.both` request also
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

        // The second control: **widened, and then deduped away.** A one-pane request arriving under
        // a `.both` refresh for the SAME target widens to `.both`, which is exactly the key already
        // in flight — so the call skips and returns having walked nothing. Announced before the
        // dedupe, the line read "Widening a rightOnly refresh to both panes" immediately followed by
        // "Skipping duplicate in-flight refresh", crediting a widening to a call that did no work.
        //
        // `.rightOnly` requested, because the fragment has to be one nothing else in this package
        // writes: `PaneReloadScopeTranscript` and the presence half above both widen a `.leftOnly`.
        // Marker first, as everywhere here, so a rolled window is reported rather than passing.
        let m3 = FileSyncManager()
        let sameTarget = m3.makeRefreshKey(left: l, right: r, reloading: .both)
        m3.activeRefreshKey = sameTarget
        let dedupeMarker = "logging-gap dedupe marker \(Self.token())"
        await Logger.shared.debug(dedupeMarker).value
        await m3.refreshTreesAndScan(left: l, right: r, reloading: .rightOnly)
        #expect(m3.activeRefreshKey == sameTarget,
                "the fixture did not dedupe, so this half is measuring the wrong branch entirely")

        #expect(await loggedLine(containing: dedupeMarker) != nil,
                "the log window rolled past this test's own marker, so the silence below is vacuous")
        #expect(await loggedLine(containing: "Widening a rightOnly refresh") == nil,
                "a refresh that deduped and walked nothing still claims to have widened one")
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
        // The roster loaded AND was collapsed to one record — both halves matter here. The first
        // is the fixture working at all; the second is why this warning cannot be derived from
        // `store.people`, which is the repaired roster and no longer shows the repeat. An earlier
        // version of the warning did exactly that and went silent; `PersonRegistry.repeatedIds`
        // reads the raw list instead.
        #expect(store.people.count == 1, "the fixture roster did not load, or the repeat survived it")
        #expect(store.people.first?.fullNames == ["Shweta R Dani"],
                "the collapse kept the wrong record, so the line below would name the wrong loss")

        // **The LOAD warning specifically.** `PeopleStore.save()` now refuses a roster that repeats
        // an id and names the same ids doing it, so "a line mentioning `dup`" is no longer one
        // thing: matched on the load warning's own opening so a refusal can never stand in for it.
        let line = await loggedLine(containing: "people.json repeats the person id(s) \(dup)")
        #expect(line != nil, "a roster repeating a person id loaded with nothing in the log")
        #expect(line?.contains("Refusing to write") != true,
                "the save-time refusal was matched instead of the load warning: \(line ?? "nil")")
        #expect(line?.contains("LAST entry") == true,
                "the line has to say which of the two records wins: \(line ?? "nil")")
        #expect(line?.contains("dropped") == true,
                "the line has to say the earlier records are DISCARDED, not merely out-voted: \(line ?? "nil")")
        // **The path is load-bearing for the control below, and nothing else pinned it.**
        // `anOrdinaryRosterLoadsWithoutAWarning` asserts the absence of any line naming the PROFILE
        // ID, and the only reason a warning would carry that id is that this line prints
        // `fileURL.path` — which is `<dir>/<profile id>/people.json`. Narrow that to
        // `lastPathComponent` and the control goes vacuous in silence, including for the very
        // mutation its comment claims to catch. So it is pinned here, in the positive half, where
        // the line actually exists to be read.
        #expect(line?.contains("/\(id)/people.json") == true,
                "the warning no longer prints the roster's PATH, so `anOrdinaryRosterLoadsWithoutAWarning` — which matches on the profile id — can never fail: \(line ?? "nil")")
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

        // **The marker goes in before the load**, on this suite's rule for every absence assertion:
        // `Logger.entries` is a rolled 1000-line window shared with every suite running alongside,
        // and a silence measured over a window that rolled past is a test that cannot fail. Older
        // than anything the load could write, so if it is still there, so is anything after it.
        let marker = "logging-gap roster control marker \(Self.token())"
        await Logger.shared.debug(marker).value

        let store = PeopleStore(directory: dir, profileId: id, profile: nil)
        #expect(store.people.count == 2, "the fixture roster did not load, so the silence below is free")
        #expect(store.source == .file, "the roster has to have come from the file")

        #expect(await loggedLine(containing: marker) != nil,
                "the log window rolled past this test's own marker, so the silence below is vacuous")
        // Matched on the profile id rather than on `mark`: the id is in the file path the warning
        // prints, so this catches a warning that fires with an EMPTY list of repeats too — which is
        // exactly what a guard that stopped guarding would produce. That the warning really does
        // print the path is pinned in the positive sibling above, because nothing here can see it.
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
        //
        // **This absence needs its own marker most of all**, and it was the one that did not have
        // one. Its window is the widest of the three — two full `writeProfile` calls with atomic
        // disk writes between the marker and the read — so on a loaded machine running this package
        // in parallel it is the likeliest of them to be measured over a window that has already
        // rolled, and the regression it exists to catch (a `Logger.shared.warning` reinstated beside
        // `throw WriteRefusal.profileExists`) would then go unreported. Logged before the FIRST
        // write, since that is the earliest point anything could name `refused`.
        let refusalMarker = "logging-gap refusal marker \(Self.token())"
        await Logger.shared.debug(refusalMarker).value

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
        #expect(await loggedLine(containing: refusalMarker) != nil,
                "the log window rolled past this test's own marker, so the silence below is vacuous")
        #expect(await loggedLine(containing: refused) == nil,
                "the store logged a refusal it also threw — the same fact twice, once where nobody chose the wording")
    }
}
