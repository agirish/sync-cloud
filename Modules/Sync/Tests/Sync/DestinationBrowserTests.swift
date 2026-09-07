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

    /// Folders only, name-sorted. A file row would be a destination you cannot pick.
    @Test func testSubfoldersListsDirectoriesOnly() throws {
        let fm = try fixture()
        let names = DestinationBrowser.listSubfolders(of: "/p", fileManager: fm).folders.map(\.name)
        #expect(names == ["Health", "School"])
    }

    /// Dot-directories are dropped by name as well as by the enumerator's hidden flag — a folder
    /// can be one without the other.
    @Test func testHiddenFoldersAreDroppedUnlessAsked() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.listSubfolders(of: "/p", fileManager: fm).folders.map(\.name) == ["Health", "School"])
        let shown = DestinationBrowser.listSubfolders(of: "/p", showHidden: true, fileManager: fm).folders.map(\.name)
        #expect(shown.contains(".hidden"))
    }

    /// A path with nothing under it is empty, not an error — the picker renders "Empty" for it.
    @Test func testLeafFolderListsNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.listSubfolders(of: "/p/School/Son", fileManager: fm).folders.isEmpty)
    }

    /// An empty root would otherwise resolve against the process working directory.
    @Test func testEmptyRootListsNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.listSubfolders(of: "", fileManager: fm).folders.isEmpty)
    }

    // MARK: - Listing a folder that cannot be read

    /// The column under a folder nobody could open used to read "Empty" — a statement about
    /// contents nobody saw, and the same defect as the folder-replace warning's "0 items". The
    /// three cases are asserted together because what makes this a fix is that they differ.
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

    /// The third case, which a `!=` comparison silently folded into the first.
    ///
    /// `emptyMessage` asked `outcome == .unreadable ? "Can't be read" : "Empty"`, so a PARTIAL
    /// listing with no subfolders — the folder opened, something below it did not — announced
    /// itself as **"Empty"**: a claim about contents nobody saw, which is the exact conflation
    /// `DirectoryListingOutcome`'s three cases exist to stop, reintroduced one case along.
    ///
    /// `listSubfolders` always lists shallowly and so cannot produce this value today. The type is
    /// public and the wording is part of it, so the rule is asserted on the value rather than on
    /// the route to it — an unreachable branch that is wrong is still wrong the day it is reached.
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

    /// A directory the walk could not read means the walk did not establish "no folders match" —
    /// the same reasoning the three caps already carry, applied to the fourth way of missing a
    /// match. The pair is the test: the identical query over the identical tree answers
    /// "complete" when everything was readable.
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

    /// The two reasons a result list can be short of the truth are DIFFERENT reasons, and the
    /// advice under the list is opposite for each — so they cannot travel as one boolean.
    ///
    /// A cap stops the walk EARLY: the rows are "the first N" and a tighter query reaches further.
    /// An unreadable directory lets the walk FINISH and withholds a subtree from it: the rows are
    /// every match there was, and no query will ever open that folder. Rolled together, the second
    /// case rendered the first case's sentence, which was false on both halves.
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

        // …and both at once, which neither of the above can stand in for. The blocked folder has
        // to sit where the walk MEETS it before the cap trips: breadth-first with `limit: 1`,
        // `/p/Health` is listed (and refused) in the same pass that finds `/p/School/Son`.
        // Blocking `/p/Health/Medical` instead would leave the walk returning a level too early
        // to have noticed, which is how this arm first passed with only one of the two facts set.
        let blockedHigh = try fixture()
        blockedHigh.unlistableDirectories = ["/p/Health"]
        let both = DestinationBrowser.search("son", under: "/p", limit: 1, fileManager: blockedHigh)
        #expect(both.stoppedEarly)
        #expect(both.skippedUnreadableDirectory)
    }

    /// The sentence a person actually reads under a NON-empty list. The commit that introduced the
    /// fourth cause reasoned only about the empty-results wording; this is the branch it missed,
    /// and both halves of the old sentence were false there.
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
        // The two specific claims that were false. Stated in the negative as well as by equality,
        // because a reworded sentence could reintroduce either one on its own.
        #expect(!text.contains("the first"), "this walk completed — these are not “the first 3”")
        #expect(!text.contains("narrow"), "narrowing cannot reach behind a permission-denied folder")

        let both = DestinationSearchOutcome(matches: [], stoppedEarly: true,
                                            skippedUnreadableDirectory: true)
        #expect(both.footnote(showing: 3)
                == "Showing the first 3, and some folders couldn’t be read — there may be more either way.")
    }

    /// The empty-results wording, which does survive the fourth cause but must not flatten it back
    /// into the caps' advice either. Four inputs, four different sentences.
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

    /// The picker announced **"Can't be read"** about a folder Finder lists fine, and `search`
    /// flagged a walk that had completed and returned every match as truncated — because
    /// `FileManager.enumerator(at:)` refuses to traverse a symlinked directory, yielding zero
    /// entries and firing its error handler, which is byte for byte the signature of a locked one.
    ///
    /// Against the REAL filesystem, because the behaviour is the real `FileManager`'s; the mock
    /// disk has no symlinks and could only be evidence about itself. The control is the point: the
    /// same two questions asked of the link's own target must give the same two answers, or this
    /// test would pass for a `listSubfolders` that had simply stopped finding anything.
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

    /// **Drilling one level INTO a symlinked folder must keep the caller's spelling too.**
    ///
    /// The re-spelling that makes the test above pass fires only on the RETRY, and the retry fires
    /// only when the FINAL path component is the link. One level in, the direct walk succeeds and
    /// the enumerator hands back the canonicalised TARGET path, which nothing re-spells. Measured
    /// on a real disk before the fix:
    ///
    ///     listSubfolders(of: <base>/link)        → ["<base>/link/Health"]            ✓
    ///     listSubfolders(of: <base>/link/Health) → ["<base>/real/Health/Medical"]    ✗
    ///
    /// The second line is not under the root the picker is browsing, so `trail` takes its
    /// "outside the root" escape and hands back every component — the footer read
    /// `Dropbox › private › var › folders › c6 › … › real › Health › Medical`, which is the exact
    /// failure `trail`'s own docstring cites as the bug it exists to stop. `highlighted` (what Move
    /// commits to) and the recents key diverge from the browsed path the same way.
    ///
    /// Newly reachable: before the symlink fallback landed, `listSubfolders(of: link)` answered
    /// `.unreadable`, so there was no level two to reach.
    ///
    /// Asserted at BOTH levels over the same tree, because level one alone is what shipped: the
    /// existing fixture's leaves sit at depth 1, exactly the depth where re-spelling does fire.
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

        // The user-visible consequence, stated as the footer renders it. `#require` rather than a
        // subscript after `#expect`: `#expect` records and continues, so indexing an empty array on
        // the next line would trap the test host and lose the run.
        let medical = try #require(level2.folders.first).path
        #expect(DestinationBrowser.trail(of: medical, under: link.path) == ["link", "Health"],
                "trail took its outside-the-root escape: \(DestinationBrowser.trail(of: medical, under: link.path))")
        #expect(DestinationBrowser.crumbs(for: medical, under: link.path, providerName: "Dropbox")
                == ["Dropbox", "Health", "Medical"],
                "footer read: \(DestinationBrowser.crumbs(for: medical, under: link.path, providerName: "Dropbox"))")

        // Control: the same folder asked about by its real spelling still answers in that spelling.
        // Without this the assertions above would pass for a `listSubfolders` that had simply
        // started prefixing everything with whatever it was handed.
        let realHealth = DestinationBrowser.listSubfolders(
            of: real.appendingPathComponent("Health").path, fileManager: FileManager.default)
        #expect(realHealth.folders.map(\.path) == [real.appendingPathComponent("Health/Medical").path])
    }

    /// **A link pointing back at the root must not multiply the results.**
    ///
    /// `listSubfolders`' filter keeps symlinked directories — `fileExists(atPath:isDirectory:)`
    /// follows links — and once a `listSubfolders` of one succeeds, the breadth-first walk descends
    /// through them. Before these commits a symlinked directory was a dead end for the walk, so
    /// this is newly reachable. Measured on a real disk before the fix, with
    /// `root/Shortcuts/Home -> root`:
    ///
    ///     search("Medical") → 3 matches, ALL WITH THE SAME `path`
    ///
    /// `DestinationFolder: Identifiable` has `id { path }`, so `ForEach(ranked)` in the picker got
    /// three rows carrying one id — undefined behaviour by SwiftUI's own documentation. The
    /// footnote rendered "Showing the first 3 — narrow the search, or browse to it", which is false
    /// twice over: the walk found ONE folder three times, and it was not cut short.
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
        // The non-negotiable one, stated separately from the count so it cannot be satisfied by a
        // walk that simply found nothing: no two rows may carry the same `ForEach` id.
        #expect(Set(found.matches.map(\.id)).count == found.matches.count,
                "two rows share an id: \(found.matches.map(\.id))")
        #expect(!found.stoppedEarly, "the walk exhausted its frontier — nothing was cut short")
        #expect(found.footnote(showing: found.matches.count) == nil,
                "footnote claimed a truncation that did not happen: \(found.footnote(showing: found.matches.count) ?? "nil")")
        // Not "couldn't be read" either: the link IS readable, the walk simply declines to arrive
        // at the same directory twice. Nothing was withheld from it.
        #expect(!found.skippedUnreadableDirectory)

        // The link is still a destination in its own right — declining to walk THROUGH it must not
        // hide it from a query that names it, nor from the column that browses to it.
        let byName = DestinationBrowser.search("Home", under: root.path, fileManager: FileManager.default)
        #expect(byName.matches.map(\.path) == [root.appendingPathComponent("Shortcuts/Home").path])
        #expect(DestinationBrowser.listSubfolders(of: root.appendingPathComponent("Shortcuts").path,
                                                  fileManager: FileManager.default).folders.map(\.name) == ["Home"])
    }

    /// The same loop, made expensive. Eight sibling links back to the root turned a one-folder
    /// answer into the whole limit, and turned a query that matches NOTHING into a walk that spent
    /// its entire listing budget and then reported itself truncated. Measured before the fix:
    ///
    ///     search("d3")  → 60 matches (the limit) for 1 real folder
    ///     search("zzz") → stoppedEarly = true, having found nothing anywhere
    ///
    /// The second is the one that reaches the user as a lie: "narrow the search" about a tree the
    /// walk never actually ran out of.
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

    /// The cycle guard must survive a root spelled the way the OS hands it out.
    ///
    /// Every other fixture here is rooted at a CANONICAL path, via `makeCanonicalTempRoot`, which
    /// hides the one gap that has broken path comparison in this repo before: a link's stored target
    /// is absolute and canonical, while the root being browsed is not, so an identity function that
    /// merely resolved *components* would leave the two comparing unequal and walk the cycle anyway.
    /// This is the same tree as the loop test above, browsed through the `/var` spelling a caller
    /// gets straight from `FileManager.temporaryDirectory`.
    ///
    /// The premise is asserted, not assumed: measured, `resolvingSymlinksInPath` closes the gap by
    /// STRIPPING `/private` rather than adding it, which is why both spellings land on one form.
    /// The day that stops being true this fixture is what notices.
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
        // The premise, measured rather than assumed: two genuinely different strings for one
        // directory, which the identity function is expected to bring together. If the temp dir
        // ever stops being behind /var these are the same string and the fixture proves nothing —
        // so that is required, not merely expected.
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

    /// Both `Son` folders are found, from different depths.
    @Test func testSearchFindsMatchesAtEveryDepth() throws {
        let fm = try fixture()
        let paths = Set(DestinationBrowser.search("son", under: "/p", fileManager: fm).matches.map(\.path))
        #expect(paths == ["/p/Health/Medical/Kaiser/Son", "/p/School/Son"])
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

    /// An empty or whitespace query matches nothing rather than everything — the picker shows the
    /// browse columns in that state, and a full-tree dump behind them would be noise.
    @Test func testBlankQueryMatchesNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("", under: "/p", fileManager: fm).matches.isEmpty)
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

    /// The trail names the provider folder and every level between it and the match, so two
    /// same-named folders read differently.
    @Test func testTrailDistinguishesSameNamedFolders() {
        #expect(DestinationBrowser.trail(of: "/p/Health/Medical/Kaiser/Son", under: "/p")
                == ["p", "Health", "Medical", "Kaiser"])
        #expect(DestinationBrowser.trail(of: "/p/School/Son", under: "/p") == ["p", "School"])
    }

    /// A folder directly under the root trails just the root.
    @Test func testTrailOfATopLevelFolderIsTheRoot() {
        #expect(DestinationBrowser.trail(of: "/p/Health", under: "/p") == ["p"])
    }

    /// The root trails NOTHING — there is no level between a folder and itself.
    ///
    /// The `/p` fixture hid this: `"/p".deletingLastPathComponent` is `"/"`, which splits to the
    /// empty array by luck. A realistic root fell through to the outside-the-root branch and
    /// answered with the root's own ancestors.
    @Test func testTheRootItselfTrailsNothing() {
        #expect(DestinationBrowser.trail(of: "/p", under: "/p").isEmpty)
        #expect(DestinationBrowser.trail(of: "/Users/me/Dropbox", under: "/Users/me/Dropbox").isEmpty)
        #expect(DestinationBrowser.trail(of: "/Users/me/Dropbox/", under: "/Users/me/Dropbox").isEmpty,
                "a trailing slash is the same folder")
    }

    /// A path outside the root (the system-panel escape) still reads as its own parents rather
    /// than coming back empty.
    @Test func testTrailOutsideTheRootFallsBackToItsOwnParents() {
        #expect(DestinationBrowser.trail(of: "/elsewhere/Deep/Folder", under: "/p")
                == ["elsewhere", "Deep"])
    }

    /// Prefix aliasing: "/p" must not claim "/pictures/x".
    @Test func testTrailDoesNotClaimASiblingSharingAPrefix() {
        #expect(DestinationBrowser.trail(of: "/pictures/Deep/Folder", under: "/p")
                == ["pictures", "Deep"])
    }

    // MARK: - Breadcrumbs

    /// The footer names the provider, then every level down to the chosen folder.
    @Test func testCrumbsNameTheProviderThenEveryLevel() {
        #expect(DestinationBrowser.crumbs(for: "/Users/me/Dropbox/Health/Medical",
                                          under: "/Users/me/Dropbox", providerName: "Dropbox")
                == ["Dropbox", "Health", "Medical"])
        #expect(DestinationBrowser.crumbs(for: "/Users/me/Dropbox/Health",
                                          under: "/Users/me/Dropbox", providerName: "Dropbox")
                == ["Dropbox", "Health"])
    }

    /// The root is ONE crumb, and it is the PROVIDER'S name. This is the rail's "Places" row — one
    /// click, the most reachable control on the card — and it used to render the root's own
    /// ancestors between the two: "Dropbox › me › Dropbox".
    ///
    /// The provider name deliberately differs from the folder name here, because that is the real
    /// case and the only one that can tell the two failure modes apart: iCloud Drive's root folder
    /// is literally `com~apple~CloudDocs`. With the names equal, falling through to the
    /// outside-the-root branch produces the right answer for the wrong reason.
    @Test func testCrumbsForTheRootAreJustTheProviderName() {
        let root = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(DestinationBrowser.crumbs(for: root, under: root, providerName: "iCloud Drive")
                == ["iCloud Drive"])
        #expect(DestinationBrowser.crumbs(for: root + "/", under: root, providerName: "iCloud Drive")
                == ["iCloud Drive"], "a trailing slash is the same folder")
        #expect(DestinationBrowser.crumbs(for: root, under: root + "/", providerName: "iCloud Drive")
                == ["iCloud Drive"], "…on either side")

        // And one level down still swaps the display name in for the root's folder name.
        #expect(DestinationBrowser.crumbs(for: root + "/Receipts", under: root,
                                          providerName: "iCloud Drive")
                == ["iCloud Drive", "Receipts"])
    }

    /// A folder reached through `Other…` is outside the provider, so the provider's name would be a
    /// lie. It reads as its own path instead.
    @Test func testCrumbsOutsideTheRootDoNotClaimTheProvider() {
        let crumbs = DestinationBrowser.crumbs(for: "/Volumes/Archive/2025",
                                               under: "/Users/me/Dropbox", providerName: "Dropbox")
        #expect(crumbs == ["Volumes", "Archive", "2025"])
        #expect(!crumbs.contains("Dropbox"))
    }

    /// Prefix aliasing at the crumb layer too: "/p" must not claim "/pictures/x" and swap in the
    /// provider name for "pictures".
    @Test func testCrumbsDoNotClaimASiblingSharingAPrefix() {
        #expect(DestinationBrowser.crumbs(for: "/pictures/Deep", under: "/p", providerName: "P")
                == ["pictures", "Deep"])
    }

    /// No folder chosen yet is no crumbs, which is what the footer's placeholder keys on.
    @Test func testCrumbsForNoDestinationAreEmpty() {
        #expect(DestinationBrowser.crumbs(for: "", under: "/p", providerName: "P").isEmpty)
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

    /// Every item already sitting in the destination — the case that used to move nothing and say
    /// nothing.
    @Test func testAllSourcesAlreadyInIsDetected() {
        #expect(DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/a.pdf", "/p/Health/b.pdf"]))
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/a.pdf", "/p/School/b.pdf"]))
    }

    /// An empty selection is not "already there" — there is simply nothing to say.
    @Test func testEmptySelectionIsNotAlreadyThere() {
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: []))
    }

    /// A file nested DEEPER than the destination has not arrived: only its immediate parent counts,
    /// or moving `/p/Health/Medical/x.pdf` into `/p/Health` would be reported as a no-op.
    @Test func testOnlyTheImmediateParentCountsAsAlreadyThere() {
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/Medical/x.pdf"]))
    }

    // MARK: - Collision preview

    /// A name already taken in the destination is reported, one that is free is not.
    @Test func testCollidingNamesReportsOnlyTakenNames() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/report.pdf", "/p/Health/notes.txt"],
            into: "/p/School",
            fileManager: fm
        )
        #expect(colliding == ["report.pdf"])
    }

    /// An item ALREADY in the destination is not colliding with itself. Without this, opening the
    /// picker on a folder the file already sits in would report a collision AND the already-there
    /// refusal — two contradictory statements about one file.
    @Test func testAnItemAlreadyInTheDestinationIsNotACollision() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/settled.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/School/settled.pdf"], into: "/p/School", fileManager: fm
        )
        #expect(colliding.isEmpty)
    }

    /// A folder whose name is taken collides exactly as a file does — replacing a folder replaces
    /// its whole contents, so this is the case most worth seeing before confirming.
    @Test func testAFolderNameCollidesToo() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/School/Son"], into: "/p/Health/Medical/Kaiser", fileManager: fm
        )
        #expect(colliding == ["Son"])
    }

    /// Every name free means no preview to show.
    @Test func testNoCollisionsWhenEveryNameIsFree() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/a.pdf", "/p/Health/b.pdf"], into: "/p/School", fileManager: fm
        )
        #expect(colliding.isEmpty)
    }

    /// An empty destination is not a question yet.
    @Test func testNoDestinationYieldsNoCollisions() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.collidingNames(movingFrom: ["/p/Health/a.pdf"], into: "", fileManager: fm).isEmpty)
    }

    /// Two selected items sharing a name collide with EACH OTHER: the move is flat, so both derive
    /// the same target, the first arrives and the second prompts. Nothing has to be on disk for
    /// this, which is why an existence check alone reported a clean move and then asked anyway.
    @Test func testTwoSelectedItemsSharingANameCollide() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/report.pdf", "/p/School/report.pdf"],
            into: "/p/Health/Prescriptions",
            fileManager: fm
        )
        #expect(colliding == ["report.pdf"], "one name, one prompt — not one entry per source")
    }

    /// Three of a name is still one name: the footer counts names, and the second and third both
    /// land on the same target.
    @Test func testARepeatedNameIsReportedOnce() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/x.pdf", "/p/School/x.pdf", "/p/Health/Medical/x.pdf"],
            into: "/p/School/Son",
            fileManager: fm
        )
        #expect(colliding == ["x.pdf"])
    }

    /// A name that collides for BOTH reasons at once — taken in the destination and repeated within
    /// the selection — is still one name. Without de-duplication the footer would say "2 of 2
    /// names" for what is one file's worth of question.
    @Test func testANameCollidingForBothReasonsIsReportedOnce() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/dup.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/dup.pdf", "/p/Health/Medical/dup.pdf"],
            into: "/p/School",
            fileManager: fm
        )
        #expect(colliding == ["dup.pdf"])
    }

    /// Distinct names from distinct folders are still clean — the within-selection rule must not
    /// turn every multi-item move into a warning.
    @Test func testDistinctNamesFromDifferentFoldersStayClean() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/a.pdf", "/p/School/b.pdf", "/p/Health/Medical/c.pdf"],
            into: "/p/Health/Prescriptions",
            fileManager: fm
        )
        #expect(colliding.isEmpty)
    }

    /// Reported in selection order, which is the order the tooltip lists them in.
    @Test func testCollidingNamesKeepSelectionOrder() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/zebra.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.virtualDisk["/p/School/apple.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/zebra.pdf", "/p/Health/apple.pdf"],
            into: "/p/School",
            fileManager: fm
        )
        #expect(colliding == ["zebra.pdf", "apple.pdf"])
    }

    // MARK: - Search cost

    /// The listing cap bounds the walk by directories READ, not by matches found — the expensive
    /// query is the one that matches nothing, where `limit` never bites and the walk would
    /// otherwise read every directory within `maxDepth` before it could answer.
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

        // …and the budget is a real ceiling, not a value the walk would have respected anyway:
        // unbudgeted, the same fruitless query reads the entire tree.
        listings = 0
        _ = DestinationBrowser.search("nothingmatchesthis", under: "/p", fileManager: fm)
        #expect(listings == 61, "/p plus its 12 children plus their 48 — every directory there is")
    }

    /// Cancellation is polled per directory, so a superseded keystroke's walk stops instead of
    /// running to completion behind the one the user is waiting on. `Task.detached` does not
    /// inherit cancellation, which is why this is an explicit hook rather than `Task.isCancelled`.
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

    /// A walk that exhausts the tree is COMPLETE — the flag must not simply always be true, or the
    /// picker would permanently caveat results it fully searched.
    @Test func testAnExhaustiveSearchIsNotTruncated() throws {
        let fm = try fixture()
        let outcome = DestinationBrowser.search("son", under: "/p", fileManager: fm)
        #expect(outcome.matches.count == 2)
        #expect(!outcome.stoppedEarly && !outcome.skippedUnreadableDirectory)
    }

    /// Each of the three caps stops the walk early, and each must say so — a partial list that
    /// reads as the complete one is how "the folder isn't there" becomes a wrong conclusion.
    @Test func testEveryCapReportsTruncation() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("son", under: "/p", limit: 1, fileManager: fm).stoppedEarly,
                "match limit")
        #expect(DestinationBrowser.search("son", under: "/p", maxDepth: 2, fileManager: fm).stoppedEarly,
                "depth ceiling — Kaiser/Son is below it")
        #expect(DestinationBrowser.search("son", under: "/p", maxListings: 1, fileManager: fm).stoppedEarly,
                "listing budget")
    }

    /// A blank query is not a truncated search — it is no search. Otherwise the picker would show
    /// its "showing the first N" caveat over the browse columns, which ran no walk at all.
    @Test func testABlankQueryIsNotTruncated() throws {
        let fm = try fixture()
        let blank = DestinationBrowser.search("", under: "/p", fileManager: fm)
        #expect(!blank.stoppedEarly && !blank.skippedUnreadableDirectory)
    }

    /// …and an uncancelled walk is unaffected, so the hook cannot silently disable search.
    @Test func testSearchIsUnaffectedWhenNotCancelled() throws {
        let fm = try fixture()
        let found = DestinationBrowser.search("son", under: "/p", fileManager: fm,
                                              isCancelled: { false })
        #expect(Set(found.matches.map(\.path)) == ["/p/Health/Medical/Kaiser/Son", "/p/School/Son"])
    }
}
