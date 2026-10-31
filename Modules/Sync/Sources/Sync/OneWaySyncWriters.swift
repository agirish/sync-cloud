//
//  OneWaySyncWriters.swift
//  SyncCloud
//

import Darwin
import Foundation

// MARK: - One process writes

/// Why this process may not sync at all: it is a test runner, or a copy of SyncCloud outside
/// /Applications (a build in DerivedData, a worktree's copy, a translocated download). Only the
/// installed app syncs, so a second copy can never write beside it.
public enum OneWaySyncLaunchRefusal: Equatable, Sendable {
    case testRunner
    case outsideApplications(bundlePath: String)
}

public enum OneWaySyncLaunchGate {

    /// The refusal for the running process, or nil when it may sync.
    public static func refusalForThisProcess() -> OneWaySyncLaunchRefusal? {
        refusal(
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            executable: URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent,
            environment: ProcessInfo.processInfo.environment,
            xcTestLoaded: NSClassFromString("XCTestCase") != nil)
    }

    /// Pure, for the tests. The test-runner markers are the ones `Logger` and `SyncHistoryStore`
    /// read: `swift test` runs inside `swiftpm-testing-helper`, XCTest inside `xctest`, and Xcode
    /// sets the XCTest* environment in a test host that is the app itself.
    public static func refusal(
        bundlePath: String, executable: String, environment: [String: String], xcTestLoaded: Bool
    ) -> OneWaySyncLaunchRefusal? {
        let testMarkers = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath"]
        if executable == "swiftpm-testing-helper" || executable == "xctest" || xcTestLoaded
            || testMarkers.contains(where: { environment[$0] != nil }) {
            return .testRunner
        }
        let bundle = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard bundle.pathExtension == "app",
              bundle.deletingLastPathComponent().path.lowercased() == "/applications" else {
            return .outsideApplications(bundlePath: bundlePath)
        }
        return nil
    }
}

/// The lock only one process holds while it may sync: `sync.lock` in Application Support, held
/// with `flock`. The kernel lets it go when the process ends however it ends, so a crash never
/// leaves a stale lock to clear by hand. The holder's PID is written in it, for the log.
public final class OneWaySyncProcessLock: @unchecked Sendable {
    public enum Refusal: Error, Equatable, Sendable {
        /// Another process holds it; its PID, when it could be read.
        case heldByAnotherProcess(pid: Int32?)
        case cannotOpen(errno: Int32)
    }

    public let url: URL
    private var fd: Int32
    private let lock = NSLock()

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    /// Takes the lock at `url`, or says who holds it. Never waits.
    public static func acquire(at url: URL) -> Result<OneWaySyncProcessLock, Refusal> {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failure(.cannotOpen(errno: errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            var bytes = [UInt8](repeating: 0, count: 32)
            let count = pread(fd, &bytes, bytes.count, 0)
            close(fd)
            guard code == EWOULDBLOCK else { return .failure(.cannotOpen(errno: code)) }
            let text = count > 0 ? String(decoding: bytes[0..<count], as: UTF8.self) : ""
            return .failure(.heldByAnotherProcess(pid: Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return .success(OneWaySyncProcessLock(url: url, fd: fd))
    }

    /// Lets it go. Also done when the lock is freed or the process ends.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

// MARK: - One Mac writes

/// The marker in Dropbox that says which Mac syncs: its hardware ID and its last sync. Every Mac
/// signed in to the same Dropbox sees it, so a second Mac set up for the same sync finds it isn't
/// the one. Checked before every sync and once Dropbox has caught up after a wake.
public struct OneWaySyncMacMarker: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// `IOPlatformUUID`, as in the record's binding.
    public var hardwareID: String
    /// The Mac's name when it took the sync, for *Sync From This Mac Instead…*'s confirmation.
    public var macName: String
    /// When it took the sync, in seconds.
    public var claimedAt: Int64
    /// Its last sync, in seconds; nil before its first finishes.
    public var lastSyncAt: Int64?

    public init(version: Int = OneWaySyncMacMarker.currentVersion, hardwareID: String, macName: String,
                claimedAt: Int64, lastSyncAt: Int64? = nil) {
        self.version = version
        self.hardwareID = hardwareID
        self.macName = macName
        self.claimedAt = claimedAt
        self.lastSyncAt = lastSyncAt
    }
}

public enum OneWaySyncMarkerCheck: Equatable, Sendable {
    case thisMac(OneWaySyncMacMarker)
    /// Another Mac syncs: this one stops, closes its rows, and offers *Sync From This Mac
    /// Instead…*, showing that Mac's last sync.
    case otherMac(OneWaySyncMacMarker)
    /// Dropbox made a conflicted copy of the marker: two Macs both claim the sync, and every Mac
    /// stops until one takes it over. The copies' names, sorted.
    case conflicted([String])
    case missing
    /// There, but not a marker this build can read; it names no Mac this one can trust.
    case unreadable
    /// The folder or the file couldn't be read just now (Dropbox's folder gone, no access): it
    /// says nothing about which Mac syncs, and the sync waits rather than asking for a first run.
    case cannotRead
}

/// The marker file, in the folder the caller names (the Dropbox parent). A dot file, so neither
/// Finder nor the panes list it, and outside every synced folder, so the sync never copies or
/// removes it. Its name doesn't start `.SyncCloud-`, the temporary files' prefix, so a sweep of
/// those never takes it.
public struct OneWaySyncMarkerFile: Sendable {
    public static let fileName = ".SyncCloud One-Way Sync.json"
    static let stem = ".SyncCloud One-Way Sync"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var url: URL { folder.appendingPathComponent(Self.fileName) }

    /// Which Mac the marker names. A conflicted copy beside it outranks the marker itself.
    public func check(hardwareID: String) -> OneWaySyncMarkerCheck {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return .cannotRead }
        let conflicted = Self.conflictedCopies(in: names)
        if !conflicted.isEmpty { return .conflicted(conflicted) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return (error as? CocoaError)?.code == .fileReadNoSuchFile ? .missing : .cannotRead
        }
        struct Header: Decodable { var version: Int }
        guard (try? JSONDecoder().decode(Header.self, from: data))?.version == OneWaySyncMacMarker.currentVersion,
              let marker = try? JSONDecoder().decode(OneWaySyncMacMarker.self, from: data),
              !marker.hardwareID.isEmpty else { return .unreadable }
        return !hardwareID.isEmpty && marker.hardwareID == hardwareID ? .thisMac(marker) : .otherMac(marker)
    }

    /// Writes `marker`, replacing the file in one step so Dropbox uploads only a whole one.
    public func write(_ marker: OneWaySyncMacMarker) throws {
        try OneWaySyncFiles.writeDurably(OneWaySyncStore.encode(marker), to: url)
    }

    /// *Sync From This Mac Instead…*: this Mac's marker, and the conflicted copies gone.
    public func claim(_ marker: OneWaySyncMacMarker) throws {
        try write(marker)
        for name in conflictedCopies() { try OneWaySyncFiles.remove(folder.appendingPathComponent(name)) }
    }

    /// Turn Off One-Way Sync.
    public func remove() throws {
        try OneWaySyncFiles.remove(url)
    }

    /// Files beside the marker that Dropbox made from it: its name followed by a conflict note,
    /// "(Mac’s conflicted copy 2026-10-30)" or "(Case Conflict)". Matched on "conflict" in any
    /// case rather than one spelling, which Dropbox has changed before.
    func conflictedCopies() -> [String] {
        Self.conflictedCopies(in: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    static func conflictedCopies(in names: [String]) -> [String] {
        names.filter { name in
            name != Self.fileName && name.hasPrefix(Self.stem) && name.lowercased().contains("conflict")
        }.sorted()
    }
}

// MARK: - Starting a sync

/// Whether a sync may start, from everything saved: the process, the lock, the record and the
/// marker. The first that stops it wins, in that order.
public enum OneWaySyncStartCheck: Equatable, Sendable {
    case ready(OneWaySyncRecord, firstRun: UUID, state: OneWaySyncSavedState)
    /// Never syncs from this process, and raises no row: it isn't the app the user runs.
    case refused(OneWaySyncLaunchRefusal)
    /// Another SyncCloud on this Mac holds the lock.
    case anotherProcessSyncs(pid: Int32?)
    /// The lock file couldn't be opened or locked (Application Support unwritable, say).
    case lockUnavailable(errno: Int32)
    /// *Needs a new first run*. Never run on its own: the user starts it from *Review First Run…*.
    case needsNewFirstRun(OneWaySyncNewFirstRunReason)
    /// *Synced by another Mac*.
    case otherMacSyncs(OneWaySyncMacMarker)
    /// *Two Macs both claim this sync*.
    case twoMacsClaim([String])
    /// A value of the binding couldn't be read on this Mac just now (iCloud signed out): the
    /// whole sync waits with that row.
    case cannotConfirm(OneWaySyncNewFirstRunReason)
    /// Dropbox's marker couldn't be read just now: the whole sync waits and retries.
    case markerUnavailable

    /// Pure, for the tests: `lock` is the result of taking the lock, which the caller keeps for
    /// as long as it syncs.
    public static func evaluate(
        refusal: OneWaySyncLaunchRefusal?, lock: Result<OneWaySyncProcessLock, OneWaySyncProcessLock.Refusal>,
        record: OneWaySyncSavedRecord, marker: OneWaySyncMarkerCheck
    ) -> OneWaySyncStartCheck {
        if let refusal { return .refused(refusal) }
        switch lock {
        case .failure(.heldByAnotherProcess(let pid)): return .anotherProcessSyncs(pid: pid)
        case .failure(.cannotOpen(let code)): return .lockUnavailable(errno: code)
        case .success: break
        }
        // Another Mac's claim outranks this Mac's record: whatever this Mac has saved, it is not
        // the one that syncs, and its own record mismatching would only bury that.
        switch marker {
        case .conflicted(let names): return .twoMacsClaim(names)
        case .otherMac(let other): return .otherMacSyncs(other)
        case .cannotRead: return .markerUnavailable
        case .thisMac, .missing, .unreadable: break
        }
        let saved: OneWaySyncRecord, firstRun: UUID, state: OneWaySyncSavedState
        switch record {
        case .ready(let r, let f, let s): (saved, firstRun, state) = (r, f, s)
        case .needsNewFirstRun(let reason): return .needsNewFirstRun(reason)
        case .cannotConfirm(let reason): return .cannotConfirm(reason)
        }
        switch marker {
        case .thisMac: return .ready(saved, firstRun: firstRun, state: state)
        case .missing: return .needsNewFirstRun(.noMarker)
        default: return .needsNewFirstRun(.unreadable)
        }
    }
}
