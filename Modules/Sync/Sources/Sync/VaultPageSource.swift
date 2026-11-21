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

        public init(isScan: @escaping () -> Bool, read: @escaping (_ sharper: Bool) -> [String]?,
                    barcodes: @escaping () -> [String]) {
            self.isScan = isScan
            self.read = read
            self.barcodes = barcodes
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
        guard letters > leastText else { return seen(picture) }
        var layer = textLayer.components(separatedBy: .newlines)
        func givesANumber(_ lines: [String]) -> Bool {
            !VaultReading.read(pages: [lines], from: path, under: roots).finds.isEmpty
        }
        if letters <= stampAtMost, !givesANumber(layer), picture.isScan() {
            if let seen = seen(picture), givesANumber(seen) {
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

    /// The picture as Vision reads it. A Social Security card's small type runs a digit in at
    /// 2400 pixels, and a license back's barcode can fail to decode; both read true at about
    /// 4000. Only such a page, with nothing read from it, is read again.
    private static func seen(_ picture: Picture) -> [String]? {
        guard var lines = picture.read(false) else { return nil }
        if VaultReading.wantsSharperRead(lines), let again = picture.read(true) {
            lines = again
            Logger.shared.debug("Vault: a page was read again at 4000 px; "
                                + (VaultReading.wantsSharperRead(lines) ? "still nothing read" : "now read"))
        }
        return lines
    }
}
