import Testing
import Foundation
@testable import Sync

/// The destination picker's model: what it offers, in what order, and the two questions it asks
/// before lighting up its Move button.
@Suite struct DestinationBrowserTests {

    /// A provider at `/p` with two same-named leaves, which is the case the trail exists for:
    ///
    ///     /p/Health/Medical/Kaiser/Son
    ///     /p/School/Son
    ///     /p/Health/Prescriptions
    ///     /p/.hidden
    ///     /p/loose.txt
    private func fixture() throws -> MockFileManager {
        let fm = MockFileManager()
        for dir in ["/p", "/p/Health", "/p/Health/Medical", "/p/Health/Medical/Kaiser",
                    "/p/Health/Medical/Kaiser/Son", "/p/Health/Prescriptions",
                    "/p/School", "/p/School/Son", "/p/.hidden"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        fm.virtualDisk["/p/loose.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        return fm
    }

    // MARK: - Listing

    /// Folders only, name-sorted: a file row would be a destination you cannot pick.
    /// Dot-directories are dropped by name as well as by the enumerator's hidden flag: a folder can
    /// be one without the other.
    @Test func testHiddenFoldersAreDroppedUnlessAsked() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.listSubfolders(of: "/p", fileManager: fm).folders.map(\.name) == ["Health", "School"])
        let shown = DestinationBrowser.listSubfolders(of: "/p", showHidden: true, fileManager: fm).folders.map(\.name)
        #expect(shown.contains(".hidden"))
    }

    /// An empty root would otherwise resolve against the process working directory.
    @Test func testEmptyRootListsNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.listSubfolders(of: "", fileManager: fm).folders.isEmpty)
    }

    // MARK: - Listing a folder that cannot be read

    /// The column under a folder that couldn't be opened says so, not "Empty", which would be a
    /// claim about contents nobody saw. The three cases are asserted together because they must
    /// differ.
    @Test func testAnUnreadableFolderIsNotOfferedAsAnEmptyOne() throws {
        let fm = try fixture()
        fm.unlistableDirectories = ["/p/Health/Prescriptions"]

        let unreadable = DestinationBrowser.listSubfolders(of: "/p/Health/Prescriptions", fileManager: fm)
        #expect(unreadable.outcome == .unreadable)
        #expect(unreadable.emptyMessage == "Can’t be read")

        // A folder that genuinely holds no subfolders, from the same fixture and the same call.
        let leaf = DestinationBrowser.listSubfolders(of: "/p/School/Son", fileManager: fm)
        #expect(leaf.outcome == .listed)
        #expect(leaf.emptyMessage == "Empty")

        // And a folder with rows has nothing to say in its place.
        let populated = DestinationBrowser.listSubfolders(of: "/p", fileManager: fm)
        #expect(populated.folders.map(\.name) == ["Health", "School"])
        #expect(populated.emptyMessage == nil)
    }

    /// A partial listing with no subfolders (the folder opened, something below it didn't) is not
    /// "Empty", and not "Can't be read" either: `DirectoryListingOutcome`'s three cases each get
    /// their own words, which a two-way check would fold together.
    ///
    /// `listSubfolders` lists shallowly and can't produce this value today, but the type is public
    /// and the wording is part of it, so the rule is asserted on the value itself.
    @Test func testAPartialListingIsNotAnnouncedAsEmpty() throws {
        let partial = DestinationFolderListing(folders: [], outcome: .listedWithUnreadableDescendants)
        let empty = DestinationFolderListing(folders: [], outcome: .listed)
        let unreadable = DestinationFolderListing(folders: [], outcome: .unreadable)

        #expect(partial.emptyMessage != empty.emptyMessage,
                "a folder with a withheld subtree is not a folder known to hold nothing")
        #expect(partial.emptyMessage != unreadable.emptyMessage,
                "…and it is not a folder nobody opened either")
        #expect(partial.emptyMessage == "Can’t be fully read")
        #expect(empty.emptyMessage == "Empty")
        #expect(unreadable.emptyMessage == "Can’t be read")
    }

    /// A directory the walk couldn't read means it hasn't established "no folders match", as with
    /// the three caps. The pair is the test: the same query over the same tree answers "complete"
    /// when everything is readable.
    @Test func testSearchThatCouldNotReadADirectorySaysItStoppedShort() throws {
        let readable = try fixture()
        let complete = DestinationBrowser.search("Kaiser", under: "/p", fileManager: readable)
        #expect(complete.matches.map(\.name) == ["Kaiser"])
        #expect(!complete.stoppedEarly && !complete.skippedUnreadableDirectory)

        let blocked = try fixture()
        blocked.unlistableDirectories = ["/p/Health/Medical"]
        let partial = DestinationBrowser.search("Kaiser", under: "/p", fileManager: blocked)
        #expect(partial.matches.isEmpty, "Kaiser sits behind the folder that could not be read")
        #expect(partial.skippedUnreadableDirectory,
                "a walk that could not read a directory has not earned “No folders match”")
        #expect(!partial.stoppedEarly, "…and it is not the CAPS that stopped it — nothing was cut short")
    }

    /// The two reasons a result list can be short are different, with opposite advice, so they
    /// can't share one boolean. A cap stops the walk early: the rows are "the first N" and a
    /// tighter query reaches further. An unreadable directory lets the walk finish without a
    /// subtree: the rows are every match found, and no query will open that folder.
    @Test func testAWithheldDirectoryIsNotTheSameFactAsHittingACap() throws {
        let blocked = try fixture()
        blocked.unlistableDirectories = ["/p/Health/Medical"]

        // Matches exist and are all found; only the unreadable folder is unaccounted for.
        let withheld = DestinationBrowser.search("School", under: "/p", fileManager: blocked)
        #expect(withheld.matches.map(\.name) == ["School"])
        #expect(!withheld.stoppedEarly, "nothing cut this walk short — it ran the tree out")
        #expect(withheld.skippedUnreadableDirectory)

        // The same tree, readable, with a cap doing the stopping instead.
        let readable = try fixture()
        let capped = DestinationBrowser.search("son", under: "/p", limit: 1, fileManager: readable)
        #expect(capped.stoppedEarly)
        #expect(!capped.skippedUnreadableDirectory, "every directory here was read")

        // …and both at once. The blocked folder must sit where the walk meets it before the cap
        // trips: breadth-first with `limit: 1`, `/p/Health` is refused in the same pass that finds
        // `/p/School/Son`. Blocking `/p/Health/Medical` would end the walk a level too early to
        // notice, leaving only one of the two facts set.
        let blockedHigh = try fixture()
        blockedHigh.unlistableDirectories = ["/p/Health"]
        let both = DestinationBrowser.search("son", under: "/p", limit: 1, fileManager: blockedHigh)
        #expect(both.stoppedEarly)
        #expect(both.skippedUnreadableDirectory)
    }

    /// The sentence under a non-empty list matches why it might be short: the cap's advice is
    /// false for a walk that finished with a folder unread.
    @Test func testTheFootnoteUnderResultsMatchesWhyTheyMightBeShort() throws {
        let complete = DestinationSearchOutcome(matches: [], stoppedEarly: false,
                                                skippedUnreadableDirectory: false)
        #expect(complete.footnote(showing: 3) == nil, "a complete answer caveats nothing")

        let capped = DestinationSearchOutcome(matches: [], stoppedEarly: true,
                                              skippedUnreadableDirectory: false)
        #expect(capped.footnote(showing: 3) == "Showing the first 3 — narrow the search, or browse to it.")

        let withheld = DestinationSearchOutcome(matches: [], stoppedEarly: false,
                                                skippedUnreadableDirectory: true)
        let text = try #require(withheld.footnote(showing: 3))
        #expect(text == "Some folders couldn’t be read — a match may be inside one of them.")
        // The two claims that would be false here, checked in the negative as well as by equality,
        // because a reworded sentence could bring either one back on its own.
        #expect(!text.contains("the first"), "this walk completed — these are not “the first 3”")
        #expect(!text.contains("narrow"), "narrowing cannot reach behind a permission-denied folder")

        let both = DestinationSearchOutcome(matches: [], stoppedEarly: true,
                                            skippedUnreadableDirectory: true)
        #expect(both.footnote(showing: 3)
                == "Showing the first 3, and some folders couldn’t be read — there may be more either way.")
    }

    /// The empty-results wording keeps the unreadable-folder case apart from the caps' advice too.
    /// Four inputs, four different sentences.
    @Test func testTheEmptyMessageNamesWhichKindOfNothingItIs() throws {
        func message(stoppedEarly: Bool, skipped: Bool) -> String {
            DestinationSearchOutcome(matches: [], stoppedEarly: stoppedEarly,
                                     skippedUnreadableDirectory: skipped).emptyMessage(query: "Son")
        }
        let complete = message(stoppedEarly: false, skipped: false)
        let capped = message(stoppedEarly: true, skipped: false)
        let withheld = message(stoppedEarly: false, skipped: true)
        let both = message(stoppedEarly: true, skipped: true)

        #expect(complete == "No folders match “Son”")
        #expect(Set([complete, capped, withheld, both]).count == 4,
                "each cause has to reach its own sentence, not share one")
        // Only the complete walk may make the flat claim; the other three have not earned it.
        for (name, text) in [("capped", capped), ("withheld", withheld), ("both", both)] {
            #expect(text != complete, "\(name) reused the complete walk's wording")
            #expect(text.contains("Son"), "\(name) dropped the query from its sentence")
        }
        #expect(withheld.contains("read"), "the withheld case has to say what happened: \(withheld)")
    }

    // MARK: - A folder reached through a symlink, on a real disk

    /// A symlinked folder is browsable and searchable, not "Can't be read" or truncated.
    /// `FileManager.enumerator(at:)` won't traverse a symlinked directory: it yields nothing and
    /// fires its error handler, exactly as for a locked one.
    ///
    /// On the real filesystem, because the behaviour is the real `FileManager`'s; the mock has no
    /// symlinks. The control asks the link's target the same questions, so a `listSubfolders` that
    /// found nothing at all can't pass.
    @Test func testAFolderReachedThroughASymlinkIsBrowsableAndSearchable() throws {
        let base = try makeCanonicalTempRoot(prefix: "DestSymlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("provider")
        for name in ["Medical", "Dental"] {
            try FileManager.default.createDirectory(at: target.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: target.appendingPathComponent("loose.txt"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let listed = DestinationBrowser.listSubfolders(of: link.path, fileManager: FileManager.default)
        #expect(listed.outcome == .listed)
        #expect(listed.folders.map(\.name) == ["Dental", "Medical"])
        #expect(listed.emptyMessage == nil, "a column with rows has nothing to say in their place")
        // Rows keyed on the path the user browsed through, not the link's target — the footer's
        // breadcrumbs, `trail`, and the recents list are all matched against it.
        #expect(listed.folders.map(\.path) == [link.appendingPathComponent("Dental").path,
                                               link.appendingPathComponent("Medical").path])

        let found = DestinationBrowser.search("Medical", under: link.path, fileManager: FileManager.default)
        #expect(found.matches.map(\.name) == ["Medical"])
        #expect(!found.stoppedEarly && !found.skippedUnreadableDirectory,
                "the walk read every directory it queued — it was not truncated")
        #expect(found.footnote(showing: 1) == nil)

        // Control: the same tree asked about directly, with no symlink in the way.
        let direct = DestinationBrowser.search("Medical", under: target.path, fileManager: FileManager.default)
        #expect(direct.matches.map(\.name) == found.matches.map(\.name))
        #expect(!direct.stoppedEarly && !direct.skippedUnreadableDirectory)
    }

    /// Drilling one level into a symlinked folder keeps the caller's spelling too. Re-spelling on
    /// the retry covers only a link as the final component; one level in, the direct walk succeeds
    /// and the enumerator hands back the canonical target path. That path is outside the browsed
    /// root, so `trail` would list every component of it in the footer, and `highlighted` (what
    /// Move commits to) and the recents key would drift from the browsed path. Asserted at both
    /// levels, because depth 1 alone passes either way.
    @Test func testDrillingIntoASymlinkedFolderKeepsTheCallersSpelling() throws {
        let base = try makeCanonicalTempRoot(prefix: "DestSymlinkDeep")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("Health/Medical"), withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Level 1: the link itself is the final component, so the retry path re-spells.
        let level1 = DestinationBrowser.listSubfolders(of: link.path, fileManager: FileManager.default)
        #expect(level1.folders.map(\.path) == [link.appendingPathComponent("Health").path],
                "level 1 lost the caller's spelling: \(level1.folders.map(\.path))")

        // Level 2: one level INSIDE the link, where the direct walk succeeds on its own.
        let health = link.appendingPathComponent("Health").path
        let level2 = DestinationBrowser.listSubfolders(of: health, fileManager: FileManager.default)
        #expect(level2.outcome == .listed)
        #expect(level2.folders.map(\.path) == [link.appendingPathComponent("Health/Medical").path],
                "level 2 answered in the target's spelling: \(level2.folders.map(\.path))")

        // What the footer shows. `#require`, not a subscript after `#expect`: `#expect` continues,
        // so indexing an empty array would trap the test host and lose the run.
        let medical = try #require(level2.folders.first).path
        #expect(DestinationBrowser.trail(of: medical, under: link.path) == ["link", "Health"],
                "trail took its outside-the-root escape: \(DestinationBrowser.trail(of: medical, under: link.path))")
        #expect(DestinationBrowser.crumbs(for: medical, under: link.path, providerName: "Dropbox")
                == ["Dropbox", "Health", "Medical"],
                "footer read: \(DestinationBrowser.crumbs(for: medical, under: link.path, providerName: "Dropbox"))")

        // Control: asked by its real spelling, the folder answers in that spelling, so a
        // `listSubfolders` that prefixed everything with whatever it was handed can't pass.
        let realHealth = DestinationBrowser.listSubfolders(
            of: real.appendingPathComponent("Health").path, fileManager: FileManager.default)
        #expect(realHealth.folders.map(\.path) == [real.appendingPathComponent("Health/Medical").path])
    }

    /// A link pointing back at the root must not multiply the results. `listSubfolders` keeps
    /// symlinked directories (`fileExists(atPath:isDirectory:)` follows links), so the walk
    /// descends through them and, unguarded, finds one folder once per route. `DestinationFolder`'s
    /// `id` is its `path`, so the picker's `ForEach` would get rows sharing an id, which SwiftUI
    /// leaves undefined, and the footnote would claim a truncation that never happened.
    @Test func testASymlinkBackToTheRootDoesNotMultiplyOrTruncateTheResults() throws {
        let root = try makeCanonicalTempRoot(prefix: "DestSymlinkLoop")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Medical"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Shortcuts"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Shortcuts/Home"), withDestinationURL: root)

        let found = DestinationBrowser.search("Medical", under: root.path, fileManager: FileManager.default)

        #expect(found.matches.map(\.path) == [root.appendingPathComponent("Health/Medical").path],
                "one real folder, found once: \(found.matches.map(\.path))")
        // No two rows may share a `ForEach` id. Separate from the count, which a walk that found
        // nothing could satisfy.
        #expect(Set(found.matches.map(\.id)).count == found.matches.count,
                "two rows share an id: \(found.matches.map(\.id))")
        #expect(!found.stoppedEarly, "the walk exhausted its frontier — nothing was cut short")
        #expect(found.footnote(showing: found.matches.count) == nil,
                "footnote claimed a truncation that did not happen: \(found.footnote(showing: found.matches.count) ?? "nil")")
        // Not "couldn't be read" either: the link is readable; the walk just won't visit the same
        // directory twice.
        #expect(!found.skippedUnreadableDirectory)

        // The link is still a destination: not walking through it must not hide it from a query
        // that names it, or from the column that browses to it.
        let byName = DestinationBrowser.search("Home", under: root.path, fileManager: FileManager.default)
        #expect(byName.matches.map(\.path) == [root.appendingPathComponent("Shortcuts/Home").path])
        #expect(DestinationBrowser.listSubfolders(of: root.appendingPathComponent("Shortcuts").path,
                                                  fileManager: FileManager.default).folders.map(\.name) == ["Home"])
    }

    /// The same loop, made expensive: eight sibling links back to the root. Unguarded, one real
    /// folder would fill the match limit, and a query matching nothing would spend the listing
    /// budget and then report itself truncated, telling the user to narrow a search that had
    /// nothing left to find.
    @Test func testManyLinksBackToTheRootDoNotConsumeTheSearchBudget() throws {
        let root = try makeCanonicalTempRoot(prefix: "DestSymlinkFan")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("d3"), withIntermediateDirectories: true)
        for i in 0..<8 {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("back\(i)"), withDestinationURL: root)
        }

        let hit = DestinationBrowser.search("d3", under: root.path, fileManager: FileManager.default)
        #expect(hit.matches.map(\.path) == [root.appendingPathComponent("d3").path],
                "\(hit.matches.count) matches for one real folder")
        #expect(Set(hit.matches.map(\.id)).count == hit.matches.count)
        #expect(!hit.stoppedEarly)

        let miss = DestinationBrowser.search("zzz", under: root.path, fileManager: FileManager.default)
        #expect(miss.matches.isEmpty)
        #expect(!miss.stoppedEarly,
                "a walk that exhausted a nine-entry tree may not report itself truncated")
        #expect(miss.emptyMessage(query: "zzz") == "No folders match “zzz”",
                "got: \(miss.emptyMessage(query: "zzz"))")
    }

    /// The cycle guard holds for a root spelled the way the OS hands it out. The other fixtures
    /// use canonical roots (`makeCanonicalTempRoot`), which hides this gap: a link's stored target
    /// is canonical while the browsed root may not be, so an identity that only resolved components
    /// would see two paths and walk the cycle. Same tree as the loop test, browsed through the
    /// `/var` spelling of `FileManager.temporaryDirectory`. `resolvingSymlinksInPath` joins the two
    /// by stripping `/private`, not adding it; the premise is asserted, so a change there shows.
    @Test func testTheCycleGuardHoldsWhenTheRootIsSpelledUncanonically() throws {
        let canonical = try makeCanonicalTempRoot(prefix: "DestSymlinkVar")
        defer { try? FileManager.default.removeItem(at: canonical) }
        try FileManager.default.createDirectory(
            at: canonical.appendingPathComponent("Health/Medical"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: canonical.appendingPathComponent("Shortcuts"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: canonical.appendingPathComponent("Shortcuts/Home"), withDestinationURL: canonical)

        // The same directory, spelled the way `temporaryDirectory` hands it out.
        let uncanonical = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
            .appendingPathComponent(canonical.lastPathComponent)
        // The premise: two different strings for one directory, which the identity must join. If
        // the temp dir stops being behind /var they are one string and the fixture proves nothing,
        // so this is required, not expected.
        try #require(uncanonical.path != canonical.path,
                     "this machine's temp dir is already canonical — nothing here is being tested")
        #expect(DirectoryListingSupport.identity(of: uncanonical)
                == DirectoryListingSupport.identity(of: canonical),
                "the two spellings must reach one identity, or the guard cannot see the cycle")

        let found = DestinationBrowser.search("Medical", under: uncanonical.path, fileManager: FileManager.default)

        #expect(found.matches.map(\.path) == [uncanonical.appendingPathComponent("Health/Medical").path],
                "one real folder, found once, in the spelling asked for: \(found.matches.map(\.path))")
        #expect(Set(found.matches.map(\.id)).count == found.matches.count)
        #expect(!found.stoppedEarly)
    }

    // MARK: - Search

    /// Both `Son` folders are found, from different depths. A walk that exhausts the tree is
    /// complete: the flags must not always be true, or the picker would caveat results it fully
    /// searched.
    @Test func testSearchFindsMatchesAtEveryDepth() throws {
        let fm = try fixture()
        let outcome = DestinationBrowser.search("son", under: "/p", fileManager: fm)
        #expect(Set(outcome.matches.map(\.path)) == ["/p/Health/Medical/Kaiser/Son", "/p/School/Son"])
        #expect(outcome.matches.count == 2)
        #expect(!outcome.stoppedEarly && !outcome.skippedUnreadableDirectory)
    }

    /// Case-insensitive and substring, so three characters reach a long folder name.
    @Test func testSearchIsCaseInsensitiveSubstring() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("PRESCRIP", under: "/p", fileManager: fm).matches.map(\.name) == ["Prescriptions"])
    }

    /// Breadth-first: the shallow match is reached before the deep one, so a truncated result set
    /// holds the shallowest matches rather than whichever branch happened to be walked first.
    @Test func testSearchIsBreadthFirst() throws {
        let fm = try fixture()
        let first = DestinationBrowser.search("son", under: "/p", limit: 1, fileManager: fm)
        #expect(first.matches.map(\.path) == ["/p/School/Son"], "School/Son is two levels up from Kaiser/Son")
    }

    /// The depth cap stops the walk before the deep match.
    @Test func testSearchRespectsMaxDepth() throws {
        let fm = try fixture()
        let shallow = DestinationBrowser.search("son", under: "/p", maxDepth: 2, fileManager: fm)
        #expect(shallow.matches.map(\.path) == ["/p/School/Son"])
    }

    /// An empty or whitespace query matches nothing rather than everything: the picker shows the
    /// browse columns then, and a full-tree dump behind them would be noise. A blank query is no
    /// search, not a truncated one, or the picker would show its "showing the first N" caveat over
    /// the browse columns.
    @Test func testBlankQueryMatchesNothing() throws {
        let fm = try fixture()
        let blank = DestinationBrowser.search("", under: "/p", fileManager: fm)
        #expect(blank.matches.isEmpty)
        #expect(!blank.stoppedEarly && !blank.skippedUnreadableDirectory)
        #expect(DestinationBrowser.search("   ", under: "/p", fileManager: fm).matches.isEmpty)
    }

    // MARK: - Ranking

    /// Recents lead, in their own order.
    @Test func testRecentsRankFirstInTheirOwnOrder() {
        let matches = [
            DestinationFolder(path: "/p/School/Son"),
            DestinationFolder(path: "/p/Health/Medical/Kaiser/Son"),
        ]
        let ranked = DestinationBrowser.ranked(
            matches,
            recents: ["/p/Health/Medical/Kaiser/Son", "/p/School/Son"],
            query: "son",
            under: "/p"
        )
        #expect(ranked.map(\.path) == ["/p/Health/Medical/Kaiser/Son", "/p/School/Son"])
    }

    /// With no recency to go on, an exact name beats a mere substring.
    @Test func testExactNameBeatsSubstring() {
        let matches = [
            DestinationFolder(path: "/p/Sonations"),
            DestinationFolder(path: "/p/Son"),
        ]
        let ranked = DestinationBrowser.ranked(matches, recents: [], query: "son", under: "/p")
        #expect(ranked.map(\.name) == ["Son", "Sonations"])
    }

    /// Equal on name, the shallower folder wins.
    @Test func testShallowerBeatsDeeper() {
        let matches = [
            DestinationFolder(path: "/p/Health/Medical/Kaiser/Son"),
            DestinationFolder(path: "/p/School/Son"),
        ]
        let ranked = DestinationBrowser.ranked(matches, recents: [], query: "son", under: "/p")
        #expect(ranked.map(\.path) == ["/p/School/Son", "/p/Health/Medical/Kaiser/Son"])
    }

    /// A recent that is NOT among the matches must not be injected into the results.
    @Test func testRankingNeverAddsFolders() {
        let matches = [DestinationFolder(path: "/p/School/Son")]
        let ranked = DestinationBrowser.ranked(
            matches, recents: ["/p/Health/Prescriptions"], query: "son", under: "/p"
        )
        #expect(ranked.map(\.path) == ["/p/School/Son"])
    }

    // MARK: - Trail

    /// One test's trail checks: (path, root, the trail expected).
    struct TrailCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let checks: [(path: String, root: String, trail: [String])]
    }

    static let trails: [TrailCase] = [
        // Every level between the provider folder and the match, so two same-named folders read
        // differently.
        TrailCase(testDescription: "same-named folders", checks: [
            ("/p/Health/Medical/Kaiser/Son", "/p", ["p", "Health", "Medical", "Kaiser"]),
            ("/p/School/Son", "/p", ["p", "School"])]),
        TrailCase(testDescription: "a top-level folder trails just the root",
                  checks: [("/p/Health", "/p", ["p"])]),
        // There is no level between a folder and itself. Checked on a realistic root too: `/p`'s
        // parent is `/`, which splits to an empty array by luck and would hide a fall-through to
        // the outside-the-root branch (the root's own ancestors). A trailing slash is the same folder.
        TrailCase(testDescription: "the root itself trails nothing", checks: [
            ("/p", "/p", []),
            ("/Users/me/Dropbox", "/Users/me/Dropbox", []),
            ("/Users/me/Dropbox/", "/Users/me/Dropbox", [])]),
        // The system-panel escape still reads as its own parents rather than coming back empty.
        TrailCase(testDescription: "outside the root", checks: [("/elsewhere/Deep/Folder", "/p", ["elsewhere", "Deep"])]),
        // Prefix aliasing: "/p" must not claim "/pictures/x".
        TrailCase(testDescription: "a sibling sharing a prefix", checks: [("/pictures/Deep/Folder", "/p", ["pictures", "Deep"])]),
    ]

    @Test(arguments: trails)
    func testTrail(_ c: TrailCase) {
        for check in c.checks {
            #expect(DestinationBrowser.trail(of: check.path, under: check.root) == check.trail,
                    "trail of \(check.path) under \(check.root)")
        }
    }

    // MARK: - Breadcrumbs

    /// One test's crumb checks: (folder, root, provider name, the crumbs expected).
    struct CrumbCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let checks: [(folder: String, root: String, provider: String, crumbs: [String])]
    }

    static let crumbCases: [CrumbCase] = {
        let iCloud = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        return [
            // The footer names the provider, then every level down to the chosen folder.
            CrumbCase(testDescription: "the provider, then every level", checks: [
                ("/Users/me/Dropbox/Health/Medical", "/Users/me/Dropbox", "Dropbox", ["Dropbox", "Health", "Medical"]),
                ("/Users/me/Dropbox/Health", "/Users/me/Dropbox", "Dropbox", ["Dropbox", "Health"])]),
            // The root is one crumb, the provider's name, not its ancestors ("Dropbox › me ›
            // Dropbox"). It is the rail's "Places" row, the card's most reachable control. The
            // provider name differs from the folder name, as for iCloud Drive's
            // `com~apple~CloudDocs`: with the two equal, a fall-through to the outside-the-root
            // branch would give the right answer by accident. A trailing slash on either side is
            // the same folder, and one level down still swaps the display name in.
            CrumbCase(testDescription: "the root is just the provider name", checks: [
                (iCloud, iCloud, "iCloud Drive", ["iCloud Drive"]),
                (iCloud + "/", iCloud, "iCloud Drive", ["iCloud Drive"]),
                (iCloud, iCloud + "/", "iCloud Drive", ["iCloud Drive"]),
                (iCloud + "/Receipts", iCloud, "iCloud Drive", ["iCloud Drive", "Receipts"])]),
            // A folder reached through `Other…` is outside the provider, so it reads as its own
            // path, not under the provider's name.
            CrumbCase(testDescription: "outside the root", checks: [
                ("/Volumes/Archive/2025", "/Users/me/Dropbox", "Dropbox", ["Volumes", "Archive", "2025"])]),
            // Prefix aliasing: "/p" must not claim "/pictures/x" and swap in the provider name.
            CrumbCase(testDescription: "a sibling sharing a prefix", checks: [("/pictures/Deep", "/p", "P", ["pictures", "Deep"])]),
            // No folder chosen yet is no crumbs, which is what the footer's placeholder keys on.
            CrumbCase(testDescription: "no destination", checks: [("", "/p", "P", [])]),
        ]
    }()

    @Test(arguments: crumbCases)
    func testCrumbs(_ c: CrumbCase) {
        for check in c.checks {
            #expect(DestinationBrowser.crumbs(for: check.folder, under: check.root, providerName: check.provider)
                    == check.crumbs, "crumbs for \(check.folder) under \(check.root)")
        }
    }

    // MARK: - Pre-flight refusals

    /// Moving a folder into itself, or into anything under it.
    @Test func testDestinationInsideSelectionIsRefused() {
        #expect(DestinationBrowser.destinationIsInsideSelection("/p/Health", sources: ["/p/Health"]))
        #expect(DestinationBrowser.destinationIsInsideSelection("/p/Health/Medical/Kaiser", sources: ["/p/Health"]))
        #expect(!DestinationBrowser.destinationIsInsideSelection("/p/School", sources: ["/p/Health"]))
    }

    /// Boundary-safe: "/p/Health" must not claim "/p/HealthRecords".
    @Test func testNestingCheckStopsAtAComponentBoundary() {
        #expect(!DestinationBrowser.destinationIsInsideSelection("/p/HealthRecords", sources: ["/p/Health"]))
    }

    /// Every item already sitting in the destination is detected, so the picker can say so rather
    /// than move nothing silently.
    @Test func testAllSourcesAlreadyInIsDetected() {
        #expect(DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/a.pdf", "/p/Health/b.pdf"]))
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/a.pdf", "/p/School/b.pdf"]))
    }

    /// An empty selection is not "already there": there is nothing to say.
    @Test func testEmptySelectionIsNotAlreadyThere() {
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: []))
    }

    /// A file nested deeper than the destination has not arrived: only its immediate parent counts,
    /// or moving `/p/Health/Medical/x.pdf` into `/p/Health` would be reported as a no-op.
    @Test func testOnlyTheImmediateParentCountsAsAlreadyThere() {
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/Medical/x.pdf"]))
    }

    // MARK: - Collision preview

    /// One collision preview: files planted in the fixture, the selection, the destination, and
    /// the names expected, in selection order (the order the tooltip lists them in).
    struct Collision: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var planted: [String] = []
        let from: [String]
        let into: String
        let expected: [String]
    }

    static let collisions: [Collision] = [
        Collision(testDescription: "a taken name is reported, a free one is not",
                  planted: ["/p/School/report.pdf"],
                  from: ["/p/Health/report.pdf", "/p/Health/notes.txt"], into: "/p/School", expected: ["report.pdf"]),
        // Or the picker would report a collision and the already-there refusal for one file.
        Collision(testDescription: "an item already in the destination does not collide with itself",
                  planted: ["/p/School/settled.pdf"],
                  from: ["/p/School/settled.pdf"], into: "/p/School", expected: []),
        // Replacing a folder replaces its whole contents: the case most worth seeing first.
        Collision(testDescription: "a folder name collides too",
                  from: ["/p/School/Son"], into: "/p/Health/Medical/Kaiser", expected: ["Son"]),
        Collision(testDescription: "every name free",
                  from: ["/p/Health/a.pdf", "/p/Health/b.pdf"], into: "/p/School", expected: []),
        Collision(testDescription: "no destination is not a question yet",
                  from: ["/p/Health/a.pdf"], into: "", expected: []),
        // The move is flat, so both derive the same target and the second prompts. Nothing need
        // be on disk, so an existence check alone would report a clean move and then ask anyway.
        // One name, one prompt — not one entry per source.
        Collision(testDescription: "two selected items sharing a name",
                  from: ["/p/Health/report.pdf", "/p/School/report.pdf"], into: "/p/Health/Prescriptions",
                  expected: ["report.pdf"]),
        // The footer counts names, and the second and third both land on the same target.
        Collision(testDescription: "three of a name is one name",
                  from: ["/p/Health/x.pdf", "/p/School/x.pdf", "/p/Health/Medical/x.pdf"], into: "/p/School/Son",
                  expected: ["x.pdf"]),
        // Taken in the destination and repeated in the selection, or the footer counts it twice.
        Collision(testDescription: "a name colliding for both reasons is reported once",
                  planted: ["/p/School/dup.pdf"],
                  from: ["/p/Health/dup.pdf", "/p/Health/Medical/dup.pdf"], into: "/p/School", expected: ["dup.pdf"]),
        // The within-selection rule must not turn every multi-item move into a warning.
        Collision(testDescription: "distinct names from different folders stay clean",
                  from: ["/p/Health/a.pdf", "/p/School/b.pdf", "/p/Health/Medical/c.pdf"],
                  into: "/p/Health/Prescriptions", expected: []),
        Collision(testDescription: "selection order is kept",
                  planted: ["/p/School/zebra.pdf", "/p/School/apple.pdf"],
                  from: ["/p/Health/zebra.pdf", "/p/Health/apple.pdf"], into: "/p/School",
                  expected: ["zebra.pdf", "apple.pdf"]),
    ]

    @Test(arguments: collisions)
    func testCollidingNames(_ c: Collision) throws {
        let fm = try fixture()
        for path in c.planted {
            fm.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        #expect(DestinationBrowser.collidingNames(movingFrom: c.from, into: c.into, fileManager: fm) == c.expected)
    }

    // MARK: - Search cost

    /// The listing cap bounds the walk by directories read, not matches found. The expensive query
    /// matches nothing: `limit` never bites, and the walk would read every directory within
    /// `maxDepth` before answering.
    @Test func testSearchStopsAfterItsListingBudget() throws {
        // Zero-padded so every sibling name is the same length: the mock's enumerator matches
        // children by string prefix, and "/p/d1" would otherwise claim "/p/d10" as its own child.
        let fm = MockFileManager()
        for i in 0..<12 {
            let parent = String(format: "/p/d%02d", i)
            try fm.createDirectory(at: URL(fileURLWithPath: parent), withIntermediateDirectories: true)
            for j in 0..<4 {
                try fm.createDirectory(at: URL(fileURLWithPath: String(format: "%@/e%02d", parent, j)),
                                       withIntermediateDirectories: true)
            }
        }
        var listings = 0
        fm.onEnumerate = { _ in listings += 1 }

        // Nothing matches, so `limit` never bites and only the listing budget can stop it.
        _ = DestinationBrowser.search("nothingmatchesthis", under: "/p", maxListings: 5, fileManager: fm)
        #expect(listings <= 5, "read \(listings) directories against a budget of 5")

        // …and the budget is a real ceiling: unbudgeted, the same query reads the whole tree.
        listings = 0
        _ = DestinationBrowser.search("nothingmatchesthis", under: "/p", fileManager: fm)
        #expect(listings == 61, "/p plus its 12 children plus their 48 — every directory there is")
    }

    /// Cancellation is polled per directory, so a superseded keystroke's walk stops rather than run
    /// on behind the one the user is waiting for. An explicit hook, not `Task.isCancelled`, because
    /// `Task.detached` doesn't inherit cancellation.
    @Test func testSearchStopsWhenCancelled() throws {
        let fm = try fixture()
        var listings = 0
        fm.onEnumerate = { _ in listings += 1 }
        let found = DestinationBrowser.search("son", under: "/p", fileManager: fm,
                                              isCancelled: { true })
        #expect(found.matches.isEmpty)
        #expect(listings == 0, "cancelled before the first directory was even read")
    }

    // MARK: - Truncation is reported, not silent

    /// Each of the three caps stops the walk early and must say so: a partial list read as the
    /// complete one leads to "the folder isn't there".
    @Test func testEveryCapReportsTruncation() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("son", under: "/p", limit: 1, fileManager: fm).stoppedEarly,
                "match limit")
        #expect(DestinationBrowser.search("son", under: "/p", maxDepth: 2, fileManager: fm).stoppedEarly,
                "depth ceiling — Kaiser/Son is below it")
        #expect(DestinationBrowser.search("son", under: "/p", maxListings: 1, fileManager: fm).stoppedEarly,
                "listing budget")
    }

    // MARK: - Folders a root links to (iCloud Drive's Documents)

    /// iCloud Drive with Desktop & Documents syncing: the container's `Documents` is a hidden link
    /// to `~/Documents`, so the enumerator never lists it. The fixture models that by leaving the
    /// link out of the container altogether, and hands the table in, as `PathBoundary` would.
    private func linkedFixture() throws -> (MockFileManager, PathBoundary.LinkedFolders) {
        let fm = MockFileManager()
        for dir in ["/icloud", "/icloud/Downloads", "/icloud/Word",
                    "/home/Documents", "/home/Documents/Travel", "/home/Documents/Travel/Trips"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        // `Desktop` is in the table but missing on disk: it must not be offered.
        return (fm, ["/icloud": ["Documents": "/home/Documents", "Desktop": "/home/Desktop"]])
    }

    /// The root column lists Documents, at its real path, under the link's name, so everything in
    /// Documents can be reached from the iCloud root.
    @Test func testARootListsTheFoldersItLinksTo() throws {
        let (fm, links) = try linkedFixture()
        let folders = DestinationBrowser.listSubfolders(of: "/icloud", fileManager: fm, links: links).folders
        #expect(folders.map(\.name) == ["Documents", "Downloads", "Word"])
        #expect(folders.first?.path == "/home/Documents")
        // Control: one level down is an ordinary listing, untouched by the table.
        let travel = DestinationBrowser.listSubfolders(of: "/home/Documents/Travel", fileManager: fm, links: links)
        #expect(travel.folders.map(\.path) == ["/home/Documents/Travel/Trips"])
    }

    /// Search starts from the root listing, so it reaches into Documents too.
    @Test func testSearchReachesThroughALinkedFolder() throws {
        let (fm, links) = try linkedFixture()
        let found = DestinationBrowser.search("Trips", under: "/icloud", fileManager: fm, links: links)
        #expect(found.matches.map(\.path) == ["/home/Documents/Travel/Trips"])
    }

    /// The footer reads from the provider down, through the link's name, never from `/Users`.
    @Test func testCrumbsForALinkedFolderReadFromTheProvider() throws {
        let (_, links) = try linkedFixture()
        let trips = "/home/Documents/Travel/Trips"
        #expect(DestinationBrowser.trail(of: trips, under: "/icloud", links: links) == ["icloud", "Documents", "Travel"])
        #expect(DestinationBrowser.crumbs(for: trips, under: "/icloud", providerName: "iCloud", links: links)
                == ["iCloud", "Documents", "Travel", "Trips"])
        #expect(DestinationBrowser.crumbs(for: "/home/Documents", under: "/icloud", providerName: "iCloud", links: links)
                == ["iCloud", "Documents"])
        // Control: with no table the same path is outside the root and speaks for itself.
        #expect(DestinationBrowser.crumbs(for: trips, under: "/icloud", providerName: "iCloud", links: [:])
                == ["home", "Documents", "Travel", "Trips"])
    }

    /// The linked folder itself, under a real home path, reads from the provider. Its parent is the
    /// home folder, which no root holds, so a trail built from the parent would read "iCloud › me ›
    /// Documents". A multi-component home is used because a one-component one hides that:
    /// `dropFirst` removes the only wrong crumb.
    @Test func testTheLinkedFolderItselfReadsFromTheProvider() {
        let links: PathBoundary.LinkedFolders = ["/icloud": ["Documents": "/Users/me/Documents"]]
        #expect(DestinationBrowser.trail(of: "/Users/me/Documents", under: "/icloud", links: links) == ["icloud"])
        #expect(DestinationBrowser.crumbs(for: "/Users/me/Documents", under: "/icloud", providerName: "iCloud", links: links)
                == ["iCloud", "Documents"])
        #expect(DestinationBrowser.crumbs(for: "/Users/me/Documents/Travel", under: "/icloud", providerName: "iCloud",
                                          links: links) == ["iCloud", "Documents", "Travel"])
    }
}
