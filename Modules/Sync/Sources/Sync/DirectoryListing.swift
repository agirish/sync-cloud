//
//  DirectoryListing.swift
//  SyncCloud
//

import Foundation

/// How completely a directory could be read.
///
/// The three cases exist because two of them are currently the same value everywhere in this
/// codebase, and the wrong one wins. Callers switch over this exhaustively, so a fourth case
/// would fail to compile rather than being absorbed by a `default:`.
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

/// The result of listing one directory, keeping "could not be listed" distinguishable from
/// "listed, and it is empty".
///
/// Those two arrive identically through `FileManager.enumerator(at:)`, and the `guard let` idiom
/// wrapped around it does not separate them — **the enumerator is not nil for a directory it
/// cannot read.** Measured on this machine:
///
///     directory, mode 000, 3 files   enumerator: NON-NIL, 0 entries   contentsOfDirectory: THROWS
///     directory that does not exist  enumerator: NON-NIL, 0 entries   contentsOfDirectory: THROWS
///     directory, genuinely empty     enumerator: NON-NIL, 0 entries   contentsOfDirectory: 0
///
/// So every `guard let enumerator = fm.enumerator(at:…) else { report failure }` in this repo has
/// an else-branch the filesystem never reaches, and an unreadable folder arrives at the caller
/// indistinguishable from an empty one. That is not a theoretical shape: it is why a folder-replace
/// confirmation can say "0 items will be removed" immediately before removing all of them.
///
/// The separator is the `errorHandler:`, also measured. It fires exactly once with the ROOT's own
/// URL when the root cannot be listed; it fires with the DESCENDANT's URL when a subdirectory
/// below it cannot be descended into (the root is not among them, and the unreadable subdirectory
/// is still yielded as an entry); and it never fires for a directory that is genuinely empty.
///
/// `FileDiffEngine`'s cold walk already does this by hand and is the strongest instance in the
/// repo — it aggregates unreadable directories and re-marks them `isUnexplored`. This type is that
/// reasoning made reusable for the call sites that list one directory eagerly. It deliberately
/// does NOT replace the diff engine's streaming walk: this drains the enumerator into an array,
/// which is right for a single directory of children and wrong for a 39,000-entry tree.
public struct DirectoryListing: Sendable {
    /// The entries read. Empty and meaningless when `outcome == .unreadable`; empty and
    /// authoritative when `outcome == .listed`.
    public let urls: [URL]

    /// How much of the directory the listing actually covers.
    public let outcome: DirectoryListingOutcome

    /// Descendants that could not be descended into, when `outcome` is
    /// `.listedWithUnreadableDescendants`. Empty otherwise.
    public let unreadableDescendants: [URL]

    /// True only when `urls` is the complete, trustworthy contents. Provided so a call site that
    /// genuinely has one honest answer for both failure shapes can say so in one word — a call
    /// site that needs to tell them apart switches on `outcome` instead.
    public var isComplete: Bool { outcome == .listed }

    public init(urls: [URL], outcome: DirectoryListingOutcome, unreadableDescendants: [URL] = []) {
        self.urls = urls
        self.outcome = outcome
        self.unreadableDescendants = unreadableDescendants
    }
}

public extension FileManaging {

    /// Lists what is under `url`, reporting whether the listing can be trusted.
    ///
    /// Defaults to a shallow listing — `urls` is then exactly the immediate children, which is what
    /// every call site converted to this reads. Pass `options: []` for a recursive listing, where
    /// `urls` is every descendant rather than the children, and which is the only way to reach
    /// `.listedWithUnreadableDescendants`.
    ///
    /// - Parameter isWanted: decides which entries `urls` holds on to. Every entry is still
    ///   *visited* — the outcome is unchanged by it — but only the ones this keeps are retained,
    ///   so a caller that wants the subdirectories of a folder holding thirty thousand loose files
    ///   pays for the folders rather than for the files. Defaults to keeping everything.
    ///
    /// - Important: `url` must be a directory. Handing this a regular file answers `.unreadable`,
    ///   measured — the enumerator yields nothing and reports the file through the error handler,
    ///   which is indistinguishable here from a locked directory. That is the safe direction for
    ///   every current caller, but it is a conflation: a caller that needs to tell "not a folder"
    ///   from "locked folder" must ask `fileExists(atPath:isDirectory:)` first rather than reading
    ///   it out of this answer.
    ///
    /// - Important: a SYMLINKED directory is the other shape the enumerator cannot tell apart from
    ///   a locked one, and unlike the regular-file case it is not the safe direction — so it is
    ///   handled rather than documented. See ``DirectoryListingSupport/traversableTarget(of:using:)``.
    ///   When the retry succeeds, `urls` is re-spelled under the path the CALLER asked about
    ///   rather than under the link's target, because a picker's breadcrumbs and recents are keyed
    ///   on the path it browsed through. `unreadableDescendants` is the one thing that is not:
    ///   those URLs come from the error handler, which reports absolute paths with no relative
    ///   base to re-spell from, so on that path alone they carry the target's spelling.
    ///
    /// - Note: a nil enumerator is treated as `.unreadable` for completeness, but neither the real
    ///   filesystem nor `MockFileManager` produces one — the real one because that is the whole
    ///   finding behind this type, the mock because it models the real one faithfully. The failure
    ///   detection that matters happens through the error handler.
    func listing(
        of url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants],
        keeping isWanted: (URL) -> Bool = { _ in true }
    ) -> DirectoryListing {
        let direct = drainListing(of: url, keys: keys, options: options,
                                  respellingUnder: nil, keeping: isWanted)
        guard direct.outcome == .unreadable,
              let target = DirectoryListingSupport.traversableTarget(of: url, using: self)
        else { return direct }

        // `.producesRelativePathURLs` rather than prefix arithmetic on the paths: measured, the
        // enumerator yields children under `/private/var/…` while `resolvingSymlinksInPath` hands
        // back `/var/…`, so `hasPrefix(target.path)` matches nothing. The relative path is exact
        // at any depth and needs no canonicalisation on either side.
        let retried = drainListing(of: target, keys: keys,
                                   options: options.union(.producesRelativePathURLs),
                                   respellingUnder: url, keeping: isWanted)
        // A link to a locked directory, a broken link and a link to a regular file all land here
        // and all stay unreadable — the fallback may only ever turn a false failure into a real
        // listing, never the reverse.
        return retried.outcome == .unreadable ? direct : retried
    }

    /// One pass of the enumerator, with no fallback of its own.
    ///
    /// - Parameter base: when non-nil, every entry is re-spelled as `base` + the entry's relative
    ///   path before the caller's filter sees it, so a predicate about the path is asked the same
    ///   question on the direct and the retried walk.
    fileprivate func drainListing(
        of url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        respellingUnder base: URL?,
        keeping isWanted: (URL) -> Bool
    ) -> DirectoryListing {
        var failures: [URL] = []

        // Returning true keeps the walk going: one locked folder must not abort the whole listing,
        // which is the same call FileDiffEngine's handler makes for the same reason.
        let record: (URL, Error) -> Bool = { failedURL, _ in
            failures.append(failedURL)
            return true
        }

        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: keys,
                                          options: options, errorHandler: record) else {
            return DirectoryListing(urls: [], outcome: .unreadable)
        }

        var kept: [URL] = []
        var entryCount = 0
        for case let child as URL in enumerator {
            // Counted before it is filtered, and the two must never be the same number. A zero
            // ENTRY count is precisely what tells `classify` the root itself failed; a filter that
            // happens to reject everything is a folder with nothing the caller wanted in it, which
            // is a completely different statement.
            entryCount += 1
            let spelled = base.map { $0.appendingPathComponent(child.relativePath) } ?? child
            if isWanted(spelled) { kept.append(spelled) }
        }

        let verdict = DirectoryListingSupport.classify(entryCount: entryCount, failures: failures, root: url)
        return DirectoryListing(urls: verdict.outcome == .unreadable ? [] : kept,
                                outcome: verdict.outcome,
                                unreadableDescendants: verdict.unreadableDescendants)
    }

    /// How many entries sit under `url`, counted rather than collected, and whether the count can
    /// be trusted.
    ///
    /// Separate from ``listing(of:includingPropertiesForKeys:options:keeping:)`` because the one
    /// caller that needs this needs it on a folder about to be destroyed, which can hold a hundred
    /// thousand entries: `listing` retains what it is asked to keep, and this caller wants only the
    /// number. It stops at `cap` and says so, so the cost is bounded by the cap rather than by the
    /// folder.
    ///
    /// - Parameter options: required rather than defaulted, and deliberately unlike its sibling's
    ///   shallow default. `[]` here means a RECURSIVE walk, which is the opposite of what an
    ///   omitted argument means one declaration away on `listing(of:…)`; a default that quiet is
    ///   worth more read wrong than saved.
    ///
    /// - Parameter cap: the highest number this will count to. On reaching it the walk stops and
    ///   `isCapped` is true, which reads as "at least this many". A non-positive cap has no
    ///   special case: the check runs after the increment, so counting stops on the first entry
    ///   and the answer is "at least 1" — never a claim about a directory this did not open.
    ///
    /// - Important: when `isCapped` is true, `outcome` describes only the part that was read. A
    ///   locked subdirectory beyond the cap is never met, so `.listed` there means "nothing
    ///   unreadable in the first `cap` entries", not "nothing unreadable at all". `.unreadable` is
    ///   unaffected: it requires a count of zero, which no capped walk can have.
    func childCount(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions,
        cap: Int
    ) -> DirectoryChildCount {
        let direct = drainCount(of: url, options: options, cap: cap)
        guard direct.outcome == .unreadable,
              let target = DirectoryListingSupport.traversableTarget(of: url, using: self)
        else { return direct }
        // No re-spelling to do: this hands back a number, and the number is the target's either
        // way. Same one-way rule as `listing` — a retry that also fails changes nothing.
        let retried = drainCount(of: target, options: options, cap: cap)
        return retried.outcome == .unreadable ? direct : retried
    }

    fileprivate func drainCount(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions,
        cap: Int
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
        while enumerator.nextObject() != nil {
            count += 1
            if count >= cap {
                isCapped = true
                break
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

    /// True when counting stopped at the cap rather than at the end of the directory.
    ///
    /// A floor under the real number, as is `.listedWithUnreadableDescendants` — but the two are
    /// deliberately NOT rolled into one "is this a floor?" property. The only consumer, the
    /// folder-replace warning, has to word them differently ("1000+ items" for a floor we chose,
    /// "at least 3 items" for one the disk imposed), so a combined flag would be answered and then
    /// immediately re-split at its single call site.
    public let isCapped: Bool

    public init(count: Int, outcome: DirectoryListingOutcome, isCapped: Bool) {
        self.count = count
        self.outcome = outcome
        self.isCapped = isCapped
    }
}

public enum DirectoryListingSupport {

    /// Turns "how many entries came back" plus "which URLs the error handler named" into an
    /// outcome. The one place that rule is written down, so a call site that streams its own
    /// enumerator — the folder-size walk in the details sidebar, which cannot afford to collect
    /// what it counts — reaches the same verdict as ``FileManaging/listing(of:includingPropertiesForKeys:options:)``
    /// rather than restating it slightly differently.
    ///
    /// Whether the ROOT failed is decided by the entry count, not by comparing the reported URL
    /// against the one we asked for. That comparison looks like the direct signal and is the
    /// trap: measured on this machine, asking for `/var/…/locked` gets the failure reported as
    /// `/private/var/…/locked`, and `standardizedFileURL` does not close that gap — the match
    /// failed in two of three constructions of the same directory.
    ///
    /// The count is exact instead. A DESCENDANT failure can only be reported after the root was
    /// listed successfully, and the unreadable descendant is itself yielded as an entry (a
    /// listable root holding one locked subdirectory yields 2 entries, not 0). So a handler that
    /// fired with nothing to show for it can only mean the root itself could not be read.
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
    /// `FileManager.enumerator(at:)` **does not traverse a symlinked directory.** Measured on this
    /// machine, against a symlink pointing at a perfectly readable folder:
    ///
    ///     enumerator(at: link)          NON-NIL, 0 entries, error handler fires with `link`
    ///     contentsOfDirectory(atPath:)  ["note.txt", "Medical", "Dental"]
    ///
    /// The first line is byte for byte the signature ``classify(entryCount:failures:root:)`` reads
    /// as `.unreadable` — so without this, the destination picker says "Can't be read" about a
    /// folder Finder lists fine, and a search that walked the whole tree reports itself truncated.
    /// That is the same unearned claim the rest of this file exists to stop, pointing the other
    /// way. The repo already knew the quirk: `FileSyncManager+Scanning`'s cold walk falls back to
    /// the path-based listing for exactly this reason, and this is that fallback made reusable.
    ///
    /// Three things it deliberately does not do:
    ///
    /// - **It does not run for an injected `FileManaging`.** A mock's paths are not on this disk,
    ///   and `resourceValues` would consult the real one regardless — `/var` is itself a symlink,
    ///   so a mock directory named `/var` would otherwise be retried against the machine's own.
    ///   Mock disks contain no symlinks, so there is nothing there to rescue anyway.
    /// - **It does not resolve a link that resolves to itself.** Measured, a broken link and a
    ///   self-referential one both come back equal to the original, and retrying them would only
    ///   repeat the same refusal; both are genuinely unreadable and must stay that way.
    /// - **It does not decide anything.** It offers a second URL to ask; the caller re-runs the
    ///   same walk and keeps the failure if the second ask fails too.
    public static func traversableTarget(of url: URL, using fileManager: FileManaging) -> URL? {
        guard fileManager is FileManager else { return nil }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        return resolved.path == url.path ? nil : resolved
    }

    /// A comparable form of a directory URL, used only to keep the root out of the descendant
    /// list — never to decide whether the root failed, which the entry count settles exactly.
    ///
    /// `resolvingSymlinksInPath` is applied to BOTH sides rather than `standardizedFileURL`,
    /// because the gap this has to close is `/var` vs `/private/var`: resolving maps both to the
    /// same form, and standardizing maps neither. That it also resolves symlinks is harmless here
    /// — a symlinked root and the failure reported for it are the same directory either way.
    static func identity(of url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
