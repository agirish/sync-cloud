import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// Outcomes a reader can observe that `~/sync-cloud.log` must account for: a pane that reloaded
/// when only the other was asked for, a household where one person's names stopped matching, a
/// tree with neither a profile nor an index entry. Each line is pinned so its removal fails a test,
/// and the cases that must stay silent are pinned beside them.
///
/// `Logger.shared` is process-wide and shared with every suite running alongside, so every fixture
/// carries a token unique to its own run.
@Suite @MainActor struct LoggingGapTests {
    /// Opened per test (Swift Testing builds a fresh instance for each), so every assertion reads a
    /// window that starts before its test does and can't be evicted. See `LogCapture`.
    private let log = LogCapture()


    /// The shared logger's most recent entry containing `fragment`, or nil. The whole entry, not
    /// its message, because a line's level is part of what this suite pins
    /// (`wideningAOnePaneRefreshSaysSo`).
    private func loggedEntry(containing fragment: String) async -> LogEntry? {
        await log.entries.last { $0.message.contains(fragment) }
    }

    /// The message of the above, for the assertions that read only the wording.
    private func loggedLine(containing fragment: String) async -> String? {
        await loggedEntry(containing: fragment)?.message
    }

    private static func token() -> String { String(UUID().uuidString.prefix(8)) }

    // MARK: - A one-pane refresh that quietly becomes a two-pane one

    /// A left-pane tab switch that walks the right pane has to say why.
    ///
    /// `refreshTreesAndScan` unions its requested scope with whatever is in flight, so a `.leftOnly`
    /// switch during a `.both` load widens to `.both`; otherwise the narrower refresh would cancel
    /// the wider one and leave the other pane blank. The log then shows a right-pane load under a
    /// left-only request, so the widening must be logged. Two controls:
    /// - An undisputed refresh must not claim a widening, or the line would appear on every load.
    /// - A refresh that widens and is then deduped (the widened key equals `activeRefreshKey`)
    ///   starts nothing, so it must not claim one either.
    ///
    /// No half lets a refresh finish before the assertion: the rest of the package can log past the
    /// 1,000-line window while even an empty refresh is scheduled. The decision is taken
    /// synchronously at the top of `refreshTreesAndScan`, so each half reads the log as soon as it
    /// is taken. Each fixture's scope pair is unique in this package: `PaneReloadScopeTranscript`
    /// widens a `.leftOnly` under a `.both`, so these halves use `.rightOnly`.
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
                              rootPath: left.path, type: .localFolder)
        let r = CloudProvider(id: "R", displayName: "R", imageName: "folder",
                              rootPath: right.path, type: .localFolder)

        // A planted key standing in for a refresh in flight; the key is all this decision reads.
        // `.rightOnly`, so the widened `.both` key differs from it and the refresh really runs
        // (a planted `.both` for the same target would dedupe; that case is the third half).
        //
        // Started as a task and read at the decision's own observable: `activeRefreshKey` moves
        // off the planted key right after the line is written.
        let m = FileSyncManager()
        let planted = m.makeRefreshKey(left: l, right: r, reloading: .rightOnly)
        m.activeRefreshKey = planted
        let widening = Task { await m.refreshTreesAndScan(left: l, right: r, reloading: .leftOnly) }
        await waitUntil("the widened refresh reaches its scope decision") {
            m.activeRefreshKey != planted
        }
        widening.cancel()

        // The whole sentence: `PaneReloadScopeTranscript` widens a `.leftOnly` under a `.both` in
        // the same process, so a shorter fragment could match its line instead.
        let entry = await loggedEntry(
            containing: "Widening a leftOnly refresh to both panes: a rightOnly refresh was already in flight")
        #expect(entry != nil,
                "a one-pane refresh was widened to both panes, and really ran, with nothing in the log")
        // The level matters: `.debug` is dropped at Settings ▸ Advanced ▸ Info, and this is the only
        // account of a visible event (the other pane reloading). The reader who turned the noise
        // down is the one asking why their right pane reloaded.
        #expect(entry?.level == .info,
                "the widening line is back at \(entry?.level.rawValue ?? "no") level — at .debug it is dropped for exactly the reader who turned the noise down to ask why their other pane reloaded")
        _ = await widening.value

        // First control: a `.both` request also disagrees with a narrower refresh in flight and
        // takes this branch, but widens nothing, so it must not announce a widening.
        //
        // It can't dedupe, so it is started as a task and read once the decision is taken. The wait
        // is for `activeRefreshKey` to move off the planted key, not to land on the widened one: the
        // refresh releases the key when it finishes, so a fast one could pass through the widened
        // value between polls. The marker goes in first, so if it is still in the window, so is
        // anything the branch wrote.
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

        // Second control: widened, then deduped. A one-pane request under a `.both` refresh for the
        // same target widens to the key already in flight, so the call returns having walked
        // nothing, and must not claim a widening.
        //
        // `.rightOnly`, because nothing else in this package widens it. Marker first, so a rolled
        // window is reported rather than passing.
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

    /// A repeated person id is tolerated by everything and announced by nothing else.
    ///
    /// The id is the roster's primary key, and consumers resolve a repeat differently (the
    /// registry's token index keeps the last record, an id lookup returns the first). Nothing fails;
    /// a full name just stops matching. Copying a record to add a spelling without changing its `id`
    /// causes it. The control below keeps the warning off an ordinary roster's launch.
    @MainActor
    @Test func aRepeatedPersonIdIsWarnedAboutOnceAtLoad() async throws {
        let dup = "mother-\(Self.token())"
        let (dir, id) = try Self.roster("""
            {"id": "\(dup)", "displayName": "Mother", "fullNames": ["Mother Maiden"]},
            {"id": "\(dup)", "displayName": "Mother", "fullNames": ["Mother I Maiden"]}
            """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PeopleStore(directory: dir, profileId: id, profile: nil)
        // The roster loaded and was collapsed to one record. The collapse is why the warning can't
        // be derived from `store.people`, which no longer shows the repeat;
        // `PersonRegistry.repeatedIds` reads the raw list instead.
        #expect(store.people.count == 1, "the fixture roster did not load, or the repeat survived it")
        #expect(store.people.first?.fullNames == ["Mother I Maiden"],
                "the collapse kept the wrong record, so the line below would name the wrong loss")

        // The load warning specifically: `PeopleStore.save()` refuses a roster that repeats an id
        // and names the same ids, so match on the load warning's own opening.
        let line = await loggedLine(containing: "people.json repeats the person id(s) \(dup)")
        #expect(line != nil, "a roster repeating a person id loaded with nothing in the log")
        #expect(line?.contains("Refusing to write") != true,
                "the save-time refusal was matched instead of the load warning: \(line ?? "nil")")
        #expect(line?.contains("LAST entry") == true,
                "the line has to say which of the two records wins: \(line ?? "nil")")
        #expect(line?.contains("dropped") == true,
                "the line has to say the earlier records are DISCARDED, not merely out-voted: \(line ?? "nil")")
        // The path is pinned because the control below depends on it:
        // `anOrdinaryRosterLoadsWithoutAWarning` asserts no line names the profile id, which only
        // works while this line prints `fileURL.path` (`<dir>/<profile id>/people.json`). Narrowed
        // to `lastPathComponent`, the control would go vacuous.
        #expect(line?.contains("/\(id)/people.json") == true,
                "the warning no longer prints the roster's PATH, so `anOrdinaryRosterLoadsWithoutAWarning` — which matches on the profile id — can never fail: \(line ?? "nil")")
    }

    /// The control: a roster whose ids are unique says nothing at all.
    @MainActor
    @Test func anOrdinaryRosterLoadsWithoutAWarning() async throws {
        let mark = Self.token()
        let (dir, id) = try Self.roster("""
            {"id": "mother-\(mark)", "displayName": "Mother"},
            {"id": "father-\(mark)", "displayName": "Father"}
            """)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Marker before the load, as for every absence assertion here: a silence measured over a
        // window that has rolled can't fail. If the marker is still there, so is anything after it.
        let marker = "logging-gap roster control marker \(Self.token())"
        await Logger.shared.debug(marker).value

        let store = PeopleStore(directory: dir, profileId: id, profile: nil)
        #expect(store.people.count == 2, "the fixture roster did not load, so the silence below is free")
        #expect(store.source == .file, "the roster has to have come from the file")

        #expect(await loggedLine(containing: marker) != nil,
                "the log window rolled past this test's own marker, so the silence below is vacuous")
        // Matched on the profile id, which is in the path the warning prints, so this also catches
        // a warning that fires with an empty list of repeats. The positive test pins that the path
        // is printed.
        #expect(await loggedLine(containing: id) == nil, "an ordinary roster was warned about")
    }

    // MARK: - A profile that was written and then taken away again

    /// The rollback is logged; a refusal is not.
    ///
    /// The profile lands first and `profiles.json` second; if the second fails, the profile is
    /// removed again, since a profile nothing points at is one every retry refuses. The thrown error
    /// is the index write's own and says nothing about the profile, so only the log can.
    ///
    /// A refusal, by contrast, is thrown and the caller logs it: the store throws and writes nothing
    /// here, the same for all three refusals, so the log doesn't suggest some never happen.
    @MainActor
    @Test func theRollbackIsLoggedAndTheRefusalIsNot() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logging-gap-rollback-\(Self.token())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rolled = "rolled-\(Self.token())"
        let url = FilingProfileStore.profileURL(id: rolled, in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // The index write fails because its directory doesn't exist, which is the path that reaches
        // the rollback (see `land`).
        #expect(throws: (any Error).self) {
            try FilingProfileStore.land(Data(#"{"profileId":"mine"}"#.utf8), at: url,
                                        index: Data("{}".utf8),
                                        at: dir.appendingPathComponent("no-such-dir/profiles.json"))
        }
        let line = await loggedLine(containing: rolled)
        #expect(line != nil, "a profile was written and removed again with nothing in the log")
        #expect(line?.contains("removed again") == true,
                "the line has to say the profile went away, not merely that a write failed: \(line ?? "nil")")

        // The silent half. A refusal carries its whole sentence in the error, so the store must not
        // also log it, but the error must still carry the id.
        //
        // This absence has the widest window here (two `writeProfile` calls with atomic writes), so
        // it most needs its marker: without one, a reinstated `Logger.shared.warning` beside
        // `throw WriteRefusal.profileExists` could go unreported. Logged before the first write,
        // the earliest point anything could name `refused`.
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

    // MARK: - A re-home line that credits a pane that did not move

    /// A provider switch re-homes one pane, and the line must not claim both.
    ///
    /// The line is how `~/sync-cloud.log` tells a source switch from a two-pane reset:
    /// `retargetPane` leaves the sibling its tree, columns, selection and history. "Moved" must not
    /// be decided by comparing whole histories, since any pane with history behind it would then
    /// count as re-homed; this fixture's right pane has one step behind it for that reason.
    ///
    /// The sibling's Back stack must survive, because its tree isn't being replaced.
    @Test func aProviderSwitchDoesNotClaimToHaveRehomedBothPanes() async {
        let token = Self.token()
        let manager = FileSyncManager()
        // The right pane, where the switch isn't happening: on a folder, one step in.
        manager.focusOn(relativePath: "Documents/Family", isLeft: false)
        #expect(manager.rightHistory.canGoBack,
                "the fixture has no right-pane history, so it cannot measure the case it exists for")

        let marker = "logging-gap rehome marker \(token)"
        await Logger.shared.debug(marker).value
        let landing = "Left-\(token)"
        manager.retargetPane(isLeft: true, landing: landing)

        #expect(await loggedLine(containing: marker) != nil,
                "the log window rolled past this test's own marker, so the reading below is vacuous")
        let line = await loggedLine(containing: landing)
        #expect(line?.contains("This touched only the left pane") == true,
                "the line does not say which pane the call touched: \(line ?? "nothing was logged")")
        #expect(line?.contains("the right pane's tree, columns, selection and history are as they were") == true,
                "the line does not spell out what the untouched pane kept — the folder is the least of it: \(line ?? "nothing was logged")")
        #expect(line?.contains("both panes") == false,
                "the line credits a re-homing to a pane that did not move: \(line ?? "nothing was logged")")
        // Phrased about the call, not the window: releasing a duplicate review's pin from the
        // sibling lands two of these in one gesture, and each must not call the other pane
        // "untouched" when the gesture moved both.
        #expect(line?.contains("the right pane is untouched") == false,
                "the line makes a claim about the window's end state that a second retarget in the same gesture falsifies: \(line ?? "nothing was logged")")

        // The sibling's tree is still on screen, so Back is still a step the user can take.
        #expect(manager.rightHistory.entries == ["", "Documents/Family"],
                "a switch on the left pane emptied the right pane's Back stack")
    }

    /// A Compare's start line says at Info whether it read the panes' cached walks or walked the
    /// disk, and how old the walks were. The branch decides the answer as well as the time: a disk
    /// walk stops at the node budget, so cold and warm Compares of one pair can count different
    /// differences. Its completed line says how much each side held. The roots carry this run's
    /// token, so no other suite's scan can answer for these.
    @Test func aScanSaysWhereItsTreesCameFrom() async throws {
        let token = Self.token()
        let leftRoot = "/scan-\(token)-left", rightRoot = "/scan-\(token)-right"
        let fm = MockFileManager()
        for dir in [leftRoot, rightRoot] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        fm.virtualDisk[leftRoot + "/only.txt"] = .init(isDirectory: false, attributes: nil, contents: nil)
        let m = FileSyncManager(fileManager: fm)
        m.linkedFolders = [:]
        let l = CloudProvider(id: "L", displayName: "L", imageName: "", rootPath: leftRoot, type: .iCloud)
        let r = CloudProvider(id: "R", displayName: "R", imageName: "", rootPath: rightRoot, type: .dropBox)

        // Nothing cached, so the scan walks both folders.
        await m.scanDirectories(left: l, leftPath: leftRoot, right: r, rightPath: rightRoot)
        let cold = await loggedEntry(containing: "by walking “\(leftRoot)” and “\(rightRoot)” from disk")
        #expect(cold?.level == .info, "a scan that walked both folders said so at \(cold?.level.rawValue ?? "no") level")
        #expect(cold?.message.hasSuffix("no cached walk of either folder") == true, "\(cold?.message ?? "nothing logged")")
        // One line, not a start line and a mode line: the start names the sources and the branch.
        let coldLine = try #require(cold?.message)
        #expect(coldLine.hasPrefix("[scan] #") && coldLine.contains(" start: comparing L and R by walking “\(leftRoot)”"),
                "the branch is not on the start line: \(coldLine)")
        // The completed line of the same scan, by its tag, counts what each side walked.
        let tag = String(coldLine.dropFirst("[scan] ".count).prefix { $0 != " " })
        let walked = "; walked 1 file and 0 folders on the left, 0 files and 0 folders on the right"
        let completed = await log.entries.contains {
            $0.message.hasPrefix("[scan] \(tag) completed: found 1 differences in ") && $0.message.hasSuffix(walked)
        }
        #expect(completed, "no completed line for scan \(tag) counts what each side walked")

        // The refresh walks and caches both panes, and its scan compares those walks.
        await m.refreshTreesAndScan(left: l, right: r)
        let warm = await loggedEntry(containing: "start: comparing L and R from the panes' cached walks of “\(leftRoot)” (walked ")
        #expect(warm?.level == .info, "a scan from the panes' walks said so at \(warm?.level.rawValue ?? "no") level")
        #expect(warm?.message.contains("and “\(rightRoot)” (walked ") == true, "\(warm?.message ?? "nothing logged")")

        // One side cached: the line names the side that missed (after a source switch, the pane
        // that stayed means its walk wasn't kept).
        m.dropPrefetchedTrees(keeping: leftRoot)
        await m.scanDirectories(left: l, leftPath: leftRoot, right: r, rightPath: rightRoot)
        let half = await loggedEntry(containing: "by walking “\(leftRoot)” and “\(rightRoot)” from disk")
        #expect(half?.message.hasSuffix("no cached walk of the right one") == true, "\(half?.message ?? "nothing logged")")
    }

    /// The completed line's counts: files and folders per side, in the singular for one, and the
    /// root's own record (written when the root couldn't be listed) counted as neither.
    @Test func aScansWalkedCountsNameFilesAndFoldersPerSide() {
        func info(_ path: String, folder: Bool, unexplored: Bool = false) -> FileDiffEngine.FileInfo {
            FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/root/" + path), modificationDate: nil, fileSize: nil,
                                    isDirectory: folder, isUnexplored: unexplored)
        }
        let left = ["a.txt": info("a.txt", folder: false), "b.txt": info("b.txt", folder: false),
                    "Docs": info("Docs", folder: true), "Docs/c.md": info("Docs/c.md", folder: false),
                    "Old": info("Old", folder: true)]
        let right = ["": info("", folder: true, unexplored: true), "Docs": info("Docs", folder: true),
                     "d.txt": info("d.txt", folder: false)]
        #expect(FileSyncManager.walkedText(left: left, right: right)
                == "walked 3 files and 2 folders on the left, 1 file and 1 folder on the right")
        #expect(FileSyncManager.walkedText(left: [:], right: [:])
                == "walked 0 files and 0 folders on the left, 0 files and 0 folders on the right")
    }

    /// The walks' ages read in the largest whole unit that fits — minutes or hours is the question.
    @Test func aWalksAgeReadsInWholeUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(FileSyncManager.ageText(since: now, now: now) == "just now")
        #expect(FileSyncManager.ageText(since: now + 5, now: now) == "just now", "a clock step back read as an age")
        #expect(FileSyncManager.ageText(since: now - 42, now: now) == "42 s ago")
        #expect(FileSyncManager.ageText(since: now - 90, now: now) == "1 min ago", "seconds past the first minute")
        #expect(FileSyncManager.ageText(since: now - 720, now: now) == "12 min ago")
        #expect(FileSyncManager.ageText(since: now - 14_580, now: now) == "4 h 3 min ago")
        #expect(FileSyncManager.ageText(since: nil, now: now) == "at an unrecorded time")
    }
}
