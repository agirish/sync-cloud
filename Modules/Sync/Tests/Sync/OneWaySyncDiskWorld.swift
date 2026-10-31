import Darwin
import Foundation
@testable import Sync

/// A scratch iCloud parent, Dropbox account and staging folder for RD67's file-writing tests,
/// under a temp root of its own: no test touches the real iCloud or Dropbox.
///
/// Dropbox files are written with the tracking flag (`UF_TRACKED`) set, as Dropbox sets it on
/// every file, so they carry a document ID the tests can follow through a replace.
struct OneWayDiskWorld {
    /// 2026-10-30 12:00 UTC.
    static let day0 = Date(timeIntervalSince1970: 1_793_361_600)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    let root: URL
    let iCloud: URL
    let account: URL
    let dropbox: URL
    let staging: URL

    init() throws {
        root = try makeCanonicalTempRoot(prefix: "OneWaySyncDisk")
        iCloud = root.appendingPathComponent("iCloud/Documents", isDirectory: true)
        account = root.appendingPathComponent("Dropbox", isDirectory: true)
        dropbox = account.appendingPathComponent("Documents", isDirectory: true)
        staging = root.appendingPathComponent("Staging", isDirectory: true)
        for folder in [iCloud, dropbox] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    var places: OneWaySyncPlaces {
        OneWaySyncPlaces(iCloudParent: iCloud, dropboxParent: dropbox, dropboxAccountFolder: account, staging: staging)
    }

    func writer(at now: Date = day0) throws -> OneWaySyncWriter {
        let writer = try OneWaySyncWriter(places: places, calendar: Self.calendar)
        writer.now = { now }
        writer.coordinationDeadline = 10
        return writer
    }

    func base(_ side: OneWaySyncSide) -> URL { side == .iCloud ? iCloud : dropbox }

    @discardableResult
    func write(_ side: OneWaySyncSide, _ path: String, _ contents: String, modified: Date? = nil) throws -> URL {
        let url = base(side).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        if side == .dropbox { precondition(chflags(url.path, UInt32(UF_TRACKED)) == 0) }
        return url
    }

    func read(_ side: OneWaySyncSide, _ path: String) -> String? {
        (try? Data(contentsOf: base(side).appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func read(account path: String) -> String? {
        (try? Data(contentsOf: account.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func documentID(_ side: OneWaySyncSide, _ path: String) -> UInt64? {
        OneWaySyncDisk.documentID(at: base(side).appendingPathComponent(path).path)
    }

    func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// Every path below the Dropbox account folder, sorted.
    var everythingInDropbox: [String] {
        ((FileManager.default.enumerator(atPath: account.path)?.allObjects as? [String]) ?? []).sorted()
    }

    var stagingContents: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }

    /// What the diff would have seen of a Dropbox file now.
    func expected(_ path: String) throws -> OneWaySyncExpectedState {
        let url = dropbox.appendingPathComponent(path)
        let state = try OneWaySyncDisk.state(at: url.path)
        return OneWaySyncExpectedState(size: state.size, modified: state.modifiedSecond, documentID: OneWaySyncDisk.documentID(at: url.path))
    }

    /// Clears every lock flag a test set, then removes the root.
    func remove() {
        OneWaySyncDisk.forEachItem(root.path) { path in
            var info = stat()
            if lstat(path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}
