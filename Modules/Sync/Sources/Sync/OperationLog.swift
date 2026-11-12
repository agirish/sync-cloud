import Foundation

/// The start and finish lines of a bulk sync, built apart from the run so tests read their real
/// text (`OperationLogTests`, `LogGroupingTests`).
///
/// Every run that passes its guards and its confirmation writes both, and so does a run with every
/// row held for a decision. The finish line counts every row the run was offered, so a run whose
/// items all failed still says what happened, and the run ID is the one its Sync History records
/// carry. Neither line starts with `"Synced file: "`, the Activity Log's fold key for one file.
public enum BulkRunLog {
    /// What a finished run did with each row it was offered.
    public struct Counts: Equatable, Sendable {
        public var done = 0
        public var failed = 0
        public var held = 0
        public var skipped = 0
        public var canceled = 0

        public init(done: Int = 0, failed: Int = 0, held: Int = 0, skipped: Int = 0, canceled: Int = 0) {
            self.done = done
            self.failed = failed
            self.held = held
            self.skipped = skipped
            self.canceled = canceled
        }
    }

    static func noun(_ isMove: Bool) -> String { isMove ? "Bulk move" : "Bulk sync" }

    public static func start(runId: UUID, isMove: Bool, items: Int, bytes: Int64?, from: String, to: String) -> String {
        "\(noun(isMove)) \(runId.uuidString) started: \(items) item(s)"
            + (bytes.map { ", \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "")
            + ", \(from) → \(to)"
    }

    public static func finish(runId: UUID, isMove: Bool, counts: Counts, elapsed: String) -> String {
        var parts = ["\(counts.done) \(isMove ? "moved" : "copied")"]
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if counts.held > 0 { parts.append("\(counts.held) held for a decision") }
        if counts.skipped > 0 { parts.append("\(counts.skipped) skipped") }
        if counts.canceled > 0 { parts.append("\(counts.canceled) not reached (canceled)") }
        return "\(noun(isMove)) \(runId.uuidString) finished (\(elapsed)): " + parts.joined(separator: ", ")
    }

    /// A run offered only rows held for a decision: nothing started, but the log still says so.
    public static func allHeld(isMove: Bool, held: Int) -> String {
        "\(noun(isMove)): nothing to \(isMove ? "move" : "copy") — \(held) item(s) held for a decision"
    }
}

/// Verify All's finish line: every pair it was asked about, sorted into what the hash said.
public enum VerifyAllLog {
    public static func finish(identical: Int, differed: Int, skipped: Int, of total: Int,
                              canceled: Bool, elapsed: String) -> String {
        let reached = identical + differed + skipped
        var parts = ["\(identical) identical", "\(differed) differed", "\(skipped) couldn’t be verified"]
        if canceled, reached < total { parts.append("\(total - reached) not reached") }
        return "Verify All \(canceled ? "canceled" : "finished") (\(elapsed)): " + parts.joined(separator: ", ")
            + " of \(total) pair(s)"
    }
}

/// A list of names for one log line, split so no line is long: every name kept, sorted, at most
/// ``perLine`` a line, each continuation saying which slice it is. One physical line each.
public enum LogNames {
    public static let perLine = 200
    /// A line also stops at about this many bytes of names, so 200 long paths stay readable.
    public static let bytesPerLine = 16 * 1024

    public static func lines(_ prefix: String, _ names: [String]) -> [String] {
        let sorted = names.sorted()
        // Slices by count and size: a new slice starts at 200 names or 16 KB, whichever comes first.
        var slices: [Range<Int>] = []
        var start = 0, bytes = 0
        for (i, name) in sorted.enumerated() {
            if i > start, i - start >= perLine || bytes + name.utf8.count + 2 > bytesPerLine {
                slices.append(start..<i); start = i; bytes = 0
            }
            bytes += name.utf8.count + 2
        }
        if start < sorted.count { slices.append(start..<sorted.count) }
        guard slices.count > 1 else { return sorted.isEmpty ? [] : ["\(prefix): " + sorted.joined(separator: ", ")] }
        return slices.map { r in
            "\(prefix) \(r.lowerBound + 1)–\(r.upperBound) of \(sorted.count): " + sorted[r].joined(separator: ", ")
        }
    }
}

/// An error as a log line writes it. A system error (Cocoa, POSIX, OSStatus, URL, Mach) gives its
/// domain, code and message, plus its underlying error's domain and code, which for the Cocoa
/// file codes 512 and 256 is where the real cause is: not `String(describing:)`, which prints the
/// whole userInfo, paths and all. The app's own errors are Swift values whose description is
/// their reason (`FilingProfileStore.WriteRefusal`), so those keep `String(describing:)`. Every
/// Swift error bridges to an NSError, so the test is the bridged domain, not the type.
public enum LogError {
    static let systemDomains: Set<String> = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                                             NSURLErrorDomain, NSMachErrorDomain]

    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard systemDomains.contains(ns.domain) else { return String(describing: error) }
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return text
    }
}

extension LogError {
    /// What puts two failures in one group of a grouped log line: never the description, which
    /// names the file. The bridged domain and code; the app's own error's case name (without its
    /// payload) or a `SyncError`'s title, since every `SyncError` bridges to one domain and code;
    /// and for Cocoa's catch-all file codes (256, 512), the underlying error that holds the cause.
    public static func groupKey(_ error: Error) -> String {
        let ns = error as NSError
        var key = "\(ns.domain) \(ns.code)"
        if let sync = error as? SyncError {
            key += " \(sync.title)"
        } else if !systemDomains.contains(ns.domain) {
            let described = String(describing: error)
            key += " " + String(described.prefix(while: { $0 != "(" && $0 != ":" }))
        }
        if ns.domain == NSCocoaErrorDomain, [256, 512].contains(ns.code),
           let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            key += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return key
    }

    /// The domain and code of an error and of each error beneath it, outermost first: the codes,
    /// not the sentence, so a TCC denial, a deny-delete ACL and a read-only mount, which all say
    /// "you don't have permission", tell apart. Bounded, so a cyclic chain can't spin.
    public static func codeChain(_ error: Error) -> String {
        var parts: [String] = []
        var current = error as NSError
        for _ in 0...4 {
            parts.append("\(current.domain) \(current.code)")
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return parts.joined(separator: " ← ")
    }

    /// The group's reason, from the code, never the description: a POSIX code's own words where
    /// there is one, else the error's failure reason, else its key.
    public static func groupReason(_ error: Error) -> String {
        let ns = error as NSError
        let posix = (ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError)
            .flatMap { $0.domain == NSPOSIXErrorDomain ? String(cString: strerror(Int32($0.code))) : nil }
        if let posix { return posix }
        if let sync = error as? SyncError { return sync.title }
        if let reason = ns.localizedFailureReason, !reason.isEmpty { return reason }
        return groupKey(error)
    }
}

/// A run's failed items as grouped lines: one ERROR line per kind of failure with its count, its
/// reason and the first item's full description (a provider's own words can't be rebuilt from a
/// code), then every name in the group (``LogNames``). Groups and names sorted, so runs compare.
/// A failure that carries the system error it wraps (``ItemError/cause``) is keyed by that error's
/// codes too, so refusals with different codes beneath one app error are separate groups.
public enum GroupedFailureLog {
    public static func lines(_ operation: String, _ failures: [(name: String, error: Error)]) -> [String] {
        lines(operation, failures.map { ItemError(name: $0.name, $0.error) })
    }

    public static func lines(_ operation: String, _ failures: [ItemError]) -> [String] {
        let groups = Dictionary(grouping: failures, by: { failure in
            LogError.groupKey(failure.error) + (failure.cause.map { " ← " + LogError.codeChain($0) } ?? "")
        })
        var out: [String] = []
        for key in groups.keys.sorted() {
            // Sorted by name, so the first item is the same whatever order the workers finished in.
            let group = (groups[key] ?? []).sorted { $0.name < $1.name }
            guard let first = group.first else { continue }
            out.append("\(operation): \(group.count) item(s) failed — \(LogError.groupReason(first.error)) [\(key)]; "
                       + "first: \(first.name): \(fullDescription(first.error))")
            out += LogNames.lines("\(operation): failed (\(LogError.groupReason(first.error)))", group.map(\.name))
        }
        return out
    }

    /// An error's own words: a `SyncError` isn't a `LocalizedError`, so its localized description
    /// is the generic "couldn’t be completed", and its log description carries the reason.
    static func fullDescription(_ error: Error) -> String {
        (error as? SyncError)?.logDescription ?? error.localizedDescription
    }
}

/// One item's failure in a batch: the error, and the item it happened to, so a grouped log line
/// can name it. A failure of the whole batch (a destination root that's gone) is named by that root.
public struct ItemError: Sendable {
    public let name: String
    public let error: Error
    /// The system error `error` replaced, when it wraps one in the app's own words (a Trash
    /// refusal as `SyncError.trashNotPermitted`): its codes are the cause, and the wrapper keeps
    /// none of them.
    public let cause: Error?

    public init(_ url: URL, _ error: Error, cause: Error? = nil) {
        self.name = url.path
        self.error = error
        self.cause = cause
    }

    public init(name: String, _ error: Error, cause: Error? = nil) {
        self.name = name
        self.error = error
        self.cause = cause
    }
}

/// A Filing scan's allowance of per-file read warnings (an OCR that failed, an unreadable image).
/// When the Neural Engine refuses machine-wide, every image in a scan fails the same way, so the
/// first ``allowed`` each get their own line and every file past them is named, sorted, in lines
/// of at most 200 when the scan ends. No name is dropped. Bound per scan as a task-local, and read
/// before any hop to a dispatch queue, where a task-local isn't visible.
public final class FilingWarningBudget: @unchecked Sendable {
    @TaskLocal public static var current: FilingWarningBudget?
    public static let allowed = 20

    private let lock = NSLock()
    private var admitted = 0
    private var overflow: [String] = []

    public init() {}

    /// Whether `name`'s warning gets its own line; past the allowance it is kept for the end.
    public func admit(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard admitted >= Self.allowed else { admitted += 1; return true }
        overflow.append(name)
        return false
    }

    public func overflowLines() -> [String] {
        lock.lock(); let names = overflow; lock.unlock()
        return LogNames.lines("Filing: \(names.count) more file(s) couldn’t be read this scan, past the first "
                              + "\(Self.allowed) logged above", names)
    }
}
