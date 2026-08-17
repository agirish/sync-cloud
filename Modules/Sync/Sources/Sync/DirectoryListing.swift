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
    /// - Important: `url` must be a directory. Handing this a regular file answers `.unreadable`,
    ///   measured — the enumerator yields nothing and reports the file through the error handler,
    ///   which is indistinguishable here from a locked directory. That is the safe direction for
    ///   every current caller, but it is a conflation: a caller that needs to tell "not a folder"
    ///   from "locked folder" must ask `fileExists(atPath:isDirectory:)` first rather than reading
    ///   it out of this answer.
    ///
    /// - Note: a nil enumerator is treated as `.unreadable` for completeness, but neither the real
    ///   filesystem nor `MockFileManager` produces one — the real one because that is the whole
    ///   finding behind this type, the mock because it models the real one faithfully. The failure
    ///   detection that matters happens through the error handler.
    func listing(
        of url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil,
        options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
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

        var urls: [URL] = []
        for case let child as URL in enumerator {
            urls.append(child)
        }

        let verdict = DirectoryListingSupport.classify(entryCount: urls.count, failures: failures, root: url)
        return DirectoryListing(urls: verdict.outcome == .unreadable ? [] : urls,
                                outcome: verdict.outcome,
                                unreadableDescendants: verdict.unreadableDescendants)
    }

    /// How many entries sit under `url`, counted rather than collected, and whether the count can
    /// be trusted.
    ///
    /// Separate from ``listing(of:includingPropertiesForKeys:options:)`` because the one caller
    /// that needs this needs it on a folder about to be destroyed, which can hold a hundred
    /// thousand entries: `listing` drains every one of them into an array to hand back the URLs,
    /// and this caller wants only the number. It stops at `cap` and says so, so the cost is bounded
    /// by the cap rather than by the folder.
    ///
    /// - Parameter cap: the highest number this will count to. On reaching it the walk stops and
    ///   `isCapped` is true, which reads as "at least this many".
    ///
    /// - Important: when `isCapped` is true, `outcome` describes only the part that was read. A
    ///   locked subdirectory beyond the cap is never met, so `.listed` there means "nothing
    ///   unreadable in the first `cap` entries", not "nothing unreadable at all". `.unreadable` is
    ///   unaffected: it requires a count of zero, which no capped walk can have.
    func childCount(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions = [],
        cap: Int
    ) -> DirectoryChildCount {
        guard cap > 0 else { return DirectoryChildCount(count: 0, outcome: .listed, isCapped: true) }

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
    public let isCapped: Bool

    /// True when `count` is a floor rather than a total — either the walk stopped early, or part
    /// of the tree was withheld. False for `.unreadable`, where `count` is not a floor of anything.
    public var isAtLeast: Bool {
        outcome == .listedWithUnreadableDescendants || (isCapped && outcome != .unreadable)
    }

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
