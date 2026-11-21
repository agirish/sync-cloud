import Events
import Foundation

/// Which reading of a PDF page Read Documents goes by: its text layer, or its picture as Vision
/// reads it. The rule is here, on lines, so it is tested without Vision; the app supplies the
/// renders (``VaultDocumentReading``).
public enum VaultPageSource {

    /// A text layer of no more letters than this is a blank scan's stray marks, and says nothing.
    public static let leastText = 40
    /// A layer of no more letters than this may be only what was put on a scan after it was made:
    /// a signing service's envelope ID, a fax header, a page footer. A full page of text is a
    /// typed page, or a scan its scanner already read.
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

    /// The page's lines, or nil when it has no text layer and its picture could not be read.
    ///
    /// The text layer's, when it has one; but a scan under a short layer the readers find no
    /// number in (``stampAtMost``) is read from its picture as well, and that reading is taken
    /// when it gives a number: a scanned passport page a signing service stamped has the stamp for
    /// its whole layer. Only then, or every typed page with nothing to find would cost a second.
    /// `path` is the file's and `roots` the read folders, for asking the readers what a reading
    /// gives.
    public static func lines(textLayer: String, from path: String, under roots: [String] = [],
                             picture: Picture) -> [String]? {
        let letters = textLayer.filter { !$0.isWhitespace }.count
        guard letters > leastText else { return seen(picture, from: path, under: roots) }
        var layer = textLayer.components(separatedBy: .newlines)
        func givesANumber(_ lines: [String]) -> Bool {
            !VaultReading.read(pages: [lines], from: path, under: roots).finds.isEmpty
        }
        if letters <= stampAtMost, !givesANumber(layer), picture.isScan() {
            if let seen = seen(picture, from: path, under: roots), givesANumber(seen) {
                Logger.shared.debug("Vault: a scan under a short text layer was read from its picture")
                return seen
            }
            Logger.shared.debug("Vault: a scan under a short text layer gave no number from its picture either")
        }
        // A scanner's text layer carries the words, never a barcode: a license back is rendered
        // once for its barcode alone.
        if VaultReading.wantsSharperRead(layer) {
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
        guard var lines = picture.read(false) else { return nil }
        if VaultReading.wantsSharperRead(lines), let again = picture.read(true) {
            lines = again
            Logger.shared.debug("Vault: a page was read again at 4000 px; "
                                + (VaultReading.wantsSharperRead(lines) ? "still nothing read" : "now read"))
        }
        if let ink = picture.inkOnly() {
            let taken = inkKeepsEverything(VaultReading.read(pages: [lines], from: path, under: roots).finds,
                                           VaultReading.read(pages: [ink], from: path, under: roots).finds)
            Logger.shared.debug("Vault: a scan on colored paper was read in its ink alone; "
                                + (taken ? "that reading was taken" : "the first reading stands"))
            if taken { lines = ink }
        }
        return lines
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
