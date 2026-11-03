import Foundation

/// **A file's stamp as a card keeps it** — when it was modified, its size and its identity on disk —
/// so a card can tell the file it read, or the file it wrote, from one that has changed since. The
/// app's own stamp lives in FileExplorer and isn't saved; this one is, with the chat.
public struct AskClaudeFileStamp: Codable, Equatable, Sendable {
    public var modifiedAt: Date?
    public var size: Int
    public var fileID: Int

    public init(modifiedAt: Date?, size: Int, fileID: Int) {
        self.modifiedAt = modifiedAt
        self.size = size
        self.fileID = fileID
    }
}

/// **A card that runs one of SyncCloud's PDF tools on the person's click** (TE294). Claude offers
/// it; nothing is written until they click its button, and what it wrote it can take back to the
/// Trash. Saved with the chat — never a password, which lives only in the card's field.
public struct AskClaudePDFCard: Codable, Equatable, Sendable {

    public enum Action: String, Codable, CaseIterable, Sendable {
        case saveAsPDF, compress, rotate, cleanMetadata, protect, removePassword
        case extract, deletePages, reorder, split, combine

        /// The card's title, and the run button's words.
        public var title: String {
            switch self {
            case .saveAsPDF: return "Save as PDF"
            case .compress: return "Compress"
            case .rotate: return "Rotate"
            case .cleanMetadata: return "Clean Metadata"
            case .protect: return "Protect with Password"
            case .removePassword: return "Remove Password"
            case .extract: return "Extract Pages"
            case .deletePages: return "Delete Pages"
            case .reorder: return "Reorder Pages"
            case .split: return "Split"
            case .combine: return "Combine"
            }
        }

        /// Tools that run over several files at once; the rest take one (Combine, two or more).
        public var takesSeveral: Bool {
            switch self {
            case .saveAsPDF, .compress, .rotate, .cleanMetadata, .combine: return true
            default: return false
            }
        }

        /// Tools that act on chosen pages, so the card draws them.
        public var choosesPages: Bool {
            switch self {
            case .extract, .deletePages, .reorder, .split: return true
            case .rotate, .saveAsPDF, .compress, .cleanMetadata, .protect, .removePassword, .combine: return false
            }
        }
    }

    /// One file on the card, by absolute path — the order Combine puts them in.
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var name: String
        /// "iCloud › Documents › Housing": where it is, for the card and for Claude.
        public var folderLabel: String
        public var bytes: Int?
        public var pageCount: Int?
        /// The file as the card read it; the run holds the file to it.
        public var stamp: AskClaudeFileStamp?
        /// Why this file can't run, shown on its row; nil when it can.
        public var refusal: String?
        /// Only in the cloud: the row offers Download before anything runs.
        public var cloudOnly: Bool

        public var id: String { path }

        public init(path: String, name: String, folderLabel: String, bytes: Int? = nil, pageCount: Int? = nil,
                    stamp: AskClaudeFileStamp? = nil, refusal: String? = nil, cloudOnly: Bool = false) {
            self.path = path
            self.name = name
            self.folderLabel = folderLabel
            self.bytes = bytes
            self.pageCount = pageCount
            self.stamp = stamp
            self.refusal = refusal
            self.cloudOnly = cloudOnly
        }
    }

    /// The tool's options as chosen — Claude's picks first, the person's changes after.
    public struct Options: Codable, Equatable, Sendable {
        public enum Strength: String, Codable, CaseIterable, Sendable { case best, balanced, smallestFile }
        public enum Mode: String, Codable, Sendable { case lockToOpen, restrictEditing }

        public var strength: Strength?
        /// Compress: come in under this many megabytes, instead of a strength.
        public var underMB: Double?
        /// Rotate: quarter turns clockwise, 1, 2 or 3.
        public var quarterTurns: Int?
        /// Extract, Delete, Reorder, Rotate: pages as typed, one-based — "3-5, 1".
        public var pages: String?
        /// Split: the one-based pages new files start at.
        public var splitAt: [Int]?
        public var mode: Mode?
        /// Combine: the new file's name, as typed.
        public var name: String?

        public init(strength: Strength? = nil, underMB: Double? = nil, quarterTurns: Int? = nil,
                    pages: String? = nil, splitAt: [Int]? = nil, mode: Mode? = nil, name: String? = nil) {
            self.strength = strength
            self.underMB = underMB
            self.quarterTurns = quarterTurns
            self.pages = pages
            self.splitAt = splitAt
            self.mode = mode
            self.name = name
        }
    }

    public enum State: String, Codable, Sendable {
        /// The files are being read for the card: its button waits.
        case checking
        case offered
        case running
        case done
        /// Some of the files were written; the rest say why not.
        case partlyDone
        /// It ran and there was nothing to write — already small, already under the target.
        case nothingWritten
        case failed
        case notNow
        case undone
        /// A newer card for the same files and tool took its place.
        case replaced
        /// SyncCloud quit while it ran.
        case quitWhileRunning
    }

    /// A file the run wrote, as it landed.
    public struct Written: Codable, Equatable, Sendable {
        public var path: String
        public var stamp: AskClaudeFileStamp
        public var bytes: Int
        public var pageCount: Int?

        public init(path: String, stamp: AskClaudeFileStamp, bytes: Int, pageCount: Int? = nil) {
            self.path = path
            self.stamp = stamp
            self.bytes = bytes
            self.pageCount = pageCount
        }
    }

    public var action: Action
    public var rows: [Row]
    public var options: Options
    public var state: State
    /// What the copy will lose, one sentence each, read from the files.
    public var losses: [String]
    /// A folder chosen for the new files because the original's can't be written to.
    public var folder: String?
    public var written: [Written]
    /// How the run ended, in the tool's own words — or, while it waits, why the last click didn't run.
    public var message: String?
    public var detail: String?
    /// Why the pages typed can't be, said under them; the button waits while there is one.
    public var pagesProblem: String?

    public init(action: Action, rows: [Row], options: Options = Options(), state: State = .checking,
                losses: [String] = [], folder: String? = nil, written: [Written] = [],
                message: String? = nil, detail: String? = nil) {
        self.action = action
        self.rows = rows
        self.options = options
        self.state = state
        self.losses = losses
        self.folder = folder
        self.written = written
        self.message = message
        self.detail = detail
    }

    /// The card's title: the tool, and for several files how many.
    public var title: String {
        switch action {
        case .combine: return "Combine \(rows.count) PDFs"
        case .saveAsPDF, .compress, .rotate, .cleanMetadata:
            return rows.count > 1 ? "\(action.title) · \(rows.count) files" : action.title
        default: return action.title
        }
    }

    /// Whether the card still waits for its click.
    public var isOpen: Bool { state == .checking || state == .offered }

    /// Whether a newer card `other` takes this one's place: the very same card again — the same
    /// tool, files and options. Two cards for one file with different pages (pages 1–3, and 7–9)
    /// are two things asked for, and both stay.
    public func isReplaced(by other: AskClaudePDFCard) -> Bool {
        isOpen && action == other.action && Set(rows.map(\.path)) == Set(other.rows.map(\.path)) && options == other.options
    }

    /// The most files on one card, and the most parts a split makes (TE294).
    public static let maxFiles = 20
    public static let maxParts = 20
}
