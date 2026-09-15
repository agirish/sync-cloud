import Darwin
import Foundation

/// What a copy can be asked while its bytes move: whether to keep going, and how far it has got.
///
/// **Why this exists (RD24).** `FileManager.copyItem` cannot be interrupted, so cancellation was
/// observed only between items — one 12 GB file, or one large folder, ran to the end once started.
/// A copy handed an observer checks `shouldContinue` per chunk and per entry instead; a `false`
/// abandons the copy, removes what it had written, and throws `CocoaError(.userCancelled)`. The
/// callers only ever copy into a `.tmp_` staging name, so an abandoned copy never touches the
/// destination: the atomicity guarantee is the staging file's, and it is unchanged.
public struct CopyObserver: Sendable {
    /// Polled per data chunk and per tree entry. Return false to abandon the copy.
    public let shouldContinue: @Sendable () -> Bool
    /// Cumulative bytes of file data written so far by this copy. Called from the copying thread;
    /// clones (instant on APFS) write no data and report nothing.
    public let bytesCopied: @Sendable (Int64) -> Void

    public init(shouldContinue: @escaping @Sendable () -> Bool, bytesCopied: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.shouldContinue = shouldContinue
        self.bytesCopied = bytesCopied
    }

    /// True when `error` is the abandonment this observer asked for — not a failure, and never
    /// something to put in an alert.
    public static func isCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }
}

extension FileManager {
    /// `copyItem(at:to:)` through `copyfile(3)`, with a progress callback that can stop it mid-file.
    ///
    /// **Measured equivalent to `copyItem` on 2026-09-15**, on a fixture holding an xattr, a Finder
    /// tag, a 0600 file with a 2020 mtime, a relative and a dangling symlink, a hard link, an ACL, a
    /// `hidden`-flagged folder, a package, an empty folder, a dotfile and a 300 MB file: every entry's
    /// mode, flags, size, link count, owner, symlink target, xattrs, ACL, birth time and mtime to the
    /// nanosecond compared equal, root included — with ONE correction applied below, without which
    /// they did not. `copyfile`'s recursive copy leaves a folder's mtime at the time of the copy
    /// whenever that folder holds a symlink (reproduced alone: one symlink in one folder), where
    /// `copyItem` preserves it. So folder times are re-applied from the source once the tree is down.
    ///
    /// `COPYFILE_CLONE` keeps the same-volume APFS clone `copyItem` makes; a clone writes no data, so
    /// it is also never observed mid-file — it is instant, and there is nothing to cancel.
    ///
    /// Failures other than cancellation go back through `copyItem` itself, after removing what this
    /// copy wrote, so the error an alert shows is the one it always showed ("…couldn't be copied
    /// because you don't have permission…"), not a bare POSIX code. Out-of-space is the exception: a
    /// second attempt would fill the disk again before failing the same way, so it is thrown directly.
    func observedCopyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver, allowClone: Bool = true) throws {
        // An occupied destination is copyItem's own error to raise, and the cleanup below must never
        // be able to remove something this copy did not write.
        guard !fileExists(atPath: dstURL.path) else {
            try copyItem(at: srcURL, to: dstURL)
            return
        }
        guard observer.shouldContinue() else { throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: srcURL.path]) }
        guard let state = copyfile_state_alloc() else {
            try copyItem(at: srcURL, to: dstURL)
            return
        }
        defer { copyfile_state_free(state) }

        let context = ObservedCopyContext(observer: observer)
        let callback: copyfile_callback_t = { what, stage, state, src, dst, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let context = Unmanaged<ObservedCopyContext>.fromOpaque(ctx).takeUnretainedValue()
            if stage == COPYFILE_ERR { return COPYFILE_QUIT }
            if !context.observer.shouldContinue() {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            switch (what, stage) {
            case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    context.observer.bytesCopied(context.finishedFileBytes + Int64(copied))
                }
            case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    context.finishedFileBytes += Int64(copied)
                }
            case (COPYFILE_RECURSE_DIR_CLEANUP, COPYFILE_FINISH):
                if let src, let dst {
                    context.directories.append((String(cString: src), String(cString: dst)))
                }
            default:
                break
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())

        var flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        if allowClone { flags |= COPYFILE_CLONE }
        let result = srcURL.withUnsafeFileSystemRepresentation { src in
            dstURL.withUnsafeFileSystemRepresentation { dst in
                copyfile(src, dst, state, copyfile_flags_t(flags))
            }
        }
        let failure = errno

        if result == 0 {
            for (src, dst) in context.directories {
                var st = stat()
                guard lstat(src, &st) == 0 else { continue }
                var times = [st.st_atimespec, st.st_mtimespec]
                _ = utimensat(AT_FDCWD, dst, &times, AT_SYMLINK_NOFOLLOW)
            }
            return
        }

        // Nothing at the destination was there before this call (guarded above), so whatever is
        // there now is this copy's partial output.
        if fileExists(atPath: dstURL.path) || (try? destinationOfSymbolicLink(atPath: dstURL.path)) != nil {
            try? removeItem(at: dstURL)
        }
        if context.cancelled || failure == ECANCELED {
            throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: srcURL.path])
        }
        if failure == ENOSPC || failure == EDQUOT {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [
                NSFilePathErrorKey: dstURL.path,
                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: failure) ?? .ENOSPC),
            ])
        }
        // The retry cannot be interrupted, so a Cancel pressed while this copy was failing ends it
        // here rather than starting an unobserved second attempt.
        guard observer.shouldContinue() else { throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: srcURL.path]) }
        try copyItem(at: srcURL, to: dstURL)
    }
}

/// The callback's context. Only ever touched from the thread running `copyfile`.
private final class ObservedCopyContext {
    let observer: CopyObserver
    var cancelled = false
    var finishedFileBytes: Int64 = 0
    var directories: [(src: String, dst: String)] = []
    init(observer: CopyObserver) { self.observer = observer }
}

extension FileSyncManager {
    /// The observer a pane transfer hands its item's copy: stop when `progress` is cancelled, and —
    /// once the item has been copying for a second — say how far it has got on the dialog's item
    /// line, where the name alone used to sit unchanged for the whole of a 12 GB file.
    ///
    /// The second's grace is what keeps an ordinary batch looking exactly as it did: most items
    /// finish (or clone, which reports no bytes at all) well inside it, so their line never flickers.
    nonisolated static func transferCopyObserver(progress: Progress, itemName: String, sourceURL: URL, fileManager: FileManaging) -> CopyObserver {
        // The total is read once, and only when the line is first shown: most items never reach a
        // second, and a stat per item on a slow provider is a cost for a line nobody sees. Folders
        // have no cheap total, and a guessed one would make the estimate a number the app invented;
        // they report bytes copied without an "of".
        let clock = ByteProgressClock()
        return CopyObserver(
            shouldContinue: { !progress.isCancelled },
            bytesCopied: { copied in
                guard let elapsed = clock.admit() else { return }
                let totalBytes = clock.total {
                    guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
                          attributes[.type] as? FileAttributeType != .typeDirectory else { return nil }
                    return (attributes[.size] as? NSNumber)?.int64Value
                }
                let text = byteProgressText(itemName: itemName, copied: copied, total: totalBytes, elapsed: elapsed)
                DispatchQueue.main.async { progress.localizedAdditionalDescription = text }
            }
        )
    }

    /// "Archive 2019.zip — 4.2 GB of 12.8 GB · about 3 min left". Pure so the wording is testable.
    /// The estimate waits for three seconds of rate — an estimate from the first chunk is noise —
    /// and is left off entirely when there is no total to estimate against.
    nonisolated static func byteProgressText(itemName: String, copied: Int64, total: Int64?, elapsed: TimeInterval) -> String {
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        guard let total, total > 0 else { return "\(itemName) — \(format(copied)) copied" }
        let shown = min(copied, total)
        var text = "\(itemName) — \(format(shown)) of \(format(total))"
        if elapsed >= 3, shown > 0 {
            let remaining = Double(total - shown) / (Double(shown) / elapsed)
            text += " · " + remainingText(seconds: remaining)
        }
        return text
    }

    nonisolated static func remainingText(seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "about \(minutes) min left" }
        return "about \(Int((seconds / 3600).rounded())) hr left"
    }
}

/// Gates the byte line: nothing for the first second of an item, then at most four updates a second.
private final class ByteProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var lastPublished: Date?
    private var resolvedTotal: Int64??

    /// The item's total size, computed by `read` the first time it is asked for.
    func total(_ read: () -> Int64?) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        if let resolvedTotal { return resolvedTotal }
        let value = read()
        resolvedTotal = .some(value)
        return value
    }

    /// Elapsed seconds when this update should be shown, nil when it should be dropped.
    func admit() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 1 else { return nil }
        if let lastPublished, now.timeIntervalSince(lastPublished) < 0.25 { return nil }
        lastPublished = now
        return elapsed
    }
}
