import Darwin
import Foundation

/// What a copy can be asked while its bytes move: whether to keep going, and how far it has got.
///
/// `FileManager.copyItem` can't be interrupted, so a large file or folder would run to the end
/// once started. A copy handed an observer checks `shouldContinue` per chunk and per entry; `false`
/// abandons it, removes what it wrote, and throws `CocoaError(.userCancelled)`. Callers copy only
/// into a `.tmp_` staging name, so an abandoned copy never touches the destination.
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

    /// True when `error` is the abandonment this observer asked for: not a failure, never an alert.
    public static func isCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }
}

extension FileManager {
    /// `copyItem(at:to:)` through `copyfile(3)`, with a progress callback that can stop it mid-file.
    ///
    /// Matches `copyItem` on modes, flags, links, owners, xattrs, ACLs and times, with one fix:
    /// `copyfile` leaves a folder's mtime at copy time whenever the folder holds a symlink, so folder
    /// times are re-applied from the source once the tree is down. `COPYFILE_CLONE` keeps the
    /// same-volume APFS clone; a clone writes no data, so it is instant and never cancelled mid-file.
    ///
    /// Other failures retry through `copyItem` after removing this copy's output, so the alert shows
    /// Foundation's usual error rather than a bare POSIX code. Out-of-space is thrown directly: a
    /// retry would fill the disk again first.
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
    /// The observer a pane transfer hands its item's copy: stop when `progress` is cancelled and,
    /// once the item has copied for a second, show how far it has got on the dialog's item line.
    /// The second's grace keeps an ordinary batch from flickering: most items finish or clone first.
    nonisolated static func transferCopyObserver(progress: Progress, itemName: String, sourceURL: URL, fileManager: FileManaging) -> CopyObserver {
        // The total is read once, only when the line is first shown, to spare a stat per item on a
        // slow provider. Folders have no cheap total, so they report bytes copied without an "of"
        // rather than an invented estimate.
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
    /// The estimate waits for three seconds of rate, since one from the first chunk is noise, and is
    /// left off when there is no total.
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
