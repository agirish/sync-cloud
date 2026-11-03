import Foundation

/// The questions an empty chat offers, one click each (TE299): a fixed table on this Mac, keyed by
/// the workspace and what is on screen. Free, and nothing is sent until one is clicked; a click
/// sends it exactly as if it were typed. They go once the chat has its first question.
///
/// **No item's name, ever.** A question names nothing but a source, and a source only while the
/// folder on screen isn't hidden from Claude: a hidden folder hides everything under it, so a
/// shown one means its source's top isn't hidden either. The file open in Edit is "this file".
public enum AskClaudeStarters {

    /// What the table is keyed by: the panel's place (`AskClaudePlace`), in its own words.
    public struct Screen: Equatable, Sendable {
        /// "Browse", "Compare", "Organize" or "Edit".
        public var workspace: String
        public var source: String
        /// Relative to the source; empty at its top.
        public var folder: String
        /// Nil while the folder hasn't loaded.
        public var itemCount: Int?
        public var folderHidden: Bool
        /// The file open in Edit, when Claude is told about it; nil when it is hidden.
        public var openFile: String?

        public init(workspace: String, source: String, folder: String, itemCount: Int?, folderHidden: Bool,
                    openFile: String? = nil) {
            self.workspace = workspace
            self.source = source
            self.folder = folder
            self.itemCount = itemCount
            self.folderHidden = folderHidden
            self.openFile = openFile
        }
    }

    /// For a folder Claude can't see into, an empty one, or one still loading.
    static let anywhere = ["What can you do in SyncCloud?", "Find my newest PDFs", "Open my Downloads folder"]

    /// Three or four questions for `screen`, most useful first.
    public static func questions(for screen: Screen) -> [String] {
        switch screen.workspace {
        case "Compare":
            let both = ["Show the name conflicts", "What changed, and which side is newer?"]
            return screen.folderHidden ? both + ["What can you do in SyncCloud?"]
                                       : ["What’s only in \(screen.source), by folder?"] + both
        case "Edit":
            guard let open = screen.openFile else { return inFolder(screen) }
            if (open as NSString).pathExtension.lowercased() == "pdf" {
                return ["Summarize this PDF", "What dates and amounts does it mention?", "Make it smaller to email",
                        "Where should this file go?"]
            }
            return ["Summarize this file", "What dates and amounts does it mention?", "Where should this file go?"]
        case "Organize":
            guard sees(screen) else { return anywhere }
            return ["Where should these files go?", "What’s newest here?", "What can you do in Organize?"]
        default:
            return inFolder(screen)
        }
    }

    /// Browse's questions, and Edit's with nothing open: about the folder on screen.
    private static func inFolder(_ screen: Screen) -> [String] {
        guard sees(screen) else { return anywhere }
        let name = screen.folder.split(separator: "/").last.map(String.init) ?? ""
        if name.caseInsensitiveCompare("Downloads") == .orderedSame {
            return ["Where should these files go?", "What came in this week?", "Which are the biggest?"]
        }
        return ["What’s in this folder?", "What’s newest here?", "Which are the biggest?"]
    }

    /// Whether there is something on screen Claude may look at.
    private static func sees(_ screen: Screen) -> Bool {
        !screen.folderHidden && (screen.itemCount ?? 0) > 0
    }
}
