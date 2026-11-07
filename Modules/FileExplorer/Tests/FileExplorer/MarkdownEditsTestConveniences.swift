import Foundation
@testable import FileExplorer

// The tests write buffers as `String`s while the edits take the text view's `NSString` storage, so
// these overloads live here rather than in the shipped code.

extension MarkdownSplice {
    /// The buffer with the replacement made — what the tests read character for character.
    func applied(to buffer: String) -> String {
        (buffer as NSString).replacingCharacters(in: range, with: text)
    }
}

extension MarkdownPasteEdits {
    static func linkPaste(_ pasted: String, over selection: NSRange, in text: String) -> MarkdownSplice? {
        linkPaste(pasted, over: selection, in: text as NSString)
    }
}

extension MarkdownListEdits {
    static func returnEdit(in text: String, selection: NSRange) -> ReturnEdit? {
        returnEdit(in: text as NSString, selection: selection)
    }

    static func tabEdit(in text: String, selection: NSRange, outdent: Bool) -> TabEdit? {
        tabEdit(in: text as NSString, selection: selection, outdent: outdent)
    }
}

/// Splits `"- a|"` into the buffer and the caret.
func caret(_ marked: String) -> (text: String, selection: NSRange) {
    let ns = marked as NSString
    let at = ns.range(of: "|")
    return (ns.replacingCharacters(in: at, with: ""), NSRange(location: at.location, length: 0))
}

/// Splits `"- «ab»"` into the buffer and a selection.
func selecting(_ marked: String) -> (text: String, selection: NSRange) {
    let ns = marked as NSString
    let open = ns.range(of: "«")
    let without = ns.replacingCharacters(in: open, with: "") as NSString
    let close = without.range(of: "»")
    return (without.replacingCharacters(in: close, with: ""),
            NSRange(location: open.location, length: close.location - open.location))
}

/// Files outside this package that Edit's paste and drop make claims in: the app's wiring and its
/// Help, under `MacApp/`, which no package test otherwise reads. Found from this file's own path.
enum EditRepoFile {
    static func text(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/FileExplorer
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/Modules/FileExplorer
            .deletingLastPathComponent()   // …/Modules
            .deletingLastPathComponent()   // the repo
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The Help paragraph that opens with `opening` — each is one string literal on one line.
    static func helpParagraph(_ opening: String) throws -> String {
        let help = try text("MacApp/HelpBook.swift")
        guard let line = help.split(separator: "\n").first(where: { $0.contains("\"" + opening) }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "no Help paragraph opens “\(opening)”"])
        }
        return String(line)
    }
}
