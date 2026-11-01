import Foundation

/// The questions typed into Ask Claude's box, for Up and Down to walk back through, like a shell's.
///
/// Up shows the one before; Down comes back, ending at what was typed and not sent. Changes made to
/// a recalled question are kept while walking, so Up then Down loses nothing, and are dropped at the
/// next send. Only typed questions are kept, the last `limit` of them, each once: sending one again
/// moves it to the newest. It outlives New Chat and the hour's reset: it is his typing, not the chat.
struct AskClaudePromptHistory: Equatable {
    static let limit = 10

    /// Oldest first.
    private(set) var entries: [String]
    /// Which entry the box shows; nil is the draft.
    private(set) var position: Int?
    private var draft = ""
    private var edits: [Int: String] = [:]

    /// Entries read back from disk go through `record`, so a file edited by hand can't bring back
    /// a blank, a repeat or more than `limit`.
    init(entries: [String] = []) {
        self.entries = []
        for entry in entries { record(entry) }
    }

    /// The question before the one shown, or nil when there is none and the box stays as it is.
    /// `current` is what the box holds now; it is kept for the way back.
    mutating func older(than current: String) -> String? {
        let target = (position ?? entries.count) - 1
        guard target >= 0 else { return nil }
        keep(current)
        position = target
        return edits[target] ?? entries[target]
    }

    /// The question after the one shown, then the draft; nil when the box already shows the draft.
    mutating func newer(than current: String) -> String? {
        guard let position else { return nil }
        keep(current)
        let target = position + 1
        if target >= entries.count {
            self.position = nil
            return draft
        }
        self.position = target
        return edits[target] ?? entries[target]
    }

    /// A question sent from the box: it becomes the newest, and the walk starts again from the draft.
    mutating func record(_ sent: String) {
        let text = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        position = nil
        draft = ""
        edits = [:]
        guard !text.isEmpty else { return }
        entries.removeAll { $0 == text }
        entries.append(text)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    private mutating func keep(_ current: String) {
        if let position {
            if current != entries[position] { edits[position] = current } else { edits[position] = nil }
        } else {
            draft = current
        }
    }
}
