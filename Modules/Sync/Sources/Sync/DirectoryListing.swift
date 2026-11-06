//
//  DirectoryListing.swift
//  SyncCloud
//

import Foundation

/// How completely a directory could be read. Callers switch over this exhaustively, never with
/// `default:`, so a new case fails to compile rather than being silently absorbed.
public enum DirectoryListingOutcome: Equatable, Sendable {
    /// The directory was read and `urls` is its complete contents. It may legitimately be empty.
    case listed
    /// The directory was read, but at least one descendant could not be descended into, so `urls`
    /// is a real but PARTIAL answer. Only reachable on a recursive listing.
    case listedWithUnreadableDescendants
    /// The directory itself could not be listed — permission denied, deleted, volume gone.
    /// `urls` is empty and means nothing; it is not evidence that the directory is empty.
    case unreadable
}

/// The result of listing one directory, keeping "could not be listed" apart from "listed, and
/// empty".
///
/// **`FileManager.enumerator(at:)` is not nil for a directory it can't read**: a locked, missing
/// or empty directory all give a non-nil enumerator with no entries. An unreadable folder read as
/// empty can make a folder-replace confirmation say "0 items will be removed" before removing them
/// all. The `errorHandler:` tells them apart: it fires with the root's URL when the root can't be
/// listed, with a descendant's URL when a subdirectory can't be entered (that subdirectory is still
/// yielded), and never for an empty directory.
///
/// For listing one directory eagerly. It drains the enumerator into an array, so it doesn't
/// replace `FileDiffEngine`'s streaming walk of a whole tree.
public struct DirectoryListing: Sendable {
    /// The entries read. Empty and meaningless when `outcome == .unreadable`; empty and
    /// authoritative when `outcome == .listed`.
    public let urls: [URL]

    /// How much of the directory the listing actually covers.
    public let outcome: DirectoryListingOutcome

    /// Descendants that could not be descended into, when `outcome` is
    /// `.listedWithUnreadableDescendants`. Empty otherwise.
    public let unreadableDescendants: [URL]

    /// True only when `urls` is the complete contents. For a call site with one answer for both
    /// failure shapes; one that must tell them apart switches on `outcome`.
    public var isComplete: Bool { outcome == .listed }

    /// True when the folder's contents aren't on this Mac and the app that syncs it didn't answer in
    /// time (`FileSyncManager.DatalessFolderReads`). `outcome` is then `.unreadable`; this lets a
    /// caller say why, rather than send someone to check permissions over a cloud app not running.
    public let isUnanswered: Bool

    /// The paths among `urls` that are symbolic links, or `nil` when not asked (ask by listing with
    /// `.isSymbolicLinkKey` among the keys). A link to a folder lists with `hasDirectoryPath` false,
    /// so a caller listing a pane's folders needs this. Read from the enumerator's prefetched URL,
    /// so it costs no `lstat` per entry, which the re-spelled `urls` would. Empty, not `nil`, for an
    /// injected `FileManaging`: a mock holds no links, and asking its URLs would ask the real disk.
    public let symbolicLinkPaths: Set<String>?

    public init(urls: [URL], outcome: DirectoryListingOutcome, unreadableDescendants: [URL] = [],
                isUnanswered: Bool = false, symbolicLinkPaths: Set<String>? = nil) {
        self.urls = urls
        self.outcome = outcome
        self.unreadableDescendants = unreadableDescendants
        self.isUnanswered = isUnanswered
        self.symbolicLinkPaths = symbolicLinkPaths
    }

    /// A folder whose provider did not answer: unknown, never empty.
    static let unanswered = DirectoryListing(urls: [], outcome: .unreadable, isUnanswered: true)
}

public extension FileManaging {

    /// Lists what is under `url`, reporting whether the listing can be trusted.
    ///
    /// Shallow by default, so `urls` is the immediate children. Pass `options: []` for a recursive
    /// listing of every descendant, the only way to get `.listedWithUnreadableDescendants`.
    ///
    /// - Parameter isWanted: which entries `urls` keeps. Every entry is still visited and the
    ///   outcome is unchanged, but a caller wanting the subfolders of a folder full of loose files
    ///   pays only for the folders. Defaults to keeping everything.
    ///
    /// - Important: `url` must be a directory. A regular file answers `.unreadable`, the same as a
    ///   locked directory; a caller that must tell them apart asks `fileExists(atPath:isDirectory:)`
    ///   first.
    ///
    /// - Important: the enumerator also can't traverse a symlinked directory, which is handled by a
    ///   retry; see ``DirectoryListingSupport/traversableTarget(of:using:)``.
    ///
    /// - Important: `urls` is always spelled under the path the caller asked about, at every depth
    ///   and on the retry too, because a picker's breadcrumbs, highlight and recents are keyed on
    ///   the path it browsed through. `unreadableDescendants` is not re-spelled: the error handler
    ///   reports absolute paths in the OS's spelling.
    ///
    /// - Note: a nil enumerator is treated as `.unreadable`, though neither the real filesystem nor
    ///   `MockFileManager` produces one; the error handler is what detects failures.
    func listing(
        of url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants],
        keeping isWanted: (URL) -> Bool = { _ in true }
    ) -> DirectoryListing {
        listing(of: url, includingPropertiesForKeys: keys, options: options, keeping: isWanted,
                askingThrough: datalessFolderReads)
    }

    /// ``listing(of:includingPropertiesForKeys:options:keeping:)`` with the reads for a dataless
    /// folder passed explicitly. `nil` only for the body of a read itself
    /// (``listingForARead(of:)``), which would otherwise join its own read and wait out the deadline.
    internal func listing(
        of url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        keeping isWanted: (URL) -> Bool,
        askingThrough reads: FileSyncManager.DatalessFolderReads?
    ) -> DirectoryListing {
        // A folder whose contents aren't on this Mac is asked for through the reads, off the pool
        // and bounded. An answer materializes it, so the walk below reads it from disk; no answer
        // is `.unanswered`. The caller blocks at most the deadline, only the first time. A folder
        // that isn't dataless costs one `stat`.
        if let reads, isDataless(at: url),
           reads.readBlocking(url.path, { [self] in listingForARead(of: url).outcome }) == nil {
            return .unanswered
        }
        // `.producesRelativePathURLs`, not prefix arithmetic: the enumerator yields `/private/var/…`
        // where `resolvingSymlinksInPath` gives `/var/…`, so a prefix test matches nothing. Used on
        // both walks, so `urls` keeps the caller's spelling at every depth.
        let walked = options.union(.producesRelativePathURLs)
        let direct = drainListing(of: url, keys: keys, options: walked,
                                  respellingUnder: url, keeping: isWanted, askingThrough: reads)
        guard direct.outcome == .unreadable,
              let target = DirectoryListingSupport.traversableTarget(of: url, using: self)
        else { return direct }

        // A link to a locked directory, a broken link and a link to a file all stay unreadable,
        // because `classify` says so on the retried walk. Pinned by
        // `aSymlinkThatLeadsNowhereReadableIsStillUnreadable`.
        return drainListing(of: target, keys: keys, options: walked,
                            respellingUnder: url, keeping: isWanted, askingThrough: reads)
    }

    /// For a caller that can suspend: asks the provider for a dataless folder's contents through the
    /// reads `listing` uses, holding no thread. True when the folder can now be listed without
    /// asking; false when it didn't answer or the task was cancelled. Call it before a synchronous
    /// listing and that listing never waits, since the registry remembers an unanswered folder.
    func waitForContents(of url: URL) async -> Bool {
        guard isDataless(at: url) else { return true }
        return await datalessFolderReads.read(url.path, { [self] in listingForARead(of: url).outcome }) != nil
    }

    /// ``waitForContents(of:)`` for a caller that can't suspend and lists with its own API:
    /// Restructure's plan view (`contentsOfDirectory`) and the landing's "is it still empty?" walk.
    /// Without it a cloud-only folder whose app has stopped would hang the plan sheet on the main
    /// actor or wedge a landing on the file queue. Blocks as `listing(of:)` does. A caller must
    /// read false as unreadable, never as empty. A folder that isn't dataless costs one `stat`.
    func waitForContentsBlocking(of url: URL) -> Bool {
        guard isDataless(at: url) else { return true }
        return datalessFolderReads.readBlocking(url.path, { [self] in listingForARead(of: url).outcome }) != nil
    }

    /// The listing a `DatalessFolderReads` read runs: shallow, and never asking through the reads,
    /// since it is the read.
    internal func listingForARead(of url: URL) -> DirectoryListing {
        listing(of: url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],
                keeping: { _ in true }, askingThrough: nil)
    }

    /// One pass of the enumerator, with no fallback of its own.
    ///
    /// - Parameter base: each entry is re-spelled as `base` + its relative path before the filter
    ///   sees it, so the direct and retried walks ask the same question. On the direct walk `base`
    ///   is the URL being enumerated, so the caller's spelling is never canonicalised away.
    fileprivate func drainListing(
        of url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        respellingUnder base: URL,
        keeping isWanted: (URL) -> Bool,
        askingThrough reads: FileSyncManager.DatalessFolderReads?
    ) -> DirectoryListing {
        var failures: [URL] = []

        // Returning true keeps the walk going: one locked folder must not abort the whole listing.
        let record: (URL, Error) -> Bool = { failedURL, _ in
            failures.append(failedURL)
            return true
        }

        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: keys,
                                          options: options, errorHandler: record) else {
            return DirectoryListing(urls: [], outcome: .unreadable)
        }

        var kept: [URL] = []
        // Asked only when the caller prefetched the answer, and only of the real disk.
        var links: Set<String>? = keys?.contains(.isSymbolicLinkKey) == true ? [] : nil
        let asksLinks = links != nil && self is FileManager
        var entryCount = 0
        for case let child as URL in enumerator {
            // Counted before filtering: a zero entry count is what tells `classify` the root
            // failed, and a filter that rejects everything must not look like that.
            entryCount += 1
            // `isDirectory:` supplied, because the no-argument overload stats the path for the
            // trailing slash. The enumerator's `hasDirectoryPath` already knows, and `.path` is the
            // same either way.
            let spelled = base.appendingPathComponent(child.relativePath, isDirectory: child.hasDirectoryPath)
            if isWanted(spelled) {
                kept.append(spelled)
                if asksLinks, (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    links?.insert(spelled.path)
                }
            }

            // **A recursive walk must not enter a dataless folder**: the enumerator reads its
            // contents on the next call, which never returns if the provider isn't running. A nested
            // walk lists it instead, asking through the reads first. A file costs no `stat`.
            if let reads, !options.contains(.skipsSubdirectoryDescendants), child.hasDirectoryPath,
               isDataless(at: spelled) {
                enumerator.skipDescendants()
                let below = listing(of: spelled, includingPropertiesForKeys: keys, options: options,
                                    keeping: isWanted, askingThrough: reads)
                switch below.outcome {
                case .unreadable:
                    failures.append(spelled)
                case .listedWithUnreadableDescendants:
                    failures.append(contentsOf: below.unreadableDescendants)
                    kept.append(contentsOf: below.urls)
                    links?.formUnion(below.symbolicLinkPaths ?? [])
                case .listed:
                    kept.append(contentsOf: below.urls)
                    links?.formUnion(below.symbolicLinkPaths ?? [])
                }
            }
        }

        let verdict = DirectoryListingSupport.classify(entryCount: entryCount, failures: failures, root: url)
        return DirectoryListing(urls: verdict.outcome == .unreadable ? [] : kept,
                                outcome: verdict.outcome,
                                unreadableDescendants: verdict.unreadableDescendants,
                                symbolicLinkPaths: verdict.outcome == .unreadable ? nil : links)
    }

    /// How many entries sit under `url`, counted rather than collected, and whether the count can
    /// be trusted. For a folder about to be replaced, which can be huge: it keeps nothing and stops
    /// at `cap`, so the cost is bounded by the cap.
    ///
    /// - Parameter options: required, unlike `listing(of:…)`'s shallow default, because `[]` here
    ///   means a recursive walk and an omitted argument there means shallow.
    ///
    /// - Parameter cap: the most this counts to; reaching it sets `isCapped` ("at least this many").
    ///   A non-positive cap stops on the first entry and answers "at least 1", never a claim about a
    ///   directory it didn't open.
    ///
    /// - Important: when `isCapped`, `outcome` covers only what was read: `.listed` means nothing
    ///   unreadable in the first `cap` entries. `.unreadable` needs a count of zero, so it is exact.
    func childCount(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions,
        cap: Int
    ) -> DirectoryChildCount {
        childCount(of: url, options: options, cap: cap, askingThrough: datalessFolderReads)
    }

    /// ``childCount(of:options:cap:)`` with its reads passed explicitly, like the `listing` overload.
    internal func childCount(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions,
        cap: Int,
        askingThrough reads: FileSyncManager.DatalessFolderReads?
    ) -> DirectoryChildCount {
        // A dataless folder is asked for as `listing` asks: a count would block on it just the same.
        if let reads, isDataless(at: url),
           reads.readBlocking(url.path, { [self] in listingForARead(of: url).outcome }) == nil {
            return DirectoryChildCount(count: 0, outcome: .unreadable, isCapped: false)
        }
        let direct = drainCount(of: url, options: options, cap: cap, askingThrough: reads)
        guard direct.outcome == .unreadable,
              let target = DirectoryListingSupport.traversableTarget(of: url, using: self)
        else { return direct }
        // No re-spelling: a count is the same either way. A failed retry stays unreadable, as in
        // `listing`. Pinned by `countingThroughASymlinkReachesTheRealNumber` and its locked-link
        // control.
        return drainCount(of: target, options: options, cap: cap, askingThrough: reads)
    }

    fileprivate func drainCount(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions,
        cap: Int,
        askingThrough reads: FileSyncManager.DatalessFolderReads?
    ) -> DirectoryChildCount {
        var failures: [URL] = []
        let record: (URL, Error) -> Bool = { failedURL, _ in
            failures.append(failedURL)
            return true
        }

        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: nil,
                                          options: options, errorHandler: record) else {
            return DirectoryChildCount(count: 0, outcome: .unreadable, isCapped: false)
        }

        var count = 0
        var isCapped = false
        while let entry = enumerator.nextObject() {
            count += 1
            if count >= cap {
                isCapped = true
                break
            }
            // Not let into a dataless folder, as in `drainListing`: a nested count asks through the
            // reads first, against what is left of the cap.
            if let reads, !options.contains(.skipsSubdirectoryDescendants),
               let child = entry as? URL, child.hasDirectoryPath, isDataless(at: child) {
                enumerator.skipDescendants()
                let below = childCount(of: child, options: options, cap: cap - count, askingThrough: reads)
                count += below.count
                switch below.outcome {
                case .unreadable, .listedWithUnreadableDescendants:
                    failures.append(child)
                case .listed:
                    break
                }
                if below.isCapped || count >= cap {
                    isCapped = true
                    break
                }
            }
        }

        let verdict = DirectoryListingSupport.classify(entryCount: count, failures: failures, root: url)
        return DirectoryChildCount(count: count, outcome: verdict.outcome, isCapped: isCapped)
    }
}

/// How many entries a directory holds, and how far the answer can be trusted.
public struct DirectoryChildCount: Equatable, Sendable {
    /// Entries seen. Meaningless when `outcome == .unreadable`; a floor rather than a total when
    /// `isCapped` or when `outcome == .listedWithUnreadableDescendants`.
    public let count: Int

    /// How much of the directory the count actually covers.
    public let outcome: DirectoryListingOutcome

    /// True when counting stopped at the cap rather than at the end of the directory. A floor, as is
    /// `.listedWithUnreadableDescendants`, but kept apart: the folder-replace warning words them
    /// differently ("1000+ items" against "at least 3 items").
    public let isCapped: Bool

    public init(count: Int, outcome: DirectoryListingOutcome, isCapped: Bool) {
        self.count = count
        self.outcome = outcome
        self.isCapped = isCapped
    }
}

public enum DirectoryListingSupport {

    /// Turns the entry count and the URLs the error handler named into an outcome. The one place
    /// that rule lives, so a call site streaming its own enumerator (the details sidebar's size
    /// walk) reaches the same verdict as
    /// ``FileManaging/listing(of:includingPropertiesForKeys:options:)``.
    ///
    /// Whether the root failed is decided by the entry count, never by matching the reported URL:
    /// asking for `/var/…/locked` reports `/private/var/…/locked`, which `standardizedFileURL`
    /// doesn't fix. The count is exact, because an unreadable descendant is itself yielded as an
    /// entry, so failures with zero entries can only mean the root itself couldn't be read.
    public static func classify(
        entryCount: Int, failures: [URL], root: URL
    ) -> (outcome: DirectoryListingOutcome, unreadableDescendants: [URL]) {
        if failures.isEmpty { return (.listed, []) }
        if entryCount == 0 { return (.unreadable, []) }
        // Root read, some subtree below it withheld. Drop any entry that is the root itself, so
        // the caller's list holds only genuine descendants whichever way the OS spelled them.
        let rootPath = identity(of: root)
        return (.listedWithUnreadableDescendants, failures.filter { identity(of: $0) != rootPath })
    }

    /// The URL a refused listing should be retried against, or nil when there is nothing to retry.
    ///
    /// **`FileManager.enumerator(at:)` doesn't traverse a symlinked directory**: on a link to a
    /// readable folder it yields nothing and reports the link to the error handler, which
    /// ``classify(entryCount:failures:root:)`` reads as `.unreadable`. Without this retry the picker
    /// would say "Can't be read" about a folder Finder lists fine.
    ///
    /// - Not run for an injected `FileManaging`: a mock's paths aren't on this disk, and
    ///   `resourceValues` would consult the real one (`/var` is itself a symlink). Mocks hold no
    ///   symlinks anyway.
    /// - nil for a link that resolves to itself (a broken or self-referential one), which must
    ///   stay unreadable.
    /// - It decides nothing: the caller re-runs the walk on the target and keeps the failure if
    ///   that fails too.
    public static func traversableTarget(of url: URL, using fileManager: FileManaging) -> URL? {
        guard fileManager is FileManager else { return nil }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        return resolved.path == url.path ? nil : resolved
    }

    /// A comparable form of a directory URL: keeps the root out of the descendant list, and lets
    /// `DestinationBrowser.search` spot a directory reached twice. Never used to decide whether the
    /// root failed, which the entry count settles. `resolvingSymlinksInPath`, not
    /// `standardizedFileURL`, because only resolving maps `/var` and `/private/var` to one form.
    static func identity(of url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
