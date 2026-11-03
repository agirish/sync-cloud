import Foundation

/// An Anthropic API key pasted into Ask Claude's message box (TE290 step 7): caught before the
/// message is sent, so a key never reaches Claude, the chat's file, or the remembered questions.
///
/// **Caught when the message holds `sk-ant-` followed by 20 or more key characters** — letters,
/// digits, `-` and `_`, which is what Anthropic's keys are made of. Fewer is a mention of the
/// prefix, not a key, and goes through.
public enum AskClaudeKeyCatch {

    /// How many key characters after `sk-ant-` make a key.
    public static let minimumTail = 20

    private static let pattern = try! NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]{\(minimumTail),}")

    /// The first key in `text`, or nil when there is none — including a key a paste broke across
    /// lines, which is caught with the line breaks taken out.
    public static func key(in text: String) -> String? {
        for candidate in [text, text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")] {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = pattern.firstMatch(in: candidate, range: range), let found = Range(match.range, in: candidate) {
                return String(candidate[found])
            }
        }
        return nil
    }

    /// How much of a key is kept when it is masked: `sk-ant-` and its kind ("api03-"), never a
    /// character of the secret.
    private static let kept = try! NSRegularExpression(pattern: "^sk-ant-(?:[a-z]+[0-9]*-)?")

    /// `text` with every key cut to its prefix and 12 dots — "sk-ant-api03-••••••••••••" — safe to
    /// show and to save with the chat. With `joiningLines`, a message whose key a paste broke across
    /// lines is masked with its line breaks taken out; a tool's text keeps its lines.
    ///
    /// Each match is replaced once, last first so the earlier ranges hold: a loop that searched
    /// again after each replacement would never end if what it kept still matched.
    public static func masked(_ text: String, joiningLines: Bool = true) -> String {
        let whole = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        var result = !joiningLines || whole || key(in: text) == nil
            ? text : text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let found = String(result[range])
            let prefix = kept.firstMatch(in: found, range: NSRange(found.startIndex..., in: found))
                .flatMap { Range($0.range, in: found) }.map { String(found[$0]) } ?? "sk-ant-"
            result.replaceSubrange(range, with: prefix + String(repeating: "•", count: 12))
        }
        return result
    }
}
