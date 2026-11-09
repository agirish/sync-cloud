import Foundation

/// What Ask Claude is told about the screen: a short text card, in the user’s message, never the
/// instructions.
///
/// Rows go as pipe-separated lines, not JSON: the same row as JSON is about twice the tokens,
/// because every row repeats the field names. Names are escaped so a file name holding a pipe, a
/// newline or `</screen>` cannot pass itself off as another row or end the block. Paths are
/// relative to their source, so the home folder’s name never leaves the Mac.
public struct AskClaudeScreen: Equatable, Sendable {

    public struct Row: Equatable, Sendable {
        /// Absolute path: the handle table’s key. Never sent.
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let kind: String
        public let size: Int?
        public let modified: Date?
        public let tags: [String]
        /// For a folder, how many items it holds, when loaded.
        public let childCount: Int?

        public init(path: String, name: String, isDirectory: Bool, kind: String, size: Int?,
                    modified: Date?, tags: [String], childCount: Int? = nil) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.kind = kind
            self.size = size
            self.modified = modified
            self.tags = tags
            self.childCount = childCount
        }
    }

    public let workspace: String
    public let source: String
    /// The folder on screen, relative to the source; empty for its top level.
    public let folder: String
    public let sort: String
    public let rows: [Row]
    /// Absolute paths of the selected rows.
    public let selection: Set<String>
    /// Whether this workspace has tools in this version.
    public let toolsAvailable: Bool
    /// Every source the Browse pane can switch to, by name.
    public let sources: [String]
    /// The mounted disks Finder would eject (a card, a USB disk, an opened disk image), by name, as
    /// the sidebar's Locations shows them: the `eject` tool names one of these.
    public var disks: [String] = []
    /// The pane's tabs, the one on screen first. A tab at a hidden folder comes as
    /// "(hidden)": a tab is titled with its folder's name.
    public var tabs: [String] = []
    /// Compare's two sides, "left: Dropbox › Documents/Work", when Compare is on screen.
    public var panes: [String] = []
    /// Compare's differences in one line, when Compare is on screen.
    public var differences: String?
    /// "Columns · hidden files off".
    public var view: String = ""
    /// The parent columns on screen in Columns view, outermost first.
    public var columns: [Column] = []
    /// Rows left out because they're on the Never show Claude list.
    public var hiddenCount = 0
    /// The folder on screen is itself hidden from Claude.
    public var folderHidden = false
    /// The file open in Edit, when Edit is on screen.
    public var openFile: Row?
    /// What they attached from a row's menu, wherever it lives: their question is about
    /// these. Never anything on the Never show Claude list.
    public var attached: [Attached] = []

    public struct Attached: Equatable, Sendable {
        public let row: Row
        /// Where it lives, "iCloud › Documents/Taxes"; never an absolute path.
        public let place: String

        public init(row: Row, place: String) {
            self.row = row
            self.place = place
        }
    }

    public struct Column: Equatable, Sendable {
        public let folder: String
        public let rows: [Row]
        /// The item open in the next column.
        public let open: String?

        public init(folder: String, rows: [Row], open: String?) {
            self.folder = folder
            self.rows = rows
            self.open = open
        }
    }

    public init(workspace: String, source: String, folder: String, sort: String, rows: [Row],
                selection: Set<String>, toolsAvailable: Bool, sources: [String] = []) {
        self.sources = sources
        self.workspace = workspace
        self.source = source
        self.folder = folder
        self.sort = sort
        self.rows = rows
        self.selection = selection
        self.toolsAvailable = toolsAvailable
    }
}

/// Short names for files and folders, kept for the whole chat, so "r9" still means the Costco
/// receipt after a re-sort. The app maps a handle back to its path; Claude never sees the path.
public struct AskClaudeHandles: Equatable, Sendable, Codable {
    private var byPath: [String: String] = [:]
    private var byHandle: [String: String] = [:]
    private var next = 1

    public init() {}

    public mutating func handle(for path: String) -> String {
        if let existing = byPath[path] { return existing }
        let handle = "r\(next)"
        next += 1
        byPath[path] = handle
        byHandle[handle] = path
        return handle
    }

    /// The path a handle names, or nil for one this chat never issued. A guessed handle can’t come
    /// to mean another file.
    public func path(for handle: String) -> String? {
        byHandle[handle.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    public var count: Int { byPath.count }

    /// Every path this chat has a handle for, so the panel can make names in answers clickable.
    public var paths: [String] { Array(byPath.keys) }
}

public enum AskClaudeScreenCard {

    /// Rows sent per folder. A bigger folder sends the rows nearest the selection, plus a line
    /// saying how many more there are and what kinds they are.
    public static let maxRows = 60
    /// Rows sent per parent column in Columns view.
    public static let maxColumnRows = 20

    public struct Rendered: Equatable, Sendable {
        public let text: String
        public let rowsSent: Int
        public let rowsTotal: Int
    }

    public static func render(_ screen: AskClaudeScreen, handles: inout AskClaudeHandles) -> Rendered {
        var lines: [String] = ["<screen>"]
        // A hidden folder isn't named, here or anywhere: its path would say what it holds.
        let folderLabel = screen.folderHidden ? "(a folder hidden from Claude)"
            : screen.folder.isEmpty ? "(top level)" : escape(screen.folder)
        lines.append("workspace: \(screen.workspace) · source: \(escape(screen.source)) · folder: \(folderLabel)")
        if !screen.sources.isEmpty {
            lines.append("sources: " + screen.sources.map(escape).joined(separator: ", "))
        }
        if !screen.disks.isEmpty {
            lines.append("disks you can eject: " + screen.disks.map(escape).joined(separator: ", "))
        }
        if let open = screen.openFile {
            lines.append("open in Edit: " + row(for: open, handles: &handles))
        }
        if !screen.tabs.isEmpty {
            lines.append("tabs: " + screen.tabs.map(escape).joined(separator: ", ") + " (first is on screen)")
        }
        if !screen.panes.isEmpty {
            lines.append("panes: " + screen.panes.map(escape).joined(separator: " · "))
        }
        if let differences = screen.differences { lines.append(escape(differences)) }
        // Before the hidden-folder stop: what they attached is shown wherever they are.
        if !screen.attached.isEmpty {
            lines.append("attached by them, what their question is about: handle|name|kind|size|modified|tags|where")
            lines += screen.attached.map { row(for: $0.row, handles: &handles) + "|" + escape($0.place) }
        }
        if screen.folderHidden {
            lines.append("This folder is on their Hidden from Claude list: nothing in it is described.")
            lines.append("</screen>")
            return Rendered(text: lines.joined(separator: "\n"), rowsSent: 0, rowsTotal: 0)
        }
        guard screen.toolsAvailable else {
            lines.append("Ask Claude has no tools in \(screen.workspace) in this version; it works in Browse.")
            lines.append("</screen>")
            return Rendered(text: lines.joined(separator: "\n"), rowsSent: 0, rowsTotal: screen.rows.count)
        }
        let folders = screen.rows.filter(\.isDirectory).count
        let bytes = screen.rows.filter { !$0.isDirectory }.compactMap(\.size).reduce(0, +)
        lines.append("sort: \(screen.sort)" + (screen.view.isEmpty ? "" : " · view: \(screen.view)")
                     + " · \(count(screen.rows.count, "item")) (\(count(folders, "folder"))) · \(size(bytes)) in files")
        // Parent columns, outermost first, so the other period or what sits next to this needs no tool.
        for column in screen.columns {
            lines.append("column \(escape(column.folder.isEmpty ? "(top level)" : column.folder))" + (column.open.map { " (open: \(escape($0)))" } ?? "") + ":")
            lines += column.rows.prefix(maxColumnRows).map { row(for: $0, handles: &handles) }
            if column.rows.count > maxColumnRows { lines.append("\(column.rows.count - maxColumnRows) more in that column") }
        }
        if !screen.columns.isEmpty { lines.append("column \(escape(screen.folder.isEmpty ? "(top level)" : screen.folder)) (on screen, rows below)") }

        let window = rowWindow(screen.rows, selection: screen.selection)
        // Handles are issued in display order, so a fresh chat reads r1, r2, r3 down the screen.
        let rowLines = window.rows.map { row(for: $0, handles: &handles) }
        let selected = screen.rows.filter { screen.selection.contains($0.path) }.map { handles.handle(for: $0.path) }
        lines.append("selected: " + (selected.isEmpty ? "none" : selected.joined(separator: " ")))
        lines.append("rows: handle|name|kind|size|modified|tags")
        lines.append(contentsOf: rowLines)
        if window.above + window.below > 0 {
            let rest = screen.rows.enumerated().filter { !window.range.contains($0.offset) }.map(\.element)
            var note = "\(count(window.above + window.below, "more item")) not listed"
            if window.above > 0 { note += " (\(window.above) above, \(window.below) below)" }
            note += ": " + kindSummary(rest) + ". Use list_folder with from to see them."
            lines.append(note)
        }
        if screen.hiddenCount > 0 { lines.append("\(count(screen.hiddenCount, "item")) here hidden from Claude by them.") }
        lines.append("</screen>")
        return Rendered(text: lines.joined(separator: "\n"), rowsSent: window.rows.count, rowsTotal: screen.rows.count)
    }

    /// One row line for tools that list rows (list_folder, find_by_name).
    public static func row(for row: AskClaudeScreen.Row, handles: inout AskClaudeHandles) -> String {
        let sizeText: String
        if row.isDirectory {
            sizeText = row.childCount.map { count($0, "item") } ?? ""
        } else {
            sizeText = row.size.map(size) ?? ""
        }
        return [handles.handle(for: row.path), escape(row.name), escape(row.kind), sizeText,
                row.modified.map(date) ?? "", row.tags.map(escape).joined(separator: ",")]
            .joined(separator: "|")
    }

    /// The rows to send: everything when it fits, otherwise a window that keeps the first selected
    /// row in view.
    static func rowWindow(_ rows: [AskClaudeScreen.Row], selection: Set<String>)
        -> (rows: [AskClaudeScreen.Row], range: Range<Int>, above: Int, below: Int) {
        guard rows.count > maxRows else { return (rows, 0..<rows.count, 0, 0) }
        let anchor = rows.firstIndex { selection.contains($0.path) } ?? 0
        let start = min(max(0, anchor - maxRows / 2), rows.count - maxRows)
        let range = start..<(start + maxRows)
        return (Array(rows[range]), range, start, rows.count - range.upperBound)
    }

    /// Makes text safe inside a row: no pipe, no line break, no angle bracket that could close the
    /// screen block.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            // A subdivision flag (🏴 and its tag letters) is the one place tag characters belong.
            if character.unicodeScalars.first?.value == 0x1F3F4 {
                out.append(character)
                continue
            }
            for scalar in character.unicodeScalars {
                switch scalar {
                case "|": out += "¦"
                case "\n", "\r", "\u{2028}", "\u{2029}": out += " "
                case "<": out += "‹"
                case ">": out += "›"
                // The joiners stay, or "👩‍💻 Notes" and Persian and Indic names come apart.
                case "\u{200C}", "\u{200D}": out.unicodeScalars.append(scalar)
                default:
                    // Control and format characters go: bidi overrides make a name read as
                    // something else, and tag characters carry text a model reads and a person
                    // never sees.
                    let category = scalar.properties.generalCategory
                    if category == .control || category == .format {
                        out += " "
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
        }
        return out
    }

    static func kindSummary(_ rows: [AskClaudeScreen.Row]) -> String {
        var counts: [String: Int] = [:]
        for row in rows { counts[row.isDirectory ? "folders" : row.kind, default: 0] += 1 }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4)
        var parts = top.map { $0.key == "folders" ? count($0.value, "folder") : "\($0.value) \(escape($0.key))" }
        let shown = top.map(\.value).reduce(0, +)
        if rows.count > shown { parts.append("\(rows.count - shown) other") }
        return parts.joined(separator: ", ")
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Sizes the way the panes show them.
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Dates as ISO days, in the Mac’s time zone: short, unambiguous, and sortable by eye.
    static func date(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
