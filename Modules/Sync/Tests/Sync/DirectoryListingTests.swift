import Foundation
import Testing
@testable import Sync

/// The seam that keeps "could not be listed" apart from "listed, and it is empty".
///
/// Most of these run against the REAL filesystem on purpose. The whole reason the seam exists is a
/// behaviour of the real `FileManager` — a non-nil enumerator that yields zero entries for a
/// directory it cannot read — and a mock is only evidence about the mock. The mock cases at the
/// bottom exist to prove the double is faithful to what the real one was measured doing, so that
/// tests written against it in other suites are not passing vacuously.
@Suite struct DirectoryListingTests {

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// chmod 000 is a no-op for root (it can read anything), so these fixtures prove nothing there
    /// and the test has to bow out.
    ///
    /// It records an issue on the way out rather than plainly returning. `return` reports the test
    /// as **PASSED**, so on a root runner every locked-directory fixture in this file — which is
    /// most of it — would go green while proving nothing at all, and nothing in the output would
    /// say so. Measured `geteuid() == 501` on this machine, so the fixtures do run here; the point
    /// is that the day they stop, the run says which ones and why.
    private func skippedBecauseRoot(_ fixture: String, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard geteuid() == 0 else { return false }
        Issue.record("""
            Skipped “\(fixture)”: running as root (euid 0), where chmod 000 does not restrict \
            access, so this fixture cannot distinguish an unreadable directory from a readable \
            one. It proves nothing on this runner — treat the suite as not having covered it.
            """, sourceLocation: sourceLocation)
        return true
    }

    private func makeDir(_ url: URL, files: Int = 0) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for i in 0..<files {
            try Data("x".utf8).write(to: url.appendingPathComponent("f\(i).txt"))
        }
    }

    // MARK: The distinction itself, on a real disk

    @Test func anEmptyDirectoryIsListedAndSaysSo() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListEmpty")
        defer { try? FileManager.default.removeItem(at: base) }
        let empty = base.appendingPathComponent("empty")
        try makeDir(empty)

        let listing = FileManager.default.listing(of: empty)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.isEmpty)
        #expect(listing.isComplete)
    }

    @Test func aPopulatedDirectoryComesBackComplete() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListFull")
        defer { try? FileManager.default.removeItem(at: base) }
        let full = base.appendingPathComponent("full")
        try makeDir(full, files: 3)

        let listing = FileManager.default.listing(of: full)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.count == 3)
    }

    /// The finding this seam was built for. Before it, this directory and the empty one above were
    /// the same value — which is how a folder-replace confirmation could say "0 items will be
    /// removed" about a folder whose contents it was about to remove.
    @Test func anUnreadableDirectoryIsNotReportedAsEmpty() throws {
        guard !skippedBecauseRoot("anUnreadableDirectoryIsNotReportedAsEmpty") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListLocked")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        // The idiom this replaces, measured in place: the guard's else-branch never fires, and the
        // enumerator hands back nothing. Anything reading that as "empty" is reading a failure.
        let rawEnumerator = FileManager.default.enumerator(at: locked, includingPropertiesForKeys: nil,
                                                           options: [], errorHandler: nil)
        #expect(rawEnumerator != nil, "the else-branch of `guard let enumerator` is dead on a real disk")
        #expect(rawEnumerator?.allObjects.count == 0)

        let listing = FileManager.default.listing(of: locked)

        #expect(listing.outcome == .unreadable)
        #expect(!listing.isComplete)
        #expect(listing.urls.isEmpty, "urls is empty here, but it is not evidence of emptiness")
    }

    @Test func aDirectoryThatDoesNotExistIsUnreadableRatherThanEmpty() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListGone")
        defer { try? FileManager.default.removeItem(at: base) }

        let listing = FileManager.default.listing(of: base.appendingPathComponent("never-created"))

        #expect(listing.outcome == .unreadable)
    }

    // MARK: Partial answers

    @Test func aReadableRootWithALockedSubtreeIsPartialNotComplete() throws {
        guard !skippedBecauseRoot("aReadableRootWithALockedSubtreeIsPartialNotComplete") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListPartial")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 1)
        let sub = root.appendingPathComponent("locked-sub")
        try makeDir(sub, files: 4)
        try chmod(sub, 0o000)
        defer {
            try? chmod(sub, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let listing = FileManager.default.listing(of: root, options: [])

        #expect(listing.outcome == .listedWithUnreadableDescendants)
        #expect(!listing.isComplete)
        #expect(listing.urls.count == 2, "the locked subdirectory is still yielded as an entry")
        #expect(listing.unreadableDescendants.count == 1)
        #expect(listing.unreadableDescendants.first?.lastPathComponent == "locked-sub")
    }

    /// A shallow listing never descends, so the same fixture is a complete answer to a narrower
    /// question. This pins the default `options:` as part of the contract rather than a detail.
    @Test func aShallowListingOfThatSameTreeIsComplete() throws {
        guard !skippedBecauseRoot("aShallowListingOfThatSameTreeIsComplete") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListShallow")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 1)
        let sub = root.appendingPathComponent("locked-sub")
        try makeDir(sub, files: 4)
        try chmod(sub, 0o000)
        defer {
            try? chmod(sub, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let listing = FileManager.default.listing(of: root)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.count == 2)
        #expect(listing.unreadableDescendants.isEmpty)
    }

    // MARK: The spelling of the root must not change the answer

    /// The reason the root-failure decision is made on the entry count and not by comparing the
    /// reported URL to the asked-for one: measured, `/var/…` asked comes back reported as
    /// `/private/var/…`, and `standardizedFileURL` does not close that gap. Each spelling below is
    /// the same directory and must give the same verdict.
    ///
    /// Asserted in BOTH directions over the same four spellings, because one direction alone is
    /// not a test. The symlink spelling used to answer `.unreadable` whether or not its target was
    /// locked — the expected value was the failure fallback, so `chmod 000 → 0o755` could not fail
    /// it, and the assertion pinned a bug as correct behaviour. The readable pass is what gives
    /// every spelling something it can get wrong.
    @Test func everySpellingOfARootTracksWhetherTheRootIsActuallyLocked() throws {
        guard !skippedBecauseRoot("every-spelling") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListSpelling")
        let target = base.appendingPathComponent("target")
        try makeDir(target, files: 2)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? chmod(target, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let spellings: [(String, URL)] = [
            ("plain", target),
            ("trailing slash", URL(fileURLWithPath: target.path + "/")),
            ("dot segment", base.appendingPathComponent("./target")),
            ("via symlink", link),
        ]

        // Readable. Every spelling names a directory holding two files, and must say so.
        for (name, url) in spellings {
            let listing = FileManager.default.listing(of: url)
            #expect(listing.outcome == .listed,
                    "\(name) spelling of a READABLE directory read as \(listing.outcome)")
            #expect(listing.urls.count == 2,
                    "\(name) spelling saw \(listing.urls.count) of 2 entries")
        }

        // Same four spellings, same directory, now locked.
        try chmod(target, 0o000)
        for (name, url) in spellings {
            #expect(FileManager.default.listing(of: url).outcome == .unreadable,
                    "\(name) spelling of a locked directory read as something other than unreadable")
        }
    }

    // MARK: A symlinked directory is a directory

    /// `FileManager.enumerator(at:)` does not traverse a SYMLINKED directory: measured, it yields
    /// zero entries and fires the error handler with the link's own URL — byte for byte the
    /// signature of a directory that cannot be read. Without a fallback the picker says "Can't be
    /// read" about a folder Finder lists fine, which is the same class of unearned claim this
    /// whole type exists to stop, pointing the other way.
    ///
    /// The repo already knew the quirk: `FileSyncManager+Scanning`'s cold walk falls back to the
    /// path-based listing for exactly this reason.
    @Test func aReadableDirectoryReachedThroughASymlinkIsListedNotUnreadable() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListSymlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        try makeDir(target)
        for name in ["Medical", "Dental"] {
            try makeDir(target.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: target.appendingPathComponent("note.txt"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // The premise, measured rather than assumed: the raw URL-based enumerator refuses, while
        // the path-based listing hands back all three names.
        var refused = 0
        let raw = FileManager.default.enumerator(at: link, includingPropertiesForKeys: nil,
                                                 options: [.skipsSubdirectoryDescendants],
                                                 errorHandler: { _, _ in refused += 1; return true })
        #expect(raw?.allObjects.count == 0, "the URL-based enumerator yields nothing through a symlink")
        #expect(refused == 1, "…and reports the link through the error handler")
        #expect(try FileManager.default.contentsOfDirectory(atPath: link.path).count == 3,
                "the directory itself is perfectly readable")

        let listing = FileManager.default.listing(of: link)

        #expect(listing.outcome == .listed, "a symlinked directory that reads fine is not a failure")
        #expect(listing.isComplete)
        #expect(Set(listing.urls.map(\.lastPathComponent)) == ["Medical", "Dental", "note.txt"])
        // Spelled back under the path the caller asked about, not the target's. The picker's
        // breadcrumbs, its `trail`, and its recents are all keyed on the path it browsed through.
        for url in listing.urls {
            #expect(url.deletingLastPathComponent().path == link.path,
                    "entry re-spelled as \(url.path), which is not under \(link.path)")
        }
    }

    /// The fallback must not launder a real failure. A symlink to a LOCKED directory is still
    /// unreadable, and so are the two shapes that resolve to themselves, and so is one to a file.
    ///
    /// **This is also the whole of what keeps the retry one-way.** A ternary preferring the direct
    /// walk's answer used to sit at the end of `listing`, described in three commit bodies as
    /// enforcing it; it enforced nothing, because a `.unreadable` listing is `([], .unreadable, [])`
    /// whichever walk produced it, so both branches of it were the same value and replacing it with
    /// `return retried` passed all 75 tests here. What actually holds the line is `classify` running
    /// on the retried walk, and what checks THAT is this fixture — so it has to be able to fail.
    ///
    /// It could not before. All four cases expected `.unreadable`, which is also the answer for a
    /// fallback that has stopped rescuing anything, and two of them (broken, self-referential) never
    /// reach the retry at all. The readable control below is what gives the four something they can
    /// get wrong: it goes through the same call, on the same disk, and must come back with entries.
    @Test func aSymlinkThatLeadsNowhereReadableIsStillUnreadable() throws {
        guard !skippedBecauseRoot("symlink-failures") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListSymlinkBad")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        let toLocked = base.appendingPathComponent("to-locked")
        try FileManager.default.createSymbolicLink(at: toLocked, withDestinationURL: locked)

        let broken = base.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: base.appendingPathComponent("no-such-thing"))

        let selfie = base.appendingPathComponent("selfie")
        try FileManager.default.createSymbolicLink(at: selfie, withDestinationURL: selfie)

        let file = base.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: file)
        let toFile = base.appendingPathComponent("to-file")
        try FileManager.default.createSymbolicLink(at: toFile, withDestinationURL: file)

        // The control: a link of exactly the same shape, onto a directory nothing is wrong with.
        let open = base.appendingPathComponent("open")
        try makeDir(open, files: 2)
        let toOpen = base.appendingPathComponent("to-open")
        try FileManager.default.createSymbolicLink(at: toOpen, withDestinationURL: open)

        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        for (name, url) in [("to a locked directory", toLocked), ("broken", broken),
                            ("self-referential", selfie), ("to a regular file", toFile)] {
            let listing = FileManager.default.listing(of: url)
            #expect(listing.outcome == .unreadable,
                    "a symlink \(name) is not something the fallback may report as readable")
            // `urls` is not just meaningless here, it is empty — the retry may not smuggle a
            // partial answer out behind an `.unreadable` verdict.
            #expect(listing.urls.isEmpty, "a symlink \(name) handed back \(listing.urls.count) entries")
        }

        let control = FileManager.default.listing(of: toOpen)
        #expect(control.outcome == .listed,
                "the fallback has stopped rescuing readable links — the four above prove nothing")
        #expect(control.urls.count == 2)
    }

    /// `traversableTarget` is the single seam all three retries reach through, and the two refusals
    /// inside it are invisible from every one of them: a self-referential link and a broken one end
    /// in `.unreadable` whether the guard drops them here or the retried walk refuses them again a
    /// step later. Dropping `resolved.path == url.path ? nil : resolved` therefore passed the whole
    /// suite, leaving a documented rule as an untested optimisation.
    ///
    /// Asked of the seam directly, where the two answers do differ, and paired with the case that
    /// must come back non-nil so it cannot pass for a `traversableTarget` that refuses everything.
    @Test func traversableTargetOffersARetryOnlyWhenThereIsSomewhereElseToLook() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListRetrySeam")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try makeDir(real)
        let good = base.appendingPathComponent("good")
        try FileManager.default.createSymbolicLink(at: good, withDestinationURL: real)
        let selfie = base.appendingPathComponent("selfie")
        try FileManager.default.createSymbolicLink(at: selfie, withDestinationURL: selfie)
        let broken = base.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: base.appendingPathComponent("no-such-thing"))

        // The one that must offer a second URL — and it must be a DIFFERENT one, which is the half
        // the guard decides.
        let offered = try #require(
            DirectoryListingSupport.traversableTarget(of: good, using: FileManager.default),
            "a link onto a real folder is exactly what the retry exists for")
        #expect(offered.path != good.path)
        #expect(DirectoryListingSupport.identity(of: offered) == DirectoryListingSupport.identity(of: real))

        // Both shapes that resolve to themselves. Retrying either repeats the same refusal, so the
        // guard is what keeps a second enumerator from being built to be told the same thing.
        #expect(DirectoryListingSupport.traversableTarget(of: selfie, using: FileManager.default) == nil,
                "a self-referential link resolves to itself — there is nowhere else to look")
        #expect(DirectoryListingSupport.traversableTarget(of: broken, using: FileManager.default) == nil,
                "a broken link resolves to itself too")

        // Not a link at all: no retry, however readable it is.
        #expect(DirectoryListingSupport.traversableTarget(of: real, using: FileManager.default) == nil)
        // And never for an injected file manager, whose paths are not on this disk.
        #expect(DirectoryListingSupport.traversableTarget(of: good, using: MockFileManager()) == nil)
    }

    /// The other half of the re-spelling promise: it holds at every DEPTH, not only when the final
    /// path component is the link.
    ///
    /// Re-spelling used to happen on the retry alone, and the retry fires only when the last
    /// component is a symlink — so one level in, the direct walk succeeded and the enumerator's
    /// canonicalised TARGET path went back to the caller unchanged. Measured before the fix:
    ///
    ///     listing(of: <base>/link)        → <base>/link/Health          ✓
    ///     listing(of: <base>/link/Health) → <base>/real/Health/Medical  ✗
    ///
    /// Both levels are asserted here because level 1 is what already worked; a fixture whose leaves
    /// all sit at depth 1 cannot see this.
    @Test func entriesKeepTheCallersSpellingBelowASymlinkTooNotOnlyAtIt() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListSymlinkLevel2")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try makeDir(real.appendingPathComponent("Health/Medical"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Level 1: the retry path, which already re-spelled.
        let level1 = FileManager.default.listing(of: link)
        #expect(level1.urls.map(\.path) == [link.appendingPathComponent("Health").path])

        // Level 2: the direct walk, one level INSIDE the link.
        let level2 = FileManager.default.listing(of: link.appendingPathComponent("Health"))
        #expect(level2.outcome == .listed)
        #expect(level2.urls.map(\.path) == [link.appendingPathComponent("Health/Medical").path],
                "level 2 answered in the target's spelling: \(level2.urls.map(\.path))")

        // Control: asked by its real name, it answers in that name — so the assertions above are
        // about carrying the CALLER's spelling, not about prefixing everything with the argument.
        let direct = FileManager.default.listing(of: real.appendingPathComponent("Health"))
        #expect(direct.urls.map(\.path) == [real.appendingPathComponent("Health/Medical").path])
    }

    /// The recursive shape too, since that is the only one that can answer
    /// `.listedWithUnreadableDescendants` — and the one where re-spelling entries under the link
    /// is arithmetic rather than a `lastPathComponent`.
    @Test func aRecursiveListingThroughASymlinkKeepsTheCallersSpelling() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListSymlinkDeep")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        try makeDir(target.appendingPathComponent("Medical/Kaiser"))
        try Data("x".utf8).write(to: target.appendingPathComponent("Medical/Kaiser/card.pdf"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let listing = FileManager.default.listing(of: link, options: [])

        #expect(listing.outcome == .listed)
        let relatives = listing.urls
            .map { $0.path.replacingOccurrences(of: link.path + "/", with: "") }
            .sorted()
        #expect(relatives == ["Medical", "Medical/Kaiser", "Medical/Kaiser/card.pdf"],
                "recursive entries must be re-spelled under the link, got \(listing.urls.map(\.path))")
    }

    /// The same quirk on the counting API, whose one caller is the folder-replace warning. A
    /// symlinked destination folder answered `.unreadable`, so the sentence fell back to
    /// "everything" for a folder it could perfectly well have counted.
    ///
    /// Both directions over the same fixture, because the retry here has to be one-way and nothing
    /// else asks it to be: `childCount`'s rescue must never turn a real failure into a number.
    /// A link onto a LOCKED directory is a folder the warning genuinely cannot count, and reporting
    /// "0 items" for it is the original defect this whole seam exists to stop, arriving by the new
    /// route. The readable half is what keeps the locked half from being satisfied by a `childCount`
    /// that had simply stopped rescuing anything.
    @Test func countingThroughASymlinkReachesTheRealNumber() throws {
        guard !skippedBecauseRoot("count-through-symlink") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirCountSymlink")
        let target = base.appendingPathComponent("target")
        try makeDir(target, files: 4)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        let toLocked = base.appendingPathComponent("to-locked")
        try FileManager.default.createSymbolicLink(at: toLocked, withDestinationURL: locked)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let counted = FileManager.default.childCount(of: link, options: [], cap: 1000)

        #expect(counted.outcome == .listed)
        #expect(counted.count == 4, "the target's four files, counted through the link")
        #expect(!counted.isCapped)

        // The one-way half. A count of 0 here is exactly the "0 items will be removed" sentence
        // this seam was built to stop, so `.unreadable` and nothing else will do.
        let refused = FileManager.default.childCount(of: toLocked, options: [], cap: 1000)
        #expect(refused.outcome == .unreadable,
                "a link onto a locked folder is not a folder with \(refused.count) items in it")
        #expect(refused.count == 0)
    }

    /// A regular file is not a directory, and this API cannot say so — it answers `.unreadable`,
    /// the same value a locked directory gets. Pinned because it is a conflation a caller could
    /// otherwise discover the hard way, and because the safe direction today is an accident of
    /// which callers exist rather than a property of the type.
    @Test func aRegularFileHandedToTheListingApiReadsAsUnreadable() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListNotADir")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: file)

        #expect(FileManager.default.listing(of: file).outcome == .unreadable)

        // The distinction this type does not carry, and where a caller has to get it instead.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
    }

    /// A hidden unreadable child must not drag its readable parent down to `.unreadable`, or a
    /// caller would refuse to act on a folder that is perfectly fine. Measured: with
    /// `.skipsHiddenFiles` the enumerator neither yields nor reports it.
    @Test func aHiddenUnreadableChildDoesNotMakeItsParentUnreadable() throws {
        guard !skippedBecauseRoot("aHiddenUnreadableChildDoesNotMakeItsParentUnreadable") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListHidden")
        let parent = base.appendingPathComponent("parent")
        let hidden = parent.appendingPathComponent(".locked")
        try makeDir(hidden, files: 3)
        try chmod(hidden, 0o000)
        defer {
            try? chmod(hidden, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let listing = FileManager.default.listing(of: parent, options: [.skipsHiddenFiles])

        #expect(listing.outcome == .listed)
        #expect(listing.urls.isEmpty)
    }

    // MARK: Filtering inside the walk

    /// `keeping:` decides what the listing RETAINS, never what it saw. The distinction is the
    /// whole reason the drain counts entries separately from the ones it keeps: a zero ENTRY count
    /// alongside a reported failure is precisely how `classify` recognises that the root itself
    /// could not be read, and a filter that happens to reject everything is a completely different
    /// statement about a directory that opened fine.
    ///
    /// Collapsed into one number — `classify(entryCount: kept.count, …)` — this fixture answers
    /// `.unreadable` for a root that was read perfectly well, which is the same false failure the
    /// symlink case produced.
    @Test func aFilterThatKeepsNothingIsNotAnUnreadableDirectory() throws {
        guard !skippedBecauseRoot("aFilterThatKeepsNothingIsNotAnUnreadableDirectory") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListFilterAll")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 2)
        let sub = root.appendingPathComponent("locked-sub")
        try makeDir(sub, files: 3)
        try chmod(sub, 0o000)
        defer {
            try? chmod(sub, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let listing = FileManager.default.listing(of: root, options: [], keeping: { _ in false })

        #expect(listing.urls.isEmpty, "the filter rejected everything, so nothing is retained")
        #expect(listing.outcome == .listedWithUnreadableDescendants,
                "the ROOT was read — a filter's verdict is not the filesystem's")
        #expect(listing.unreadableDescendants.count == 1)
    }

    /// …and the ordinary direction: the filter really does narrow what comes back, while the
    /// outcome for the same directory is identical either way.
    @Test func aFilterNarrowsTheEntriesWithoutChangingTheVerdict() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListFilterSome")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 4)
        try makeDir(root.appendingPathComponent("folder"))

        let everything = FileManager.default.listing(of: root)
        let foldersOnly = FileManager.default.listing(of: root, keeping: { $0.pathExtension.isEmpty })

        #expect(everything.urls.count == 5)
        #expect(foldersOnly.urls.map(\.lastPathComponent) == ["folder"])
        #expect(foldersOnly.outcome == everything.outcome)
        #expect(foldersOnly.outcome == .listed)
    }

    // MARK: Counting without collecting

    /// `childCount` exists so the folder-replace warning can ask "how many?" of a folder that may
    /// hold a hundred thousand entries without building an array of them — but it has to reach the
    /// same verdict `listing` does, or the warning would be back to reading a failure as a zero.
    @Test func countingAnUnreadableDirectoryIsNotACountOfZero() throws {
        guard !skippedBecauseRoot("countingAnUnreadableDirectoryIsNotACountOfZero") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirCountLocked")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let counted = FileManager.default.childCount(of: locked, options: [], cap: 1000)

        #expect(counted.outcome == .unreadable)
        #expect(counted.count == 0)
        #expect(!counted.isCapped, "zero-from-a-failure is not a floor of anything — nothing was counted")
    }

    @Test func countingAnEmptyDirectoryIsAnAuthoritativeZero() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirCountEmpty")
        defer { try? FileManager.default.removeItem(at: base) }
        let empty = base.appendingPathComponent("empty")
        try makeDir(empty)

        let counted = FileManager.default.childCount(of: empty, options: [], cap: 1000)

        #expect(counted.count == 0)
        #expect(counted.outcome == .listed)
        #expect(!counted.isCapped, "nothing cut this walk short, and nothing was withheld from it")
    }

    @Test func countingStopsAtTheCapAndSaysSo() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirCountCap")
        defer { try? FileManager.default.removeItem(at: base) }
        let full = base.appendingPathComponent("full")
        try makeDir(full, files: 9)

        let counted = FileManager.default.childCount(of: full, options: [], cap: 4)

        #expect(counted.count == 4, "the cap is where counting stops, not a number it reports past")
        #expect(counted.isCapped, "4 is a floor under an actual 9")
        #expect(counted.outcome == .listed, "capping is our choice, not a failure of the directory")

        // Same directory, cap above its size: the count is then the whole truth. Stated so the
        // assertions above cannot be satisfied by a `childCount` that always reports the cap.
        let uncapped = FileManager.default.childCount(of: full, options: [], cap: 100)
        #expect(uncapped.count == 9)
        #expect(!uncapped.isCapped)
    }

    /// A cap of zero opens the directory like any other cap, and this states what falls out of
    /// that: counting stops on the first entry, so the answer is "at least 1".
    ///
    /// It exists because the first version of `childCount` short-circuited a non-positive cap to
    /// an authoritative `.listed` zero — a verdict about a directory it had not opened, and
    /// therefore the very thing this file exists to stamp out. The locked half is the half that
    /// matters: a short-circuit cannot see a failure it never went looking for.
    @Test func aNonPositiveCapStillOpensTheDirectory() throws {
        guard !skippedBecauseRoot("aNonPositiveCapStillOpensTheDirectory") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirCountZeroCap")
        let full = base.appendingPathComponent("full")
        try makeDir(full, files: 3)
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let counted = FileManager.default.childCount(of: full, options: [], cap: 0)
        #expect(counted.count == 1)
        #expect(counted.isCapped, "“at least 1”, not “1”")

        #expect(FileManager.default.childCount(of: locked, options: [], cap: 0).outcome == .unreadable,
                "a cap of zero must not turn an unreadable directory into a readable one")
    }

    @Test func countingAPartlyReadableTreeIsAFloorNotATotal() throws {
        guard !skippedBecauseRoot("countingAPartlyReadableTreeIsAFloorNotATotal") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirCountPartial")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 2)
        let locked = root.appendingPathComponent("locked-sub")
        try makeDir(locked, files: 4)
        try chmod(locked, 0o000)
        defer {
            try? chmod(locked, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        let counted = FileManager.default.childCount(of: root, options: [], cap: 1000)

        // Two files plus the locked subdirectory itself; its four children are withheld.
        #expect(counted.count == 3)
        #expect(counted.outcome == .listedWithUnreadableDescendants, "3 is what could be seen of an actual 7")
        #expect(!counted.isCapped, "the walk finished — it was the disk that withheld the rest")
    }

    // MARK: The double is faithful to the real thing

    @Test func theMockModelsAnUnlistableDirectoryTheWayTheRealOneBehaves() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/locked"), withIntermediateDirectories: true)
        fm.virtualDisk["/locked/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.unlistableDirectories = ["/locked"]

        // Faithful means non-nil-and-empty, not nil: a mock returning nil would make the dead
        // `guard let … else` branch look tested while it stays dead in production.
        let raw = fm.enumerator(at: URL(fileURLWithPath: "/locked"), includingPropertiesForKeys: nil,
                                options: [], errorHandler: nil)
        #expect(raw != nil)
        #expect(raw?.allObjects.count == 0)

        #expect(fm.listing(of: URL(fileURLWithPath: "/locked")).outcome == .unreadable)
    }

    @Test func theMockSeparatesAnEmptyDirectoryFromAnUnlistableOne() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/locked"), withIntermediateDirectories: true)
        fm.unlistableDirectories = ["/locked"]

        #expect(fm.listing(of: URL(fileURLWithPath: "/empty")).outcome == .listed)
        #expect(fm.listing(of: URL(fileURLWithPath: "/locked")).outcome == .unreadable)
    }

    /// With nested unlistable directories the mock must name the OUTERMOST one, which is the one
    /// the real enumerator meets first on its way down. Picking the first match out of a `Set`
    /// instead made the answer depend on an iteration order Swift's per-launch hash seed decides.
    ///
    /// This asserts the rule, not the repetition: a Set's order is fixed within a process, so
    /// looping here would re-run the same draw rather than sample new ones. What makes the code
    /// deterministic is that the choice no longer consults that order at all.
    ///
    /// The fixture deliberately does not create `/root/a` as a stub — only `/root/a/b` below it —
    /// because that is the shape that exposed the mock withholding the blocked directory from its
    /// own listing, which turned a partial answer into a wholly unreadable one.
    @Test func theMockNamesTheOutermostUnlistableAncestor() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/root"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/root/a/b"), withIntermediateDirectories: true)
        fm.virtualDisk["/root/a/b/deep.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.unlistableDirectories = ["/root/a", "/root/a/b"]

        let listing = fm.listing(of: URL(fileURLWithPath: "/root"), options: [])

        #expect(listing.outcome == .listedWithUnreadableDescendants,
                "the root itself is readable — this is a partial answer, not an unreadable one")
        #expect(listing.unreadableDescendants.map(\.path) == ["/root/a"])
        #expect(listing.urls.map(\.path) == ["/root/a"],
                "the blocked directory is still an entry; nothing beneath it is")
    }

    @Test func theMockReportsAnUnlistableDescendantAsAPartialAnswer() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/root"), withIntermediateDirectories: true)
        fm.virtualDisk["/root/visible.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        try fm.createDirectory(at: URL(fileURLWithPath: "/root/sub"), withIntermediateDirectories: true)
        fm.virtualDisk["/root/sub/hidden.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.unlistableDirectories = ["/root/sub"]

        let listing = fm.listing(of: URL(fileURLWithPath: "/root"), options: [])

        #expect(listing.outcome == .listedWithUnreadableDescendants)
        #expect(listing.unreadableDescendants.map(\.path) == ["/root/sub"])
        #expect(!listing.urls.contains { $0.path == "/root/sub/hidden.txt" },
                "contents of an unlistable directory must not leak into the listing")
    }
}
