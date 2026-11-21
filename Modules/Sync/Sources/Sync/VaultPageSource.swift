import Events
import Foundation

/// Which reading of a PDF page Read Documents goes by: its text layer, or its picture as Vision
/// reads it. The rule is here, on lines, so it is tested without Vision; the app supplies the
/// renders (``VaultDocumentReading``).
public enum VaultPageSource {

    /// A text layer of no more letters than this is a blank scan's stray marks, and says nothing.
    public static let leastText = 40
    /// A layer of no more letters than this may be only what was put on a scan after it was made:
    /// a signing service's envelope ID, a case number, typed fields. Under one, a scan is read
    /// from its picture even when the layer gives a number.
    public static let stampAtMost = 400

    /// How the app reads a page's picture. Each is asked only when the rule needs it: a render
    /// and a recognition cost about a second.
    public struct Picture {
        /// Whether the page draws a picture large enough to be a scan of it.
        public var isScan: () -> Bool
        /// Vision's lines, any license barcode's text after them; from a render of about 4000
        /// pixels when `sharper`, else about 2400. Nil when the page could not be rendered or
        /// recognised, which is not a page with no text.
        public var read: (_ sharper: Bool) -> [String]?
        /// The barcodes alone, from the sharper render.
        public var barcodes: () -> [String]
        /// Vision's lines from the picture with everything but dark, grey ink turned white, for a
        /// scan on colored security paper; nil for any other, which is never read this way. A
        /// Social Security card's red pattern runs through its type, and Vision reads the
        /// pattern's strokes as letters: DANI's I, crossed by red, comes out a T.
        public var inkOnly: () -> [String]?

        public init(isScan: @escaping () -> Bool, read: @escaping (_ sharper: Bool) -> [String]?,
                    barcodes: @escaping () -> [String], inkOnly: @escaping () -> [String]? = { nil }) {
            self.isScan = isScan
            self.read = read
            self.barcodes = barcodes
            self.inkOnly = inkOnly
        }
    }

    /// The page's lines, or nil when its picture could not be read and it has no text layer, or
    /// one that says nothing.
    /// `path` is the file's and `roots` the read folders, for asking the readers what a reading
    /// gives.
    ///
    /// A page that is typed, with no scan on it, is its text layer and nothing else: most pages
    /// are, and a render and a recognition cost about a second. A page that draws a scan is read
    /// from its picture as well when its layer may not be the whole of it:
    ///
    /// - The layer gives the readers no number, whatever its length: a signing service's stamp
    ///   over a scanned passport, a scanner's own text that garbled the number, a bill whose
    ///   font maps to nothing. Vision's reading is taken when it gives one. On the owner's
    ///   papers that was 61 of 592 full pages, and 99 short ones.
    /// - The layer is short (``stampAtMost``) and gives a number: a case number stamped on the
    ///   scan of something else. Vision's reading is taken when it gives every number the layer
    ///   does and more; both, when each gives numbers of kinds the other lacks. When the two give
    ///   different numbers of one kind, one of them misread it, and the layer's is kept: text
    ///   that was typed is exact.
    ///
    /// A full page of text that gives a number is trusted as it is: there Vision more often
    /// lost the layer's number than added one (56 pages against 11).
    public static func lines(textLayer: String, from path: String, under roots: [String] = [],
                             picture: Picture) -> [String]? {
        let letters = textLayer.filter { !$0.isWhitespace }.count
        guard letters > leastText else { return seen(picture, from: path, under: roots) }
        var layer = textLayer.components(separatedBy: .newlines)
        /// The numbers a reading gives, by what kind each is.
        func numbers(_ finds: [VaultFind]) -> [String: VaultCategory] {
            Dictionary(finds.map { (VaultReading.normalized($0.value), $0.category) }, uniquingKeysWith: { first, _ in first })
        }
        let typed = VaultReading.read(pages: [layer], from: path, under: roots)
        let fromLayer = numbers(typed.finds)
        var readSharper = false
        if fromLayer.isEmpty || letters <= stampAtMost, picture.isScan() {
            guard let seen = look(at: picture, from: path, under: roots) else {
                // Vision refuses requests for minutes at a time. A layer that gives or names a
                // number is kept. One that says nothing is no reading of the page: it is
                // unreadable, as a page with no layer is, and tried again rather than marked read.
                guard typed.finds.isEmpty, typed.mentions.isEmpty else { return layer }
                Logger.shared.debug("Vault: a scan under a text layer could not be read from its picture")
                return nil
            }
            readSharper = seen.sharper
            let fromPicture = numbers(VaultReading.read(pages: [seen.lines], from: path, under: roots).finds)
            let added = fromPicture.filter { fromLayer[$0.key] == nil }
            let missed = fromLayer.filter { fromPicture[$0.key] == nil }
            // Counts and kinds of reading only, here and below: never what was read.
            if added.isEmpty {
                Logger.shared.debug("Vault: a scan under a text layer gave no more from its picture")
            } else if missed.isEmpty {
                Logger.shared.debug("Vault: a scan under a text layer was read from its picture")
                return seen.lines
            } else if Set(added.values).isDisjoint(with: missed.values) {
                Logger.shared.debug("Vault: a scan under a text layer was read from its picture and its layer")
                // Kept apart by an empty line, so no rule pairs a line of one with a line of the other.
                return seen.lines + [""] + layer
            } else {
                Logger.shared.debug("Vault: a scan's picture and its text layer disagreed; the layer was kept")
            }
        }
        // A scanner's text layer carries the words, never a barcode: a license back is rendered
        // once for its barcode alone, unless the sharper read above already looked for it.
        if !readSharper, VaultReading.wantsSharperRead(layer) {
            let decoded = picture.barcodes()
            layer += decoded
            Logger.shared.debug("Vault: a license back was rendered for its barcode; "
                                + (decoded.isEmpty ? "none decoded" : "decoded"))
        }
        return layer
    }

    /// The picture as Vision reads it: what a page with no text layer, or a photo or scan
    /// saved as an image, is read as. A Social Security card's small type runs a digit in at
    /// 2400 pixels, and a license back's barcode can fail to decode; both read true at about
    /// 4000. Only such a page, with nothing read from it, is read again.
    ///
    /// A scan on colored security paper is read once more in its ink alone (``Picture/inkOnly``),
    /// and that reading is taken when it finds every number the first did, and one at least: it
    /// can only make the words around them truer (a name, a label), never lose a number. Where
    /// the ink alone drops a number printed in color, the first reading stands.
    public static func seen(_ picture: Picture, from path: String, under roots: [String] = []) -> [String]? {
        look(at: picture, from: path, under: roots)?.lines
    }

    /// ``seen(_:from:under:)``, and whether it took the sharper render, which looks for a
    /// license's barcode too.
    private static func look(at picture: Picture, from path: String,
                             under roots: [String]) -> (lines: [String], sharper: Bool)? {
        guard var lines = picture.read(false).map({ $0.map(zeroed) }) else { return nil }
        var sharper = false
        if VaultReading.wantsSharperRead(lines), let again = picture.read(true).map({ $0.map(zeroed) }) {
            lines = again
            sharper = true
            Logger.shared.debug("Vault: a page was read again at 4000 px; "
                                + (VaultReading.wantsSharperRead(lines) ? "still nothing read" : "now read"))
        }
        if let ink = picture.inkOnly().map({ $0.map(zeroed) }) {
            let taken = inkKeepsEverything(VaultReading.read(pages: [lines], from: path, under: roots).finds,
                                           VaultReading.read(pages: [ink], from: path, under: roots).finds)
            Logger.shared.debug("Vault: a scan on colored paper was read in its ink alone; "
                                + (taken ? "that reading was taken" : "the first reading stands"))
            if taken { lines = ink }
        }
        return (lines, sharper)
    }

    /// A line Vision read, with each "Ø" beside a digit put back to the zero it is. A visa foil
    /// prints its zeros slashed; one read as the letter stopped a fourteen-digit Control Number
    /// at its eleventh, and the visa was kept under those eleven. A name's Ø has no digit beside
    /// it and stays.
    static func zeroed(_ line: String) -> String {
        let slashed: Set<Character> = ["Ø", "ø", "∅", "⌀"]
        guard line.contains(where: slashed.contains) else { return line }
        var letters = Array(line)
        func isDigit(_ index: Int) -> Bool { letters.indices.contains(index) && letters[index].isASCII && letters[index].isNumber }
        // Again until nothing changes, so a run of them ("ØØ7") is put back from its digit outward.
        var changed = true
        while changed {
            changed = false
            for index in letters.indices where slashed.contains(letters[index]) && (isDigit(index - 1) || isDigit(index + 1)) {
                letters[index] = "0"
                changed = true
            }
        }
        return String(letters)
    }

    /// Whether the ink-alone reading keeps all the first one read: every number it found, each
    /// with as much known about it (a name, a birth date, an issuer, its dates and every detail
    /// it carried), and a number at least. What it says may differ (DANT read again as DANI);
    /// what it knows may not shrink: a passport photo's issue date printed in color, lost with
    /// the color, keeps the first reading.
    static func inkKeepsEverything(_ first: [VaultFind], _ inked: [VaultFind]) -> Bool {
        guard !inked.isEmpty else { return false }
        let byNumber = Dictionary(inked.map { (VaultReading.normalized($0.value), $0.facts) }, uniquingKeysWith: { a, _ in a })
        return first.allSatisfy { find in
            guard let kept = byNumber[VaultReading.normalized(find.value)] else { return false }
            let was = find.facts
            func keeps<T>(_ path: KeyPath<VaultReadFacts, T?>) -> Bool { was[keyPath: path] == nil || kept[keyPath: path] != nil }
            return keeps(\.holder) && keeps(\.born) && keeps(\.issuer) && keeps(\.dated) && keeps(\.validUntil)
                && Set(was.details.map(\.label)).isSubset(of: Set(kept.details.map(\.label)))
        }
    }
}
