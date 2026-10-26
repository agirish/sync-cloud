import Foundation

/// **What the command-line tool prints is plain ASCII punctuation** (FC10): a terminal, a pipe
/// into `grep`, or a log a script greps should not have to match `’` where it typed `'`.
///
/// **The tool's own words are written in ASCII; only a shared sentence is folded.** The app's
/// strings stay curly, and this tool drops some of them into its lines: a row's description, a
/// provider's name rule, a Cocoa error. Each such site passes the sentence through `ascii(_:)`
/// before interpolating it. Everything else — every path, file name, provider id and display
/// name — is interpolated raw, so it prints exactly as it is on disk and pastes back into a shell
/// or a `-L`/`-R` as the same name. The design is fail-safe: a missed `ascii` leaves a curly
/// quote in a line, which is cosmetic; a fold over a name would print a different name, and
/// "Mom’s Files" folded to "Mom's Files" is one `-L` then refuses.
///
/// **A shared sentence that quotes a name keeps the name** (`ascii(_:keeping:)`): a row's
/// description names both providers and may quote both on-disk spellings or a link inside a
/// folder; a Cocoa error quotes the file. The caller lists the names it knows the sentence can
/// carry, and only the words around them fold.
///
/// **JSON is not folded.** `scan --json` and `restructure --json` are the stable, machine-read
/// formats: their paths must be the real paths, and a folded `“` would land as a bare `"` inside a
/// JSON string and break the document.
///
/// **Known limit:** a shared sentence that quotes a name the caller did not list folds that name.
/// The one such case today is a Cocoa error that quotes a file under a display name other than its
/// on-disk leaf, as Finder shows it.
public enum CLIOutput {

    /// `text` with curly quotes and apostrophes, the ellipsis and the en and em dashes folded to
    /// ASCII. Everything else passes through, the arrows and `·` the tool draws included.
    public static func ascii(_ text: String) -> String {
        ascii(text, keeping: [])
    }

    /// `text` folded as `ascii(_:)` does, except inside any occurrence of one of `names`, which is
    /// left exactly as it is. Matched scalar by scalar, so a name matches only its own spelling —
    /// not a canonically equivalent one, which is a different name on disk.
    public static func ascii(_ text: String, keeping names: [String]) -> String {
        // Most lines have nothing to fold: every folded character is at or above U+2013.
        guard text.unicodeScalars.contains(where: { $0.value >= 0x2013 }) else { return text }
        let scalars = Array(text.unicodeScalars)
        var kept = [Bool](repeating: false, count: scalars.count)
        for name in names {
            let target = Array(name.unicodeScalars)
            // A name with nothing foldable in it would come out the same either way.
            guard !target.isEmpty, target.count <= scalars.count,
                  target.contains(where: { folded($0) != nil }) else { continue }
            for start in 0...(scalars.count - target.count)
            where scalars[start..<(start + target.count)].elementsEqual(target) {
                for i in start..<(start + target.count) { kept[i] = true }
            }
        }
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            if !kept[i], let ascii = folded(scalar) {
                out.append(contentsOf: ascii.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// What one typographic scalar folds to, or nil when it is printed as it is.
    private static func folded(_ scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x2018, 0x2019: return "'"       // ‘ ’
        case 0x201C, 0x201D: return "\""      // “ ”
        case 0x2026: return "..."             // …
        case 0x2013, 0x2014: return "-"       // – —
        default: return nil
        }
    }

    /// **An error ArgumentParser will print, with its message folded.** A command body's error
    /// that is not ours to classify (`CLIExitMapping`'s `.rethrow` — say a copy's Cocoa error
    /// under `--fail-fast`, "The file “a.txt” couldn’t be opened") is printed by ArgumentParser
    /// itself, as `Error: <message>`. This reads the message the way ArgumentParser does — a
    /// `LocalizedError`'s description, else an `NSError`'s — and, when folding changes it, returns
    /// an error carrying the folded message instead; otherwise the error itself. Either way the
    /// exit code is the same: ArgumentParser exits 1 for any error not its own.
    ///
    /// An error already folded is passed on as itself, so the runner can fold a copy's error with
    /// the file's names kept and the shell's second pass leaves them alone.
    public static func foldedForPrinting(_ error: Error, keeping names: [String] = []) -> Error {
        if error is FoldedError { return error }
        let message: String
        if let described = (error as? LocalizedError)?.errorDescription {
            message = described
        } else if type(of: error) is NSError.Type {
            message = (error as NSError).localizedDescription
        } else {
            return error
        }
        let folded = ascii(message, keeping: names)
        return folded == message ? error : FoldedError(errorDescription: folded)
    }

    /// An error message after `foldedForPrinting`.
    public struct FoldedError: LocalizedError, Equatable {
        public let errorDescription: String?
    }
}
