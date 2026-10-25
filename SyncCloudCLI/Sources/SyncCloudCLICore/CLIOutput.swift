import Foundation

/// **What the command-line tool prints is plain ASCII punctuation** (FC10): a terminal, a pipe
/// into `grep`, or a log a script greps should not have to match `’` where it typed `'`.
///
/// The app's own strings stay curly — this tool shares many of them (a provider's name rules, a
/// sync error's sentence) — so the fold happens once, here, at the output boundary: every line
/// `CommandRunner` writes, and what the shell prints itself, goes through `ascii(_:)`.
///
/// **JSON is not folded.** `scan --json` and `restructure --json` are the stable, machine-read
/// formats: their paths must be the real paths, and a folded `“` would land as a bare `"` inside a
/// JSON string and break the document.
///
/// **Nor is a name from disk.** The fold is for the tool's own words; a path or a file name is
/// what someone pastes back into a shell, and "Bob’s.txt" folded to "Bob's.txt" names a file that
/// does not exist. Every path or on-disk name a text line interpolates is wrapped in
/// `verbatim(_:)`, and `ascii(_:)` leaves what is inside the wrap alone. The wrap is built only
/// where text output is rendered, never into the values the JSON writers encode.
///
/// **Known limit:** a sentence that arrives already worded — a shared Sync message, or a Cocoa
/// error such as "The file “a’s.txt” couldn’t be opened." — still folds the name inside it, because
/// there the name cannot be told apart from the words around it.
public enum CLIOutput {
    /// The typographic characters folded, and what each becomes.
    static let folds: [Character: String] = [
        "\u{2019}": "'", "\u{2018}": "'",     // ’ ‘
        "\u{201C}": "\"", "\u{201D}": "\"",   // “ ”
        "\u{2026}": "...",                    // …
        "\u{2013}": "-", "\u{2014}": "-",     // – —
    ]

    /// The two private-use characters `verbatim(_:)` puts around a name. Private use, so no file
    /// name or sentence of the app's carries them by accident; stripped from everything printed.
    static let verbatimStart: Unicode.Scalar = "\u{E000}"
    static let verbatimEnd: Unicode.Scalar = "\u{E001}"

    /// `name` marked to be printed exactly as it is — a path or an on-disk name, which `ascii(_:)`
    /// must not fold. The markers are stripped wherever the text is printed.
    public static func verbatim(_ name: String) -> String {
        String(Character(verbatimStart)) + name + String(Character(verbatimEnd))
    }

    /// `text` with curly quotes and apostrophes, the ellipsis and the dashes folded to ASCII —
    /// outside any `verbatim(_:)` wrap — and the wrap's markers removed.
    ///
    /// Read scalar by scalar, not by `Character`: a name beginning with a combining mark would
    /// otherwise join the opening marker into one grapheme, and the marker would leak. A start
    /// marker with no end leaves the rest of the text unfolded; an end marker with no start is
    /// dropped. Either way no marker is printed.
    public static func ascii(_ text: String) -> String {
        render(text, folding: true)
    }

    /// `text` with the `verbatim(_:)` markers removed and nothing folded — for what leaves the
    /// tool other than as printed text, such as the line it writes to the app's log.
    public static func stripped(_ text: String) -> String {
        render(text, folding: false)
    }

    private static func render(_ text: String, folding: Bool) -> String {
        var out = String.UnicodeScalarView()
        var depth = 0
        for scalar in text.unicodeScalars {
            if scalar == verbatimStart { depth += 1; continue }
            if scalar == verbatimEnd { depth = max(0, depth - 1); continue }
            if folding, depth == 0, let folded = folds[Character(scalar)] {
                out.append(contentsOf: folded.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// **An error ArgumentParser will print, with its message folded.** A command body's error
    /// that is not ours to classify (`CLIExitMapping`'s `.rethrow` — say a copy's Cocoa error
    /// under `--fail-fast`, "The file “a.txt” couldn’t be opened") is printed by ArgumentParser
    /// itself, as `Error: <message>`. This reads the message the way ArgumentParser does — a
    /// `LocalizedError`'s description, else an `NSError`'s — and, when folding changes it, returns
    /// an error carrying the folded message instead; otherwise the error itself. Either way the
    /// exit code is the same: ArgumentParser exits 1 for any error not its own.
    public static func foldedForPrinting(_ error: Error) -> Error {
        let message: String
        if let described = (error as? LocalizedError)?.errorDescription {
            message = described
        } else if type(of: error) is NSError.Type {
            message = (error as NSError).localizedDescription
        } else {
            return error
        }
        let folded = ascii(message)
        return folded == message ? error : FoldedError(errorDescription: folded)
    }

    /// An error message after `foldedForPrinting`.
    public struct FoldedError: LocalizedError, Equatable {
        public let errorDescription: String?
    }
}
