import Foundation
import Testing
@testable import Sync

/// The seam that keeps "could not be listed" apart from "listed, and it is empty".
///
/// Most of these run on the real filesystem on purpose: the seam exists for a real `FileManager`
/// behaviour (a non-nil enumerator that yields nothing for a directory it can't read), and a mock
/// is only evidence about the mock. The mock cases at the bottom prove the double matches the real
/// one, so suites that use it aren't passing vacuously.
@Suite struct DirectoryListingTests {

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Locks `url` (chmod 000) and returns the clean-up to defer: unlock it, then remove `base`.
    private func lock(_ url: URL, removing base: URL) throws -> () -> Void {
        try chmod(url, 0o000)
        return {
            try? self.chmod(url, 0o755)
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// chmod 000 is a no-op for root, so these fixtures prove nothing there and the test bows out.
    /// It records an issue rather than plainly returning: a bare `return` passes, and on a root
    /// runner most of this file would go green while proving nothing, with nothing said.
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

    /// The case this seam exists for. If this directory and the empty one above were the same
    /// value, a folder-replace confirmation could say "0 items will be removed" about a folder
    /// whose contents it is about to remove.
    @Test func anUnreadableDirectoryIsNotReportedAsEmpty() throws {
        guard !skippedBecauseRoot("anUnreadableDirectoryIsNotReportedAsEmpty") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListLocked")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        let cleanUp = try lock(locked, removing: base)
        defer { cleanUp() }

        // The plain enumerator idiom: its `guard let` else-branch never fires, and it hands back
        // nothing. Reading that as "empty" is reading a failure.
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
        let cleanUp = try lock(sub, removing: base)
        defer { cleanUp() }

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
        let cleanUp = try lock(sub, removing: base)
        defer { cleanUp() }

        let listing = FileManager.default.listing(of: root)

        #expect(listing.outcome == .listed)
        #expect(listing.urls.count == 2)
        #expect(listing.unreadableDescendants.isEmpty)
    }

    // MARK: The spelling of the root must not change the answer

    /// Why the root-failure decision uses the entry count, not the reported URL: `/var/…` comes
    /// back as `/private/var/…`, and `standardizedFileURL` doesn't close that gap. Each spelling
    /// below is the same directory and must give the same verdict. Both directions are asserted:
    /// `.unreadable` is also the failure fallback, so only the readable pass can catch a spelling
    /// that always fails.
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

    /// `FileManager.enumerator(at:)` doesn't traverse a symlinked directory: it yields nothing and
    /// fires the error handler with the link's own URL, exactly like an unreadable directory.
    /// Without a fallback the picker says "Can't be read" about a folder Finder lists fine.
    /// `FileSyncManager+Scanning`'s cold walk falls back to the path-based listing for the same
    /// reason.
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

        // The premise: the URL-based enumerator refuses, while the path-based listing hands back
        // all three names.
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

    /// The fallback must not launder a real failure. A symlink to a locked directory is still
    /// unreadable, and so are the two shapes that resolve to themselves, and one to a file. This is
    /// what checks the retry is one-way: `classify` runs on the retried walk, and only this fixture
    /// would catch it stopping. The readable control goes through the same call and must come back
    /// with entries, so a fallback that rescues nothing fails here too.
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

        let cleanUp = try lock(locked, removing: base)
        defer { cleanUp() }

        for (name, url) in [("to a locked directory", toLocked), ("broken", broken),
                            ("self-referential", selfie), ("to a regular file", toFile)] {
            let listing = FileManager.default.listing(of: url)
            #expect(listing.outcome == .unreadable,
                    "a symlink \(name) is not something the fallback may report as readable")
            // `urls` is empty: the retry may not smuggle a partial answer out behind
            // `.unreadable`.
            #expect(listing.urls.isEmpty, "a symlink \(name) handed back \(listing.urls.count) entries")
        }

        let control = FileManager.default.listing(of: toOpen)
        #expect(control.outcome == .listed,
                "the fallback has stopped rescuing readable links — the four above prove nothing")
        #expect(control.urls.count == 2)
    }

    /// `traversableTarget` is the seam all three retries go through, and its two refusals can't be
    /// seen from any of them: a self-referential or broken link ends in `.unreadable` either way.
    /// So the seam is asked directly, with a case that must come back non-nil so a
    /// `traversableTarget` that refuses everything fails. Dropping
    /// `resolved.path == url.path ? nil : resolved` must make this fail.
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

        // This one must offer a second URL, and a different one: that is the half the guard
        // decides.
        let offered = try #require(
            DirectoryListingSupport.traversableTarget(of: good, using: FileManager.default),
            "a link onto a real folder is exactly what the retry exists for")
        #expect(offered.path != good.path)
        #expect(DirectoryListingSupport.identity(of: offered) == DirectoryListingSupport.identity(of: real))

        // Both shapes that resolve to themselves: retrying either would only repeat the refusal.
        #expect(DirectoryListingSupport.traversableTarget(of: selfie, using: FileManager.default) == nil,
                "a self-referential link resolves to itself — there is nowhere else to look")
        #expect(DirectoryListingSupport.traversableTarget(of: broken, using: FileManager.default) == nil,
                "a broken link resolves to itself too")

        // Not a link at all: no retry, however readable it is.
        #expect(DirectoryListingSupport.traversableTarget(of: real, using: FileManager.default) == nil)
        // And never for an injected file manager, whose paths are not on this disk.
        #expect(DirectoryListingSupport.traversableTarget(of: good, using: MockFileManager()) == nil)
    }

    /// Entries keep the caller's spelling at every depth, not only when the last path component is
    /// the link. The retry fires only for that case; one level in, the direct walk succeeds and
    /// the enumerator would hand back the target's canonical path unless it is re-spelled too.
    /// Level 2 is the one that matters; a fixture with leaves only at depth 1 can't see it.
    @Test func entriesKeepTheCallersSpellingBelowASymlinkTooNotOnlyAtIt() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListSymlinkLevel2")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try makeDir(real.appendingPathComponent("Health/Medical"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Level 1: the retry path.
        let level1 = FileManager.default.listing(of: link)
        #expect(level1.urls.map(\.path) == [link.appendingPathComponent("Health").path])

        // Level 2: the direct walk, one level INSIDE the link.
        let level2 = FileManager.default.listing(of: link.appendingPathComponent("Health"))
        #expect(level2.outcome == .listed)
        #expect(level2.urls.map(\.path) == [link.appendingPathComponent("Health/Medical").path],
                "level 2 answered in the target's spelling: \(level2.urls.map(\.path))")

        // Control: asked by its real name, it answers in that name, so the assertions above check
        // the caller's spelling, not a blind prefix of the argument.
        let direct = FileManager.default.listing(of: real.appendingPathComponent("Health"))
        #expect(direct.urls.map(\.path) == [real.appendingPathComponent("Health/Medical").path])
    }

    /// The links among the entries, in the caller's spelling, when asked, and `nil` when not. A link
    /// to a folder lists with `hasDirectoryPath` false, so this is how a caller (Edit's folder menu)
    /// spots one without a `stat` per entry. Dangling links and links to files count: what a link
    /// leads to is the caller's question. Also through the retried walk, re-spelled under the link.
    @Test func theLinksAmongTheEntriesAreNamedWhenAsked() throws {
        let base = try makeCanonicalTempRoot(prefix: "DirListLinks")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let real = base.appendingPathComponent("real")
        try makeDir(real.appendingPathComponent("Folder"), files: 1)
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("ToFolder").path, withDestinationPath: "Folder")
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("ToFile").path, withDestinationPath: "Folder/f0.txt")
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("Gone").path, withDestinationPath: "nowhere")
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(fm.listing(of: real).symbolicLinkPaths == nil, "named links nobody asked about")
        for folder in [real, link] {
            let listing = fm.listing(of: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
            #expect(listing.outcome == .listed)
            #expect(listing.symbolicLinkPaths == Set(["ToFolder", "ToFile", "Gone"].map {
                folder.appendingPathComponent($0).path
            }), "under \(folder.lastPathComponent): \(listing.symbolicLinkPaths ?? [])")
        }
        // Only what the caller keeps.
        let kept = fm.listing(of: real, includingPropertiesForKeys: [.isSymbolicLinkKey],
                              keeping: { $0.lastPathComponent != "Gone" })
        #expect(kept.symbolicLinkPaths == Set(["ToFolder", "ToFile"].map { real.appendingPathComponent($0).path }))
        // Unreadable: no answer, rather than "no links".
        #expect(fm.listing(of: base.appendingPathComponent("missing"),
                           includingPropertiesForKeys: [.isSymbolicLinkKey]).symbolicLinkPaths == nil)
        // A mock disk has no links, and its paths are not this disk's to ask.
        let mock = MockFileManager()
        try mock.createDirectory(at: URL(fileURLWithPath: "/m"), withIntermediateDirectories: true)
        mock.virtualDisk["/m/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        #expect(mock.listing(of: URL(fileURLWithPath: "/m"), includingPropertiesForKeys: [.isSymbolicLinkKey])
            .symbolicLinkPaths == [])
    }

    /// The recursive shape too: the only one that can answer `.listedWithUnreadableDescendants`,
    /// and where re-spelling under the link is path arithmetic, not a `lastPathComponent`.
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

    /// The same symlink quirk on the counting API, whose one caller is the folder-replace warning:
    /// without the fallback it says "everything" about a folder it could have counted. Both
    /// directions: the rescue must never turn a real failure into a number, so a link onto a locked
    /// directory stays `.unreadable`, never "0 items". The readable half keeps a `childCount` that
    /// rescues nothing from passing.
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
        let cleanUp = try lock(locked, removing: base)
        defer { cleanUp() }

        let counted = FileManager.default.childCount(of: link, options: [], cap: 1000)

        #expect(counted.outcome == .listed)
        #expect(counted.count == 4, "the target's four files, counted through the link")
        #expect(!counted.isCapped)

        // The one-way half. A count of 0 here would be the "0 items will be removed" sentence, so
        // only `.unreadable` will do.
        let refused = FileManager.default.childCount(of: toLocked, options: [], cap: 1000)
        #expect(refused.outcome == .unreadable,
                "a link onto a locked folder is not a folder with \(refused.count) items in it")
        #expect(refused.count == 0)
    }

    /// A regular file answers `.unreadable`, the same as a locked directory: this API can't tell
    /// them apart. Pinned so a caller knows it must check for a directory itself; the safe
    /// direction holds only because of which callers exist, not because of the type.
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
    /// caller would refuse a folder that is fine. With `.skipsHiddenFiles` the enumerator neither
    /// yields nor reports it.
    @Test func aHiddenUnreadableChildDoesNotMakeItsParentUnreadable() throws {
        guard !skippedBecauseRoot("aHiddenUnreadableChildDoesNotMakeItsParentUnreadable") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListHidden")
        let parent = base.appendingPathComponent("parent")
        let hidden = parent.appendingPathComponent(".locked")
        try makeDir(hidden, files: 3)
        let cleanUp = try lock(hidden, removing: base)
        defer { cleanUp() }

        let listing = FileManager.default.listing(of: parent, options: [.skipsHiddenFiles])

        #expect(listing.outcome == .listed)
        #expect(listing.urls.isEmpty)
    }

    // MARK: Filtering inside the walk

    /// `keeping:` decides what the listing retains, never what it saw. `classify` reads a zero
    /// entry count plus a reported failure as "the root couldn't be read", so the drain counts
    /// entries separately from the ones it keeps. Passing `kept.count` to `classify` must make
    /// this fail with `.unreadable` for a root that was read fine.
    @Test func aFilterThatKeepsNothingIsNotAnUnreadableDirectory() throws {
        guard !skippedBecauseRoot("aFilterThatKeepsNothingIsNotAnUnreadableDirectory") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirListFilterAll")
        let root = base.appendingPathComponent("root")
        try makeDir(root, files: 2)
        let sub = root.appendingPathComponent("locked-sub")
        try makeDir(sub, files: 3)
        let cleanUp = try lock(sub, removing: base)
        defer { cleanUp() }

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

    /// `childCount` lets the folder-replace warning ask "how many?" of a huge folder without
    /// building an array, but it must reach the same verdict `listing` does, or the warning reads a
    /// failure as a zero.
    @Test func countingAnUnreadableDirectoryIsNotACountOfZero() throws {
        guard !skippedBecauseRoot("countingAnUnreadableDirectoryIsNotACountOfZero") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirCountLocked")
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        let cleanUp = try lock(locked, removing: base)
        defer { cleanUp() }

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

        // Same directory, cap above its size: the count is the whole truth, so a `childCount` that
        // always reports the cap fails.
        let uncapped = FileManager.default.childCount(of: full, options: [], cap: 100)
        #expect(uncapped.count == 9)
        #expect(!uncapped.isCapped)
    }

    /// A cap of zero still opens the directory: counting stops on the first entry, so the answer is
    /// "at least 1". Short-circuiting a non-positive cap to a `.listed` zero would be a verdict about
    /// a directory never opened; the locked half catches that, since it can't see the failure.
    @Test func aNonPositiveCapStillOpensTheDirectory() throws {
        guard !skippedBecauseRoot("aNonPositiveCapStillOpensTheDirectory") else { return }
        let base = try makeCanonicalTempRoot(prefix: "DirCountZeroCap")
        let full = base.appendingPathComponent("full")
        try makeDir(full, files: 3)
        let locked = base.appendingPathComponent("locked")
        try makeDir(locked, files: 3)
        let cleanUp = try lock(locked, removing: base)
        defer { cleanUp() }

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
        let cleanUp = try lock(locked, removing: base)
        defer { cleanUp() }

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
        try fm.createDirectory(at: URL(fileURLWithPath: "/empty"), withIntermediateDirectories: true)

        // Faithful means non-nil and empty, not nil: a mock returning nil would make the dead
        // `guard let … else` branch look tested.
        let raw = fm.enumerator(at: URL(fileURLWithPath: "/locked"), includingPropertiesForKeys: nil,
                                options: [], errorHandler: nil)
        #expect(raw != nil)
        #expect(raw?.allObjects.count == 0)

        #expect(fm.listing(of: URL(fileURLWithPath: "/locked")).outcome == .unreadable)
        // …and it keeps an empty directory apart from an unlistable one.
        #expect(fm.listing(of: URL(fileURLWithPath: "/empty")).outcome == .listed)
    }

    /// With nested unlistable directories the mock must name the outermost one, the one the real
    /// enumerator meets first. Taking the first match from a `Set` would depend on the per-launch
    /// hash seed, and looping wouldn't help: a Set's order is fixed within a process. `/root/a` has
    /// no stub of its own, only `/root/a/b` below it, so the mock must still list the blocked
    /// directory as an entry rather than call the whole root unreadable.
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
}
