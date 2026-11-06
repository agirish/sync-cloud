import Foundation

/// The words of the names on screen, for the transcriber on this Mac to listen for when a question
/// is spoken. Names are where dictation misses most ("Ally" heard as "Ellie"), and these hints
/// raised the name words heard right from 83% to 88%.
///
/// Words, not whole names: given "Ally Statements" the transcriber still hears "Ellie"; given
/// "Ally" it hears "Ally", streaming and batch alike.
///
/// Only what the screen card already shows Claude, so nothing on the Never show Claude list is
/// ever a hint: its rows and its folder are left out of the screen, and the caller passes only the
/// attachments it would send.
public enum AskClaudeVoiceHints {

    /// The most words given to the transcriber. A folder of thousands gives the nearest first.
    public static let limit = 100

    /// Words of what they attached first, then of the selected rows, the file open in Edit, the
    /// other rows in the screen's order, the folders on the way down, and the sources' names. A
    /// file's extension is left out, since nobody says it, and so are words dictation never
    /// misses ("the", "and").
    public static func words(on screen: AskClaudeScreen, attached: [(name: String, isDirectory: Bool)]) -> [String] {
        let selected = screen.rows.filter { screen.selection.contains($0.path) }
        let rest = screen.rows.filter { !screen.selection.contains($0.path) }
        var names = attached.map { spoken($0.name, isDirectory: $0.isDirectory) }
        names += selected.map { spoken($0.name, isDirectory: $0.isDirectory) }
        if let open = screen.openFile { names.append(spoken(open.name, isDirectory: false)) }
        names += rest.map { spoken($0.name, isDirectory: $0.isDirectory) }
        if !screen.folderHidden { names += screen.folder.split(separator: "/").map(String.init) }
        names += screen.sources

        var seen = Set<String>()
        var words: [String] = []
        for word in names.flatMap(Self.words(of:)) where seen.insert(word.lowercased()).inserted {
            words.append(word)
            if words.count == limit { break }
        }
        return words
    }

    /// "W-2 2025.pdf" is said "W-2 2025". A folder keeps its whole name: "v2.0" has no extension.
    static func spoken(_ name: String, isDirectory: Bool) -> String {
        guard !isDirectory else { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// "1099-INT Ally (copy)" is "1099-INT" and "Ally": a hyphen or a dot inside a word keeps it
    /// whole, as "H-1B" and "v2.0" are said; brackets, underscores and the like part words.
    public static func words(of name: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "_,;:()[]{}+&·—–/\\|\"“”"))
        return name.components(separatedBy: separators).compactMap { piece in
            let word = piece.trimmingCharacters(in: CharacterSet(charactersIn: ".-'’"))
            guard word.count >= 2, word.rangeOfCharacter(from: .alphanumerics) != nil,
                  !commonWords.contains(word.lowercased()) else { return nil }
            return word
        }
    }

    /// Words a name may hold that the transcriber has no trouble with; hints are better spent on
    /// the rest.
    static let commonWords: Set<String> = ["the", "and", "of", "for", "to", "in", "on", "at", "an", "my", "with", "from",
                                           "copy", "new", "untitled", "final", "draft", "scan"]
}
