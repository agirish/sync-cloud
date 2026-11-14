/// Comment stripping for the source scans in every UI test target, so a call named in a comment
/// can't stand in for the call.
public enum SourceComments {

    /// `line` without its `//` comment, whole or trailing. A `//` inside a string literal (a URL's
    /// `https://`) is kept.
    public static func codeOnly(_ line: some StringProtocol) -> String {
        var inString = false
        var previous: Character = " "
        for index in line.indices {
            let character = line[index]
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/" { return String(line[..<line.index(before: index)]) }
            previous = character
        }
        return String(line)
    }

    /// `text` with every line through `codeOnly`, line breaks kept.
    public static func stripped(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(codeOnly).joined(separator: "\n")
    }
}
