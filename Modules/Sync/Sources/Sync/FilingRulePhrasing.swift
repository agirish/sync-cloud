import Foundation

/// Natural-language rendering of a remembered ``FilingRule`` so a learned rule reads as something a
/// person can understand instead of a raw token dump. Shared by every surface that lists remembered
/// rules (Settings ▸ Filing and the Tidy ▸ Automations lens).
public enum FilingRulePhrasing {
    /// Natural-language phrasing of a rule's trigger tokens, e.g. `Files with "invoice" and "acme"`.
    /// Falls back to `Any file` for the (unexpected) empty set.
    public static func trigger(_ tokens: [String]) -> String {
        let quoted = tokens.map { "\"\($0)\"" }
        switch quoted.count {
        case 0: return "Any file"
        case 1: return "Files with \(quoted[0])"
        case 2: return "Files with \(quoted[0]) and \(quoted[1])"
        default:
            let head = quoted.dropLast().joined(separator: ", ")
            return "Files with \(head), and \(quoted.last!)"
        }
    }

    /// Home-abbreviated destination for compact display, e.g. `~/Documents/Invoices`.
    public static func destination(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
