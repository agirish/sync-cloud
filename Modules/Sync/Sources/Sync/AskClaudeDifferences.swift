import Foundation

/// Compare's differences as Ask Claude reads them: a line on the screen card, and the
/// `differences` tool's rows. Pure, so the counting, grouping and paging are tested without a scan.
///
/// The list Claude reads is the list on screen: `FileSyncManager.differences`, after the ignore
/// rules, hidden files and checksum-identical pairs are taken out. A row with either side in a
/// folder on the Never show Claude list is left out too, and counted.
public enum AskClaudeDifferences {

    /// What the tool can narrow to.
    public enum Kind: String, CaseIterable, Sendable {
        case all
        /// On the left side only (missing on the right).
        case onlyLeft = "only_left"
        /// On the right side only (missing on the left).
        case onlyRight = "only_right"
        /// On both sides, with different dates or sizes.
        case changed
        case nameConflicts = "name_conflicts"
        /// Rows no bulk run copies on its own, with the reason.
        case heldBack = "held_back"

        public func matches(_ row: FileDifference) -> Bool {
            switch self {
            case .all: return true
            case .onlyLeft: return row.type == .missingOnRight
            case .onlyRight: return row.type == .missingOnLeft
            case .changed: return row.type == .differentDates
            case .nameConflicts: return row.type == .nameConflict
            case .heldBack: return row.heldBack != nil
            }
        }
    }

    /// A kind in the sides' names, "only on Dropbox", for the steps the person reads; nil for all.
    public static func label(_ kind: Kind, comparison: Comparison) -> String? {
        switch kind {
        case .all: return nil
        case .onlyLeft: return "only on \(comparison.leftName)"
        case .onlyRight: return "only on \(comparison.rightName)"
        case .changed: return "changed"
        case .nameConflicts: return "name conflicts"
        case .heldBack: return "held back"
        }
    }

    /// The comparison the rows come from: its two sides and how fresh it is.
    public struct Comparison: Equatable, Sendable {
        public var leftName: String
        public var rightName: String
        /// Each side's compared folder, relative to its source; empty at the source's top.
        public var leftFolder: String
        public var rightFolder: String
        /// A compared folder on the Hidden from Claude list: its path isn't named.
        public var leftFolderHidden = false
        public var rightFolderHidden = false
        /// When the folders behind the rows were read; nil before the first scan.
        public var readAt: Date?
        public var isScanning: Bool
        public var hasScanned: Bool
        /// Why the comparison is partial ("Dropbox could be read only in part"), or nil.
        public var partial: String?

        public init(leftName: String, rightName: String, leftFolder: String, rightFolder: String,
                    readAt: Date?, isScanning: Bool, hasScanned: Bool, partial: String? = nil) {
            self.leftName = leftName
            self.rightName = rightName
            self.leftFolder = leftFolder
            self.rightFolder = rightFolder
            self.readAt = readAt
            self.isScanning = isScanning
            self.hasScanned = hasScanned
            self.partial = partial
        }

        /// Over an hour old, the age at which the list's own pill turns stale.
        public func isStale(now: Date) -> Bool {
            guard let readAt else { return true }
            return now.timeIntervalSince(readAt) > 3600
        }

        var sides: String {
            func side(_ name: String, _ folder: String, hidden: Bool) -> String {
                hidden ? "\(name) › (a folder hidden from Claude)" : folder.isEmpty ? name : "\(name) › \(folder)"
            }
            return "\(side(leftName, leftFolder, hidden: leftFolderHidden))  vs  \(side(rightName, rightFolder, hidden: rightFolderHidden))"
        }
    }

    /// Rows per call.
    public static let pageSize = 60

    /// The rows a call asks for: of `kind`, under `folder` (relative to the compared folders), and
    /// holding every word in their path. Words match case- and accent-insensitively.
    public static func filter(_ rows: [FileDifference], kind: Kind, folder: String?, words: [String]) -> [FileDifference] {
        let folder = folder?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).nonEmptyValue
        return rows.filter { row in
            guard kind.matches(row) else { return false }
            // Case is ignored, as the Mac's disk ignores it: "taxes" is the Taxes folder.
            if let folder, !Self.isAtOrUnder(row.relativePath, folder) { return false }
            return words.allSatisfy { row.relativePath.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func isAtOrUnder(_ path: String, _ folder: String) -> Bool {
        let path = path.lowercased(), folder = folder.lowercased()
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// The counts by kind, "9 only on Dropbox · 3 only on iCloud · 2 changed".
    public static func counts(_ rows: [FileDifference], comparison: Comparison) -> String {
        let onlyLeft = rows.filter { $0.type == .missingOnRight }.count
        let onlyRight = rows.filter { $0.type == .missingOnLeft }.count
        let changed = rows.filter { $0.type == .differentDates }.count
        let conflicts = rows.filter { $0.type == .nameConflict }.count
        var parts: [String] = []
        if onlyRight > 0 { parts.append("\(onlyRight) only on \(comparison.rightName)") }
        if onlyLeft > 0 { parts.append("\(onlyLeft) only on \(comparison.leftName)") }
        if changed > 0 { parts.append("\(changed) changed") }
        if conflicts > 0 { parts.append("\(conflicts) name conflict\(conflicts == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The screen card's line in Compare: enough to know the tool is worth calling.
    public static func summaryLine(_ rows: [FileDifference], hiddenCount: Int, comparison: Comparison, now: Date) -> String {
        if comparison.isScanning && !comparison.hasScanned { return "differences: scanning now" }
        guard comparison.hasScanned else { return "differences: not compared yet" }
        var parts = ["differences: \(rows.count)", "scanned \(age(comparison.readAt, now: now))"]
        let counts = counts(rows, comparison: comparison)
        if !counts.isEmpty { parts.append(counts) }
        if hiddenCount > 0 { parts.append("\(hiddenCount) hidden from Claude") }
        if comparison.isScanning { parts.append("a new scan is running") }
        if comparison.partial != nil { parts.append("partial") }
        return parts.joined(separator: " · ")
    }

    /// The tool's answer: the comparison, the counts, then the rows grouped by top-level folder,
    /// `pageSize` from `from`. Each row gets a handle on the side that has the item (the left
    /// when both do), so reveal and open work on it.
    public static func render(_ rows: [FileDifference], allRows: [FileDifference], hiddenCount: Int,
                              comparison: Comparison, from: Int, handles: inout AskClaudeHandles,
                              now: Date, timeZone: TimeZone = .current) -> String {
        var lines = ["differences: \(AskClaudeScreenCard.escape(comparison.sides))"]
        var facts = ["scanned \(age(comparison.readAt, now: now))", "\(allRows.count) difference\(allRows.count == 1 ? "" : "s")"]
        let all = counts(allRows, comparison: comparison)
        if !all.isEmpty { facts[1] += ": " + all }
        lines.append(facts.joined(separator: " · "))
        if let partial = comparison.partial { lines.append("partial: " + AskClaudeScreenCard.escape(partial)) }
        if hiddenCount > 0 { lines.append("\(hiddenCount) more hidden from Claude by them.") }
        guard !rows.isEmpty else {
            // "Match" only when nothing was left out: rows hidden from Claude, or a side read in
            // part, can still differ.
            if !allRows.isEmpty {
                lines.append("No differences match that.")
            } else if hiddenCount > 0 {
                lines.append("No differences besides the ones hidden from Claude.")
            } else if comparison.partial != nil {
                lines.append("No differences in what could be read; the comparison is partial.")
            } else {
                lines.append("No differences: the two sides match.")
            }
            return lines.joined(separator: "\n")
        }
        if rows.count != allRows.count { lines.append("matching: \(rows.count)") }
        lines.append("rows: handle|path|change|\(comparison.leftName) size|\(comparison.rightName) size|\(comparison.leftName) modified|\(comparison.rightName) modified|suggested")
        let sorted = rows.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        let start = max(0, min(from, sorted.count))
        let page = Array(sorted[start..<min(sorted.count, start + pageSize)])
        // Built per call on the zone asked for: a formatter kept would keep the zone of its first
        // use (CapturedTimeZoneScanTests).
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate, .withTime, .withColonSeparatorInTime,
                                   .withSpaceBetweenDateAndTime]
        var group: String?
        for row in page {
            let top = topFolder(row.relativePath)
            if top != group {
                group = top
                let inGroup = sorted.filter { topFolder($0.relativePath) == top }
                lines.append("\(AskClaudeScreenCard.escape(top)) (\(directions(inGroup, comparison: comparison)))")
            }
            let path = row.type == .missingOnLeft ? row.rightItemPath : row.leftItemPath
            let handle = handles.handle(for: path)
            let change = row.description + (row.enclosedItemCount.map { ", \($0) item\($0 == 1 ? "" : "s") inside" } ?? "")
            let fields = [handle, row.relativePath, change,
                          size(row.leftFileSize, folder: row.leftIsDirectory, exists: row.type != .missingOnLeft),
                          size(row.rightFileSize, folder: row.rightIsDirectory, exists: row.type != .missingOnRight),
                          row.leftModified.map(formatter.string(from:)) ?? "—",
                          row.rightModified.map(formatter.string(from:)) ?? "—",
                          suggested(row, comparison: comparison)]
            lines.append(fields.enumerated().map { $0.offset == 0 ? $0.element : AskClaudeScreenCard.escape($0.element) }.joined(separator: "|"))
        }
        let rest = sorted.count - start - page.count
        if rest > 0 { lines.append("\(rest) more; call again with from \(start + page.count).") }
        return lines.joined(separator: "\n")
    }

    static func topFolder(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "(top level)"
    }

    /// "5 → iCloud · 2 → Dropbox".
    static func directions(_ rows: [FileDifference], comparison: Comparison) -> String {
        let toLeft = rows.filter { $0.action == .copyToLeft }.count
        let toRight = rows.filter { $0.action == .copyToRight }.count
        var parts: [String] = []
        if toLeft > 0 { parts.append("\(toLeft) → \(comparison.leftName)") }
        if toRight > 0 { parts.append("\(toRight) → \(comparison.rightName)") }
        return parts.joined(separator: " · ")
    }

    static func suggested(_ row: FileDifference, comparison: Comparison) -> String {
        let direction = "copy to " + (row.action == .copyToLeft ? comparison.leftName : comparison.rightName)
        guard let held = row.heldBack else { return direction }
        let why: String
        switch held {
        case .sizesDifferWithoutANewerSide: why = "sizes differ and neither side is newer"
        case .folderVersusFile: why = "a folder on one side, a file on the other"
        case .sourceIsSymbolicLink: why = "the side to copy from is a link"
        case .enclosesSymbolicLink: why = "a link inside it points outside"
        }
        return "held back (\(why)); not copied by bulk runs"
    }

    static func size(_ bytes: Int?, folder: Bool, exists: Bool) -> String {
        guard exists else { return "—" }
        if folder { return bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "folder" }
        return bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
    }

    /// "just now", "4 min ago", "3 h ago", "2 days ago".
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default:
            let days = Int(seconds / 86_400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

private extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}
