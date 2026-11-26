import Events
import Foundation

/// Which reading of a PDF page Read Documents goes by: its text layer, or its picture as Vision
/// reads it. The rule is here, on lines, so it is tested without Vision; the app supplies the
/// renders (``VaultDocumentReading``).
public enum VaultPageSource {

    /// A text layer of no more letters than this, giving and naming no number, is a blank scan's
    /// stray marks.
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
        /// pattern's strokes as letters: DANI's I, crossed by red, comes out a T. From the sharper
        /// render when `sharper`, as the first reading needed (VT88): read at 2400 pixels, a card
        /// that only read at 4000 lost its number again.
        public var inkOnly: (_ sharper: Bool) -> [String]?

        public init(isScan: @escaping () -> Bool, read: @escaping (_ sharper: Bool) -> [String]?,
                    barcodes: @escaping () -> [String], inkOnly: @escaping (_ sharper: Bool) -> [String]? = { _ in nil }) {
            self.isScan = isScan
            self.read = read
            self.barcodes = barcodes
            self.inkOnly = inkOnly
        }
    }

    /// How one page was read.
    public struct Reading: Equatable, Sendable {
        /// The page's lines.
        public var lines: [String]
        /// Its other reading, when both its picture and its text layer were read and each says
        /// something the other does not. A page of its own for the readers, never joined to
        /// ``lines``: a rule that looks at a whole page (is this a form, whose notice is this)
        /// would take the two for one document.
        public var also: [String]?
        /// How the page was read, counted for the read's summary (VT25): never part of what it says,
        /// so two readings of the same lines are equal however they were come by.
        public var notes = VaultReadNotes()
        /// Its picture was asked for and could not be read (Vision refusing): the page is its text
        /// layer for now, and its file is not marked read, so the picture is tried again (VT54).
        public var pictureUnread = false

        public init(lines: [String], also: [String]? = nil, notes: VaultReadNotes = VaultReadNotes(),
                    pictureUnread: Bool = false) {
            self.lines = lines
            self.also = also
            self.notes = notes
            self.pictureUnread = pictureUnread
        }

        public static func == (a: Reading, b: Reading) -> Bool { a.lines == b.lines && a.also == b.also }
    }

    /// The page as read, or nil when its picture could not be read and it has no text layer, or
    /// one that says nothing. `path` is the file's and `roots` the read folders, for asking the
    /// readers what a reading gives.
    ///
    /// A page that is typed, with no scan on it, is its text layer: most pages are, and a render
    /// and a recognition cost about a second. (Only a typed license back is rendered, for its
    /// barcode, and a page whose whole text is forty letters or fewer.) A page that draws a scan
    /// is read from its picture as well when its layer may not be the whole of it:
    ///
    /// - the layer gives the readers no number, whatever its length: a signing service's stamp
    ///   over a scanned passport, a scanner's own text that garbled the number, a bill whose
    ///   font maps to nothing. On the owner's papers that was 61 of 592 full pages, and 99
    ///   short ones;
    /// - the layer is short (``stampAtMost``) and gives a number: a case number stamped on the
    ///   scan of something else.
    ///
    /// A reading says more than the other when it reads a number the other does not, names one
    /// the other never says, or knows more about one both read (whose it is, its dates, a
    /// license's barcode). Where only the picture says more, the picture is the page; where
    /// only the layer does, or neither, the layer. Where each says more than the other, both
    /// are kept (``Reading/also``), as two pages and never joined into one: neither reading is
    /// dropped while it says something of its own. When they give different numbers of one
    /// kind, there is no telling a stamp, which is exact, from a scanner's own reading, which
    /// is not; both numbers are kept, and each waits to be confirmed like any other.
    ///
    /// A full page of text that gives a number is trusted as it is: there Vision more often
    /// lost the layer's number than added one (56 pages against 11).
    public static func reading(textLayer: String, from path: String, under roots: [String] = [],
                               picture: Picture) -> Reading? {
        let letters = textLayer.filter { !$0.isWhitespace }.count
        // A typed layer's slashed zeros too: a font can map a slashed 0 to "Ø" (VT88).
        var layer = textLayer.components(separatedBy: .newlines).map(zeroed)
        /// What a reading gives: its finds, their numbers, and every number it gives or names.
        func read(_ lines: [String], already: (finds: [VaultFind], mentions: [VaultMention])? = nil)
            -> (finds: [VaultFind], numbers: Set<String>, any: Set<String>) {
            let read = already ?? VaultReading.read(pages: [lines], from: path, under: roots)
            let numbers = Set(read.finds.map { VaultReading.normalized($0.value) })
            return (read.finds, numbers, numbers.union(read.mentions.map { VaultReading.normalized($0.value) }))
        }
        let typed = read(layer)
        // A few letters that say nothing are a blank scan's stray marks, and the page is its
        // picture. A few that give a number ("Receipt Number LIN…", 26 letters) are a stamp.
        guard letters > leastText || !typed.any.isEmpty else {
            return noted(picture, from: path, under: roots)
        }
        // Whether the sharper read was made: it looks for a license's barcode too.
        var readSharper = false
        var notes = VaultReadNotes()
        // So short a layer is on a scan, whatever the file's pictures say.
        if typed.numbers.isEmpty || letters <= stampAtMost, letters <= leastText || picture.isScan() {
            guard let seen = look(at: picture, from: path, under: roots) else {
                // Vision can refuse requests for minutes at a time. A layer that gives or names
                // a number is kept. One that says nothing is no reading of the page: the page
                // is left out, as one with no layer is, and a file with no page read at all is
                // tried again on the next read rather than marked read.
                guard typed.any.isEmpty else { return Reading(lines: layer, pictureUnread: true) }
                Logger.shared.debug("Vault: a scan under a text layer could not be read from its picture")
                return nil
            }
            readSharper = seen.sharper
            let fromPicture = seen.notes
            let pictured = read(seen.lines, already: seen.read)
            /// Whether `one` says something `other` does not: a number it reads that the other
            /// does not read, one it names that the other never says, or more about a number
            /// both read (whose it is, its dates, a license's barcode).
            func saysMore(_ one: (finds: [VaultFind], numbers: Set<String>, any: Set<String>),
                          than other: (finds: [VaultFind], numbers: Set<String>, any: Set<String>)) -> (new: Bool, more: Bool) {
                let new = !one.numbers.isSubset(of: other.numbers) || !one.any.isSubset(of: other.any)
                let shared = one.finds.filter { other.numbers.contains(VaultReading.normalized($0.value)) }
                return (new, new || (!shared.isEmpty && !keepsEverything(shared, other.finds)))
            }
            let picture = saysMore(pictured, than: typed), text = saysMore(typed, than: pictured)
            // Counts and kinds of reading only, here and below: never what was read.
            if picture.more {
                Logger.shared.debug("Vault: a scan under a text layer was read from its picture"
                                    + (text.more ? "; the two readings are kept as two pages" : ""))
                guard text.more else { return Reading(lines: seen.lines, notes: fromPicture) }
                // The one with a number of its own is the page; with neither, what was typed.
                return picture.new ? Reading(lines: seen.lines, also: layer, notes: fromPicture)
                    : Reading(lines: layer, also: seen.lines, notes: fromPicture)
            }
            Logger.shared.debug("Vault: a scan under a text layer gave no more from its picture")
            // The layer is the page; a sharper render made on the way is still counted.
            notes.sharper = fromPicture.sharper
        }
        // A scanner's text layer carries the words, never a barcode: a license back is rendered
        // once for its barcode alone. Not when the sharper read above already looked: had it
        // decoded one, that reading would say more than the layer and be the page.
        if !readSharper, VaultReading.wantsSharperRead(layer) {
            let decoded = picture.barcodes()
            layer += decoded
            notes.sharper = 1
            Logger.shared.debug("Vault: a license back was rendered for its barcode; "
                                + (decoded.isEmpty ? "none decoded" : "decoded"))
        }
        return Reading(lines: layer, notes: notes)
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

    /// ``seen(_:from:under:)`` as a reading, with how it was read (VT25).
    public static func noted(_ picture: Picture, from path: String, under roots: [String] = []) -> Reading? {
        look(at: picture, from: path, under: roots).map { Reading(lines: $0.lines, notes: $0.notes) }
    }

    /// ``seen(_:from:under:)``, whether it took the sharper render, which looks for a license's
    /// barcode too, and what the lines read as when a colored page's two readings were weighed
    /// (nil otherwise), so they are not read once more.
    private static func look(at picture: Picture, from path: String, under roots: [String])
        -> (lines: [String], sharper: Bool, read: (finds: [VaultFind], mentions: [VaultMention])?, notes: VaultReadNotes)? {
        guard var lines = picture.read(false).map({ $0.map(zeroed) }) else { return nil }
        var sharper = false
        if VaultReading.wantsSharperRead(lines), let again = picture.read(true).map({ $0.map(zeroed) }) {
            lines = again
            sharper = true
            Logger.shared.debug("Vault: a page was read again at 4000 px; "
                                + (VaultReading.wantsSharperRead(lines) ? "still nothing read" : "now read"))
        }
        var read: (finds: [VaultFind], mentions: [VaultMention])?
        var inkTaken = false
        if let ink = picture.inkOnly(sharper).map({ $0.map(zeroed) }) {
            let first = VaultReading.read(pages: [lines], from: path, under: roots)
            let inked = VaultReading.read(pages: [ink], from: path, under: roots)
            let taken = keepsEverything(first.finds, inked.finds)
            Logger.shared.debug("Vault: a scan on colored paper was read in its ink alone; "
                                + (taken ? "that reading was taken" : "the first reading stands"))
            if taken { lines = ink }
            read = taken ? inked : first
            inkTaken = taken
        }
        var notes = VaultReadNotes()
        notes.fromPicture = 1
        notes.sharper = sharper ? 1 : 0
        notes.inkOnly = inkTaken ? 1 : 0
        return (lines, sharper, read, notes)
    }

    /// A line, with each "Ø" beside a digit put back to the zero it is. A visa foil prints its
    /// zeros slashed; one read as the letter stopped a fourteen-digit Control Number at its
    /// eleventh, and the visa was kept under those eleven; one in "Ø2SEP2Ø14" kept its date from
    /// being read. Not the diameter sign: a lone "Ø" before one to three digits and then a unit
    /// ("Ø12 mm", "Ø10.5mm"), which once read as 012 (VT88). A name's Ø has no
    /// digit beside it and stays.
    ///
    /// Only with a unit: a size alone, "Ø12" at a line's end, is as likely a box's zero or the
    /// end of a date ("2Ø24-Ø3-Ø9", "EXP Ø9/Ø7"), and is a zero (the 2026-11-25 review).
    static func zeroed(_ line: String) -> String {
        let slashed: Set<Character> = ["Ø", "ø", "∅", "⌀"]
        guard line.contains(where: slashed.contains) else { return line }
        let read = Array(line)
        var letters = read
        func isDigit(_ index: Int) -> Bool { letters.indices.contains(index) && letters[index].isASCII && letters[index].isNumber }
        // The diameter shape, judged on the line as read, so a run of slashed zeros ("ØØ71") is
        // never taken for one.
        func isDiameter(_ index: Int) -> Bool {
            // At the line's start, or after a space or a bracket: "2Ø24-Ø3-Ø9" ends in a date's part.
            if index > 0, !read[index - 1].isWhitespace, read[index - 1] != "(" { return false }
            let rest = String(read[(index + 1)...])
            return diameterSign.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil
        }
        // Again until nothing changes, so a run of them ("ØØ7") is put back from its digit outward.
        var changed = true
        while changed {
            changed = false
            for index in letters.indices where slashed.contains(letters[index])
                && (isDigit(index - 1) || isDigit(index + 1)) && !isDiameter(index) {
                letters[index] = "0"
                changed = true
            }
        }
        return String(letters)
    }

    /// What follows a diameter sign: a size of one to three digits, perhaps with a decimal part,
    /// then a unit.
    private static let diameterSign = try! NSRegularExpression(
        pattern: #"^[0-9]{1,3}(?:[.,][0-9]+)?\s*(?:mm|cm|m(?![A-Za-z])|in(?![A-Za-z])|"|″)"#)

    /// Whether a second reading of a page (its ink alone, or its picture against its text layer)
    /// keeps all the first one read: every number it found, each
    /// with as much known about it (a name, a birth date, an issuer, its dates and every detail
    /// it carried), and a number at least. What it says may differ (DANT read again as DANI);
    /// what it knows may not shrink: a passport photo's issue date printed in color, lost with
    /// the color, keeps the first reading.
    static func keepsEverything(_ first: [VaultFind], _ second: [VaultFind]) -> Bool {
        guard !second.isEmpty else { return false }
        let byNumber = Dictionary(second.map { (VaultReading.normalized($0.value), $0.facts) }, uniquingKeysWith: { a, _ in a })
        return first.allSatisfy { find in
            guard let kept = byNumber[VaultReading.normalized(find.value)] else { return false }
            let was = find.facts
            func keeps<T>(_ path: KeyPath<VaultReadFacts, T?>) -> Bool { was[keyPath: path] == nil || kept[keyPath: path] != nil }
            return keeps(\.holder) && keeps(\.born) && keeps(\.issuer) && keeps(\.dated) && keeps(\.validUntil)
                && Set(was.details.map(\.label)).isSubset(of: Set(kept.details.map(\.label)))
        }
    }
}

/// How Read Documents got on with what it opened, counts only (VT25): files passed over and why,
/// pages it could not recognise, and how pages were read. Summed over a read for its summary line.
public struct VaultReadNotes: Equatable, Sendable {
    /// PDFs with a password, passed over: theirs is not the Vault's to ask for.
    public var locked = 0
    /// Files that could not be opened at all.
    public var unopenable = 0
    /// Pages Vision could not recognise: left out, or kept as their text layer and tried again.
    public var unrecognised = 0
    /// Pages read from their picture rather than their text layer.
    public var fromPicture = 0
    /// Pages rendered at 4000 pixels: read again sharper, or for a license's barcode.
    public var sharper = 0
    /// Pages on colored paper whose reading in their ink alone was taken.
    public var inkOnly = 0
    /// Files over the 60 MB cap, passed over when opened by name (VT81): marked read as they are,
    /// so they are opened again only once they change.
    public var tooLarge = 0

    public init() {}

    public static func + (a: VaultReadNotes, b: VaultReadNotes) -> VaultReadNotes {
        var sum = a
        sum.locked += b.locked; sum.unopenable += b.unopenable; sum.unrecognised += b.unrecognised
        sum.fromPicture += b.fromPicture; sum.sharper += b.sharper; sum.inkOnly += b.inkOnly
        sum.tooLarge += b.tooLarge
        return sum
    }

    /// "; 2 locked, 1 could not be opened, 3 page(s) not recognized; 40 page(s) read from their
    /// picture, 2 rendered sharper, 5 taken in their ink alone": only what is not zero.
    public var summary: String {
        var out = ""
        let skipped = [(locked, "locked"), (unopenable, "could not be opened"), (tooLarge, "over 60 MB"),
                       (unrecognised, "page(s) not recognized")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if !skipped.isEmpty { out += "; " + skipped.joined(separator: ", ") }
        let how = [(fromPicture, "page(s) read from their picture"), (sharper, "rendered sharper"), (inkOnly, "taken in their ink alone")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if !how.isEmpty { out += "; " + how.joined(separator: ", ") }
        return out
    }
}
