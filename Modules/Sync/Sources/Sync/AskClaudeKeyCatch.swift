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

    /// The first key in `text`, or nil when there is none.
    public static func key(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range), let found = Range(match.range, in: text) else { return nil }
        return String(text[found])
    }

    /// `text` with every key cut to its first 13 characters and 12 dots — "sk-ant-api03-••••••••••••"
    /// — safe to show and to save with the chat.
    ///
    /// Each match in the message is replaced once, last first so the earlier ranges hold: a loop
    /// that searched again after each replacement would never end if what it kept still matched.
    public static func masked(_ text: String) -> String {
        var result = text
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: String(result[range].prefix(13)) + String(repeating: "•", count: 12))
        }
        return result
    }
}
