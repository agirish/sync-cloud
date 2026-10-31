//
//  OneWaySyncStore.swift
//  SyncCloud
//

import CryptoKit
import Foundation
import IOKit

/// RD67's saved state on this Mac, in one folder of Application Support:
///
/// | File | Holds |
/// |---|---|
/// | `record.json` | the record (`OneWaySyncRecord`) and the first run it belongs to |
/// | `state.json` | the DA settings, the removal window, Pause, the last sync |
/// | `exclusions.json` | files you stopped syncing, apart from the record so a new first run keeps them |
/// | `outside.json` | iCloud's files in unsynced and shared folders at the last pass, by ID: where a file moved in came from |
/// | `notices.json` | Activity ▸ Now's saved rows (`OneWaySyncNoticeStore`) |
/// | `History/` | one entry per sync that changed or held something (`OneWaySyncHistoryStore`) |
/// | `sync.lock` | held by the one process that syncs (`OneWaySyncProcessLock`) |
///
/// Every file is written whole and flushed (`OneWaySyncFiles`). The folder is injected, never
/// defaulted inside `Sync`, like the other stores: library code must not reach into the real
/// home folder because nobody said otherwise.
public struct OneWaySyncStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/SyncCloud/One-Way Sync`.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/One-Way Sync")
    }

    public var recordURL: URL { directory.appendingPathComponent("record.json") }
    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var exclusionsURL: URL { directory.appendingPathComponent("exclusions.json") }
    public var noticesURL: URL { directory.appendingPathComponent("notices.json") }
    public var outsideURL: URL { directory.appendingPathComponent("outside.json") }
    public var historyDirectory: URL { directory.appendingPathComponent("History") }
    public var lockURL: URL { directory.appendingPathComponent("sync.lock") }

    public var history: OneWaySyncHistoryStore { OneWaySyncHistoryStore(directory: historyDirectory) }

    // MARK: The record

    /// The saved record, if it belongs to the Mac, accounts and disk in `binding`, with the first
    /// run it belongs to. A record whose state file is missing or unreadable is *sync data lost*:
    /// Pause, the settings and the removal window would come back as their defaults, and a sync
    /// the user paused would run.
    public func loadRecord(on binding: OneWaySyncBinding) -> OneWaySyncSavedRecord {
        let data: Data
        do { data = try Data(contentsOf: recordURL) } catch {
            let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
            return .needsNewFirstRun(missing ? .noRecord : .unreadable)
        }
        let load = OneWaySyncRecord.load(data, on: binding)
        guard case .ready(let record) = load else {
            guard case .needsNewFirstRun(let reason) = load else { return .needsNewFirstRun(.unreadable) }
            // A value this Mac couldn't read now (iCloud signed out, iCloud Drive off) says
            // nothing about the account: the sync waits, and no first run is asked for.
            if let field = reason.bindingField, binding[keyPath: field].isEmpty { return .cannotConfirm(reason) }
            return .needsNewFirstRun(reason)
        }
        struct Generation: Decodable { var firstRun: UUID }
        // A missing state reads as the defaults everywhere else; beside a record it is data lost.
        guard let generation = try? JSONDecoder().decode(Generation.self, from: data),
              FileManager.default.fileExists(atPath: stateURL.path),
              case .ready(let state) = loadState() else { return .needsNewFirstRun(.unreadable) }
        return .ready(record, firstRun: generation.firstRun, state: state)
    }

    /// Saves the record after a sync, keeping the first run it belongs to.
    public func saveRecord(_ record: OneWaySyncRecord, firstRun: UUID) throws {
        try OneWaySyncFiles.writeDurably(StoredRecord(record: record, firstRun: firstRun).encoded(), to: recordURL)
    }

    /// Saves the record a new first run made, under a new first-run ID: History entries from
    /// before it can no longer be reversed. The old record goes first, then the state, then the
    /// new record, so a crash at any point leaves no record (a new first run, which the user
    /// starts) or the new one with its state — never the old record beside the new state, which
    /// would read as ready.
    @discardableResult
    public func startFirstRun(_ record: OneWaySyncRecord, state: OneWaySyncSavedState) throws -> UUID {
        let firstRun = UUID()
        try OneWaySyncFiles.remove(recordURL)
        try saveState(state)
        try saveRecord(record, firstRun: firstRun)
        return firstRun
    }

    /// Turn Off One-Way Sync: the record, the state and the files outside go. Exclusions, saved
    /// rows and History are the caller's to keep or remove.
    public func removeRecord() throws {
        try OneWaySyncFiles.remove(recordURL)
        try OneWaySyncFiles.remove(stateURL)
        try OneWaySyncFiles.remove(outsideURL)
    }

    // MARK: State

    public func loadState() -> OneWaySyncLoad<OneWaySyncSavedState> {
        .read(stateURL, currentVersion: OneWaySyncSavedState.currentVersion)
    }

    public func saveState(_ state: OneWaySyncSavedState) throws {
        try OneWaySyncFiles.writeDurably(Self.encode(state), to: stateURL)
    }

    // MARK: Files you stopped syncing

    /// The exclusions. Missing is none; unreadable stops the sync, since syncing a file the user
    /// stopped would overwrite the Dropbox copy they chose to keep.
    public func loadExclusions() -> OneWaySyncLoad<OneWaySyncExclusions> {
        .read(exclusionsURL, currentVersion: OneWaySyncExclusions.currentVersion)
    }

    public func saveExclusions(_ exclusions: OneWaySyncExclusions) throws {
        try OneWaySyncFiles.writeDurably(Self.encode(exclusions), to: exclusionsURL)
    }

    // MARK: Files outside the synced folders

    /// Where iCloud's files outside the synced folders were at the last pass. A hint, never a
    /// reason to stop: missing or unreadable reads as none, which only leaves a file moved in
    /// without a way back in *Reverse in iCloud*.
    public func loadOutside() -> OneWaySyncOutsideFiles {
        OneWaySyncLoad<OneWaySyncOutsideFiles>.read(outsideURL, currentVersion: OneWaySyncOutsideFiles.currentVersion).value
            ?? OneWaySyncOutsideFiles()
    }

    public func saveOutside(_ outside: OneWaySyncOutsideFiles) throws {
        try OneWaySyncFiles.writeDurably(Self.encode(outside), to: outsideURL)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// The record's own keys, with `firstRun` beside them: the record decodes from the same file
    /// unchanged (`OneWaySyncRecord.load` reads its version first and ignores the extra key), and
    /// the record and its first run are replaced in one write.
    private struct StoredRecord: Encodable {
        var record: OneWaySyncRecord
        var firstRun: UUID

        enum Key: String, CodingKey { case firstRun }

        func encode(to encoder: Encoder) throws {
            try record.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(firstRun, forKey: .firstRun)
        }

        func encoded() throws -> Data { try OneWaySyncStore.encode(self) }
    }
}

public enum OneWaySyncSavedRecord: Equatable, Sendable {
    /// `firstRun` names the first run this record grew from; a History entry made under another
    /// can't be reversed.
    case ready(OneWaySyncRecord, firstRun: UUID, state: OneWaySyncSavedState)
    case needsNewFirstRun(OneWaySyncNewFirstRunReason)
    /// The binding field `reason` names couldn't be read on this Mac just now — iCloud signed
    /// out or iCloud Drive turned off, for the account. The whole sync waits, with that row,
    /// until it can be read; it isn't a new first run.
    case cannotConfirm(OneWaySyncNewFirstRunReason)
}

extension OneWaySyncNewFirstRunReason {
    /// The binding field a mismatch of this kind compared.
    var bindingField: KeyPath<OneWaySyncBinding, String>? {
        switch self {
        case .otherMac: return \.hardwareID
        case .otherICloudAccount: return \.iCloudAccount
        case .otherDropboxAccount: return \.dropboxAccountFolder
        case .otherDisk: return \.dataVolumeUUID
        case .noRecord, .unreadable, .unsupportedVersion, .noMarker: return nil
        }
    }
}

/// A saved file that may be missing (nothing saved yet, so the type's empty value), read, or
/// unreadable — which never reads as missing: a lost Pause or a lost exclusion would sync what
/// the user held back.
public enum OneWaySyncLoad<Value: Equatable & Sendable>: Equatable, Sendable {
    case ready(Value)
    case unreadable

    public var value: Value? {
        if case .ready(let value) = self { return value }
        return nil
    }
}

extension OneWaySyncLoad where Value: Decodable & OneWaySyncEmpty {
    static func read(_ url: URL, currentVersion: Int) -> OneWaySyncLoad<Value> {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
            return missing ? .ready(Value.empty) : .unreadable
        }
        guard (try? JSONDecoder().decode(OneWaySyncVersionHeader.self, from: data))?.version == currentVersion,
              let value = try? JSONDecoder().decode(Value.self, from: data) else { return .unreadable }
        return .ready(value)
    }
}

/// Every saved file's `version`, read on its own first so a file from a newer build is never
/// half-decoded as this one.
struct OneWaySyncVersionHeader: Decodable {
    var version: Int
}

/// What a saved file reads as before anything was saved.
public protocol OneWaySyncEmpty {
    static var empty: Self { get }
}

/// What the sync keeps between passes beside the record. Lost with the record at Turn Off.
///
/// The removal window is the apply layer's to save before it applies a removal, not after: a
/// crash between the two would otherwise let those removals drop out of the 24 hours.
public struct OneWaySyncSavedState: Codable, Equatable, Sendable, OneWaySyncEmpty {
    public static let currentVersion = 1

    public var version: Int
    public var settings: OneWaySyncSettings
    /// The removal limit's last 24 hours.
    public var window: OneWaySyncRemovalWindow
    /// When the user paused, in seconds; nil while running. Pause survives a quit.
    public var pausedSince: Int64?
    /// The last sync this Mac finished, in seconds.
    public var lastSyncAt: Int64?
    /// Folders directly in the iCloud parent that aren't synced and the user has already been
    /// told of, or left unticked at setup: only a folder not here is *new in iCloud*. The
    /// record keeps no list of them (`OneWaySyncPlan.unsyncedICloudFolders`).
    public var knownUnsyncedFolders: [String]
    /// Files (record keys) whose removal or replacement the user confirmed and the sync hasn't
    /// applied yet (`OneWaySyncPass.confirmed`): a quit before it does keeps the answer.
    public var confirmed: [UInt64]

    public init(
        version: Int = OneWaySyncSavedState.currentVersion, settings: OneWaySyncSettings = OneWaySyncSettings(),
        window: OneWaySyncRemovalWindow = OneWaySyncRemovalWindow(), pausedSince: Int64? = nil, lastSyncAt: Int64? = nil,
        knownUnsyncedFolders: [String] = [], confirmed: [UInt64] = []
    ) {
        self.version = version
        self.settings = settings
        self.window = window
        self.pausedSince = pausedSince
        self.lastSyncAt = lastSyncAt
        self.knownUnsyncedFolders = knownUnsyncedFolders
        self.confirmed = confirmed
    }

    public static var empty: OneWaySyncSavedState { OneWaySyncSavedState() }
}

/// A file the user stopped syncing: it stays as it is in Dropbox, listed in Settings with
/// *Sync Again…*. Followed by its IDs as well as its paths, so a rename on either side keeps it
/// excluded.
public struct OneWaySyncExclusion: Codable, Equatable, Hashable, Sendable {
    public var iCloudPath: String
    public var dropboxPath: String
    public var iCloudID: UInt64?
    public var dropboxID: UInt64?
    /// Seconds since 1970.
    public var stoppedAt: Int64

    public init(iCloudPath: String, dropboxPath: String, iCloudID: UInt64? = nil, dropboxID: UInt64? = nil, stoppedAt: Int64) {
        self.iCloudPath = iCloudPath
        self.dropboxPath = dropboxPath
        self.iCloudID = iCloudID
        self.dropboxID = dropboxID
        self.stoppedAt = stoppedAt
    }
}

public struct OneWaySyncExclusions: Codable, Equatable, Sendable, OneWaySyncEmpty {
    public static let currentVersion = 1

    public var version: Int
    public var files: [OneWaySyncExclusion]

    public init(version: Int = OneWaySyncExclusions.currentVersion, files: [OneWaySyncExclusion] = []) {
        self.version = version
        self.files = files
    }

    public static var empty: OneWaySyncExclusions { OneWaySyncExclusions() }
}

/// iCloud's files in folders outside the synced ones at a pass — in folders that aren't synced, or
/// shared ones; not files loose in the parent, which isn't listed — by document ID (EU). At the next pass, a new file in a synced folder with one of these
/// IDs was moved in from there: its copy's History step says where from, and *Reverse in iCloud*
/// can move it back. iCloud keeps a file's ID across a move (measured).
public struct OneWaySyncOutsideFiles: Codable, Equatable, Sendable, OneWaySyncEmpty {
    public static let currentVersion = 1

    public struct File: Codable, Equatable, Sendable {
        public var id: UInt64
        public var path: String
    }

    public var version: Int
    /// By path, so an unchanged index writes the same bytes.
    public var files: [File]

    public init() {
        version = Self.currentVersion
        files = []
    }

    /// The excluded files of an iCloud listing that carry an ID of their own (hard links share one).
    public init(listing: OneWaySyncListing) {
        var paths: [UInt64: [String]] = [:]
        for item in listing.items where item.kind == .file && item.isExcluded {
            if let id = item.documentID, id != 0 { paths[id, default: []].append(item.path) }
        }
        version = Self.currentVersion
        files = paths.compactMap { $0.value.count == 1 ? File(id: $0.key, path: $0.value[0]) : nil }.sorted { $0.path < $1.path }
    }

    /// Keeps `id` at `path`, unless the listing found it outside the synced folders anyway.
    mutating func carry(id: UInt64, path: String) {
        guard !files.contains(where: { $0.id == id }) else { return }
        files.append(File(id: id, path: path))
        files.sort { $0.path < $1.path }
    }

    public var byID: [UInt64: String] {
        Dictionary(files.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
    }

    public static var empty: OneWaySyncOutsideFiles { OneWaySyncOutsideFiles() }
}

// MARK: - This Mac

public extension OneWaySyncBinding {

    /// The binding of the Mac this runs on. A value that can't be read is left empty, which
    /// `mismatch(with:)` treats as a mismatch: it can't confirm anything.
    ///
    /// - The hardware ID is `IOPlatformUUID`, which survives a reinstall and a rename of the Mac.
    /// - The iCloud account is a SHA-256 of `ubiquityIdentityToken`, which needs no iCloud
    ///   permission; empty while signed out or with iCloud Drive off. Measured 30 Oct: the token's
    ///   bytes are the same across launches.
    /// - The Data volume is the home folder's volume (the Data volume on a Mac set up as usual),
    ///   which a migration to a new disk changes.
    static func current(dropboxAccountFolder: String) -> OneWaySyncBinding {
        OneWaySyncBinding(
            hardwareID: platformUUID() ?? "",
            iCloudAccount: iCloudAccountDigest() ?? "",
            dropboxAccountFolder: dropboxAccountFolder,
            dataVolumeUUID: volumeUUID(of: NSHomeDirectory()) ?? "")
    }

    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    static func iCloudAccountDigest() -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        let bytes: Data
        if let data = token as? Data {
            bytes = data
        } else if let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            bytes = archived
        } else {
            return nil
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func volumeUUID(of path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
}
