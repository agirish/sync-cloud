import Foundation

/// What the command-line tool prints uses plain ASCII punctuation, so a terminal, a `grep` or a
/// script reading the output never has to match `’` where it typed `'`.
///
/// The tool's own words are written in ASCII. Where a line carries one of the app's curly
/// sentences (a row's description, a provider's name rule, a Cocoa error), that site passes it
/// through `ascii(_:)`. Paths, file names, provider ids and display names are interpolated raw, so
/// they print as on disk and paste back into a shell or a `-L`/`-R` as the same name. A missed
/// fold is cosmetic; a fold over a name prints a different name, which `-L` then refuses.
///
/// A shared sentence that quotes names keeps them (`ascii(_:keeping:)`): the caller lists the
/// names it knows the sentence can carry, and only the words around them fold. A name it did not
/// list is folded; today that is a Cocoa error quoting a file under a display name other than its
/// on-disk leaf, as Finder shows it.
///
/// JSON is not folded: `scan --json` and `restructure --json` must carry the real paths, and a
/// folded `“` would land as a bare `"` inside a JSON string and break the document.
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

    /// An error ArgumentParser will print, with its message folded. An error that is not ours to
    /// classify (`CLIExitMapping`'s `.rethrow`, such as a copy's Cocoa error under `--fail-fast`)
    /// is printed by ArgumentParser as `Error: <message>`. This reads the message as ArgumentParser
    /// does (a `LocalizedError`'s description, else an `NSError`'s) and returns an error carrying
    /// the folded message when folding changes it, otherwise the error itself. The exit code is 1
    /// either way.
    ///
    /// An already folded error passes through as itself, so a copy's error the runner folded with
    /// the file's names kept survives the shell's second pass.
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
