//
//  OneWaySyncListing.swift
//  SyncCloud
//

import Foundation

/// One side of RD67's one-way sync.
public enum OneWaySyncSide: Sendable, CaseIterable {
    case iCloud
    case dropbox

    /// The form two names are compared in on this side. iCloud tells letter case apart and
    /// Dropbox does not; Unicode form (NFC or NFD) counts on neither.
    ///
    /// Swift's `==` already ignores Unicode form, so the NFC step changes no comparison; it makes
    /// the key's bytes stable, which a key written anywhere relies on.
    public func nameKey(_ path: String) -> String {
        let nfc = path.precomposedStringWithCanonicalMapping
        switch self {
        case .iCloud: return nfc
        case .dropbox: return nfc.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }
    }
}

/// An item seen on one side during a pass. The lister fills it; nothing here reads the disk.
public struct OneWaySyncItem: Equatable, Sendable {
    public enum Kind: Sendable {
        case file
        case folder
    }

    /// Relative to the side's parent, `/`-separated; the first component is the folder directly
    /// in the parent. A package is one file.
    public var path: String
    public var kind: Kind
    /// A file's document ID; nil or 0 when it has none.
    public var documentID: UInt64?
    /// A folder's inode and provider item ID.
    public var folderID: OneWaySyncFolderID?
    public var size: Int64
    public var modified: Date
    public var tags: [String]
    /// The contents hash, when the lister had a reason to compute it (the change time moved, or a
    /// first run compares contents). Nil means not read, never "empty".
    public var contentHash: String?
    /// False for an iCloud file offloaded from this Mac; it is compared by size and date and
    /// downloaded only to copy.
    public var isDownloaded: Bool
    /// Inside a shared folder, a symlink, or otherwise skipped. Never synced; an ID found here
    /// means the file was moved out of the synced folders.
    public var isExcluded: Bool

    public init(
        path: String, kind: Kind = .file,
        documentID: UInt64? = nil, folderID: OneWaySyncFolderID? = nil,
        size: Int64 = 0, modified: Date = Date(timeIntervalSince1970: 0), tags: [String] = [],
        contentHash: String? = nil, isDownloaded: Bool = true, isExcluded: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.documentID = documentID
        self.folderID = folderID
        self.size = size
        self.modified = modified
        self.tags = tags
        self.contentHash = contentHash
        self.isDownloaded = isDownloaded
        self.isExcluded = isExcluded
    }

    /// The modification date to the second, the precision every comparison uses.
    var second: Int64 { Int64(modified.timeIntervalSince1970.rounded(.down)) }
}

/// Everything one side holds, from one full check: each folder directly in the parent, with the
/// contents of the synced ones. Items outside the synced folders may be included; they are used
/// only to tell a file moved out from a file deleted.
public struct OneWaySyncListing: Equatable, Sendable {
    public var items: [OneWaySyncItem]
    /// Synced folders (by name) that could not be read completely this pass. Nothing in them is
    /// matched or acted on, and nothing anywhere is called gone, on either side, while any are
    /// listed.
    public var incompleteFolders: Set<String>

    public init(items: [OneWaySyncItem], incompleteFolders: Set<String> = []) {
        self.items = items
        self.incompleteFolders = incompleteFolders
    }
}

/// Path arithmetic on the relative, `/`-separated paths the sync works in.
enum OneWaySyncPath {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func depth(_ path: String) -> Int { components(path).count }

    static func top(_ path: String) -> String { components(path).first ?? "" }

    static func parent(_ path: String) -> String { components(path).dropLast().joined(separator: "/") }

    static func name(_ path: String) -> String { components(path).last ?? "" }

    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    /// Whether moving the Dropbox item at `current` to `desired` changes anything Dropbox shows.
    /// The folder part compares as Dropbox does, ignoring case; the last component compares
    /// exactly, so a change of letter case alone is a rename in place. Unicode form never counts.
    static func needsMove(from current: String, to desired: String) -> Bool {
        let side = OneWaySyncSide.dropbox
        if side.nameKey(parent(current)) != side.nameKey(parent(desired)) { return true }
        return name(current).precomposedStringWithCanonicalMapping != name(desired).precomposedStringWithCanonicalMapping
    }
}
