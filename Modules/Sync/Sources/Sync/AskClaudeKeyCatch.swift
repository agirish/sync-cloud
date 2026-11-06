import Foundation

/// An Anthropic API key pasted into Ask Claude's message box, caught before the message is sent,
/// so a key never reaches Claude, the chat's file, or the remembered questions.
///
/// Caught when the message holds `sk-ant-` followed by 20 or more key characters: letters,
/// digits, `-` and `_`, which is what Anthropic's keys are made of. Fewer is a mention of the
/// prefix, not a key, and goes through.
public enum AskClaudeKeyCatch {

    /// How many key characters after `sk-ant-` make a key.
    public static let minimumTail = 20

    private static let pattern = try! NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]{\(minimumTail),}")

    /// The first key in `text`, or nil when there is none — including a key a paste broke across
    /// lines, which is caught with the line breaks taken out.
    public static func key(in text: String) -> String? {
        if let span = spans(in: text).first { return String(text[span].filter { !$0.isNewline }) }
        // Broken before 20 key characters: only the whole text, joined, shows it's a key.
        let joined = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard let match = pattern.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
              let found = Range(match.range, in: joined) else { return nil }
        return String(joined[found])
    }

    /// Where each key is in `text`, with the lines a paste broke it onto. A key broken after 20
    /// characters matches on its first line alone, so without this Save as API Key would store part
    /// of it and the masked card show the rest. A line after a key is more of it when it holds
    /// only key characters and isn't a plain word ("thanks") or another key.
    private static func spans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard var span = Range(match.range, in: text), span.lowerBound >= (spans.last?.upperBound ?? text.startIndex) else { continue }
            while span.upperBound < text.endIndex, text[span.upperBound].isNewline {
                let start = text.index(after: span.upperBound)
                let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
                guard continues(text[start..<end]) else { break }
                span = span.lowerBound..<end
            }
            spans.append(span)
        }
        return spans
    }

    private static func continues(_ line: Substring) -> Bool {
        guard !line.isEmpty, !line.contains("sk-ant-"),
              line.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return false }
        // A plain word: letters only, with at most the first a capital.
        return !(line.allSatisfy(\.isLetter) && line.dropFirst().allSatisfy(\.isLowercase))
    }

    /// How much of a key is kept when it is masked: `sk-ant-` and its kind ("api03-"), never a
    /// character of the secret.
    private static let kept = try! NSRegularExpression(pattern: "^sk-ant-(?:[a-z]+[0-9]*-)?")

    /// `text` with every key cut to its prefix and 12 dots — "sk-ant-api03-••••••••••••" — safe to
    /// show and to save with the chat. With `joiningLines`, a message whose key a paste broke across
    /// lines before 20 key characters is masked with its line breaks taken out; a tool's text keeps
    /// its lines, but for those inside a key.
    ///
    /// Each match is replaced once, last first so the earlier ranges hold: a loop that searched
    /// again after each replacement would never end if what it kept still matched.
    public static func masked(_ text: String, joiningLines: Bool = true) -> String {
        let whole = !spans(in: text).isEmpty
        var result = !joiningLines || whole || key(in: text) == nil
            ? text : text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        for range in spans(in: result).reversed() {
            let found = String(result[range])
            let prefix = kept.firstMatch(in: found, range: NSRange(found.startIndex..., in: found))
                .flatMap { Range($0.range, in: found) }.map { String(found[$0]) } ?? "sk-ant-"
            result.replaceSubrange(range, with: prefix + String(repeating: "•", count: 12))
        }
        return result
    }
}
