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

    public static func lines(_ prefix: String, _ names: [String]) -> [String] {
        let sorted = names.sorted()
        guard sorted.count > perLine else { return sorted.isEmpty ? [] : ["\(prefix): " + sorted.joined(separator: ", ")] }
        return stride(from: 0, to: sorted.count, by: perLine).map { start in
            let end = min(start + perLine, sorted.count)
            return "\(prefix) \(start + 1)–\(end) of \(sorted.count): " + sorted[start..<end].joined(separator: ", ")
        }
    }
}
