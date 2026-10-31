//
//  OneWaySyncFiles.swift
//  SyncCloud
//

import Darwin
import Foundation

/// How RD67's saved state reaches the disk: whole files, replaced in one step, and on the disk
/// itself before the call returns.
///
/// `Data.write(options: .atomic)` replaces a file in one step but leaves the bytes in the drive's
/// cache, so a power cut can leave the new name pointing at nothing. A History entry is written
/// before any action is applied precisely so a crash can be recovered from, so it must survive
/// one: each write here is flushed with `F_FULLFSYNC` before the rename, and the folder after it.
enum OneWaySyncFiles {

    struct WriteError: Error, CustomStringConvertible {
        var step: String
        var path: String
        var code: Int32
        var description: String { "\(step) \(path): \(String(cString: strerror(code)))" }
    }

    /// Writes `data` to `url` through a temporary file in the same folder, flushed, then renamed
    /// over the old file. Creates the folder when it is missing. Either the old file or the whole
    /// new one is there afterwards, never part of either.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The sync's own temporary prefix: the lister skips it, and a sweep of SyncCloud's
        // temporary files takes one a crash left behind, in Dropbox too (the marker).
        let temp = folder.appendingPathComponent("\(OneWaySyncPlanner.temporaryNamePrefix)\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError(step: "open", path: temp.path, code: errno) }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(temp.path)   // a no-op once the rename went through
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let wrote = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw WriteError(step: "write", path: temp.path, code: errno)
                }
                offset += wrote
            }
        }
        try flush(fd, path: temp.path)
        closed = true
        guard close(fd) == 0 else { throw WriteError(step: "close", path: temp.path, code: errno) }
        guard rename(temp.path, url.path) == 0 else { throw WriteError(step: "rename", path: url.path, code: errno) }
        syncFolder(folder)
    }

    /// Appends one line to `url`, creating it, and flushes it. Used for a History entry's ticks:
    /// a crash mid-line leaves a torn last line, which the reader skips.
    static func appendLine(_ line: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError(step: "open", path: url.path, code: errno) }
        defer { close(fd) }
        var bytes = line
        bytes.append(0x0A)
        // A crash mid-line left no newline: start on a line of our own, or this line would join
        // the torn one and be skipped with it.
        var stats = stat()
        var last: UInt8 = 0x0A
        if fstat(fd, &stats) == 0, stats.st_size > 0, pread(fd, &last, 1, stats.st_size - 1) == 1, last != 0x0A {
            bytes.insert(0x0A, at: 0)
        }
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let wrote = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw WriteError(step: "write", path: url.path, code: errno)
                }
                offset += wrote
            }
        }
        // A tick is advice, not the recovery itself: after a crash, anything not ticked is
        // compared as usual. So the ordinary flush, not `F_FULLFSYNC`, which costs milliseconds
        // a step on a run of thousands.
        guard fsync(fd) == 0 else { throw WriteError(step: "fsync", path: url.path, code: errno) }
    }

    /// Removes `url`; a file already gone is not an error.
    static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw WriteError(step: "unlink", path: url.path, code: errno)
        }
    }

    private static func flush(_ fd: Int32, path: String) throws {
        // `F_FULLFSYNC` asks the drive to empty its cache too; a file system that can't (some
        // network or FUSE volumes) refuses it, and the ordinary flush is the best there is.
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw WriteError(step: "fsync", path: path, code: errno) }
    }

    private static func syncFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        close(fd)
    }
}
