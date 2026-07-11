import Foundation

/// Makes invisible name characters visible in UI labels. A folder named "Swimming " (trailing
/// space) renders pixel-identical to its sibling "Swimming", so the panes can show two
/// "identical" rows that are actually different items — the marked form ("Swimming␣")
/// disambiguates them. Names without affix whitespace come through untouched, so ordinary
/// rows render exactly as before.
public enum NameDisplay {
    /// U+2423 OPEN BOX — the standard visible-space glyph.
    private static let visibleSpace: Character = "␣"

    /// True when the name begins or ends with whitespace (the invisible-at-the-edges cases).
    public static func hasInvisibleAffix(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(first)
            || CharacterSet.whitespacesAndNewlines.contains(last)
    }

    /// `name` with each leading/trailing whitespace character replaced by a visible "␣".
    /// Interior whitespace is left alone — it's already visible by the text around it.
    public static func visibleName(_ name: String) -> String {
        guard hasInvisibleAffix(name) else { return name }
        var characters = Array(name)
        var index = 0
        while index < characters.count, characters[index].isWhitespace {
            characters[index] = visibleSpace
            index += 1
        }
        index = characters.count - 1
        while index >= 0, characters[index].isWhitespace {
            characters[index] = visibleSpace
            index -= 1
        }
        return String(characters)
    }

    /// A relative path with every component's affix whitespace made visible
    /// ("Fitness/Swimming /a.txt" → "Fitness/Swimming␣/a.txt").
    public static func visiblePath(_ path: String) -> String {
        guard path.contains("/") else { return visibleName(path) }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { visibleName(String($0)) }
            .joined(separator: "/")
    }
}
