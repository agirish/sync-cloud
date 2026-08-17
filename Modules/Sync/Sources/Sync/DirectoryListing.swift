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

    /// Lists `url`'s children, reporting whether the listing can be trusted.
    ///
    /// Defaults to a shallow listing because every call site converted to this reads one level.
    /// Pass `options: []` for a recursive listing, which is the only way to reach
    /// `.listedWithUnreadableDescendants`.
    ///
    /// - Note: a nil enumerator is treated as `.unreadable` for completeness, but on the real
    ///   filesystem that branch does not fire — it is reachable only from an injected mock. The
    ///   failure detection that matters happens through the error handler.
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

        // Whether the ROOT failed is decided by the entry count, not by comparing the reported URL
        // against the one we asked for. That comparison looks like the direct signal and is the
        // trap: measured on this machine, asking for `/var/…/locked` gets the failure reported as
        // `/private/var/…/locked`, and `standardizedFileURL` does not close that gap — the match
        // failed in two of three constructions of the same directory.
        //
        // The count is exact instead. A DESCENDANT failure can only be reported after the root was
        // listed successfully, and the unreadable descendant is itself yielded as an entry (a
        // listable root holding one locked subdirectory yields 2 entries, not 0). So a handler that
        // fired with nothing to show for it can only mean the root itself could not be read.
        if failures.isEmpty {
            return DirectoryListing(urls: urls, outcome: .listed)
        }
        if urls.isEmpty {
            return DirectoryListing(urls: [], outcome: .unreadable)
        }
        // Root read, some subtree below it withheld. Drop any entry that is the root itself, so
        // the caller's list holds only genuine descendants whichever way the OS spelled them.
        let rootPath = DirectoryListingSupport.identity(of: url)
        let descendants = failures.filter { DirectoryListingSupport.identity(of: $0) != rootPath }
        return DirectoryListing(urls: urls,
                                outcome: .listedWithUnreadableDescendants,
                                unreadableDescendants: descendants)
    }
}

enum DirectoryListingSupport {
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
