import Foundation
@testable import FileExplorer

// **The tests write buffers as `String`s**; the edits take the text view's `NSString` storage, so
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
