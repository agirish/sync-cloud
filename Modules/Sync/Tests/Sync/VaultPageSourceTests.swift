import Foundation
import Testing
@testable import Sync

/// Which reading of a PDF page counts (``VaultPageSource``): its text layer, or its picture.
/// The picture's readings are handed in, so nothing here needs Vision. Every number is made up;
/// the passport lines are ICAO Doc 9303's own example.
@Suite struct VaultPageSourceTests {
    static let path = "/docs/Immigration/Passport/Anna/scan.pdf"
    /// What a signing service stamps on every page it handles: text, over a scan that has none.
    static let stamp = "DocuSign Envelope ID: 1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
    /// A case number stamped on a supporting document: a short layer that does give a number.
    static let caseStamp = "Exhibit 4 to the petition, receipt LIN2412345678, page 3 of 12"
    static let passport = ["PASSPORT", "UTOPIA", VaultReadingTests.nameLine, VaultReadingTests.numberLine]
    /// A full page of text, far past ``VaultPageSource/stampAtMost``, that gives the readers nothing.
    static let letter = (0..<12).map { "Line \($0) of a letter that says nothing the Vault keeps." }

    /// What was asked of the picture: each ask is a render, about a second in the app.
    final class Asked {
        var scans = 0
        var reads: [Bool] = []
        var barcodes = 0
    }

    static func picture(_ asked: Asked, isScan: Bool = true, reads: [String]?, sharper: [String]? = nil,
                        barcodes: [String] = []) -> VaultPageSource.Picture {
        VaultPageSource.Picture(
            isScan: { asked.scans += 1; return isScan },
            read: { again in asked.reads.append(again); return again ? sharper : reads },
            barcodes: { asked.barcodes += 1; return barcodes })
    }

    static func reading(_ layer: String, _ picture: VaultPageSource.Picture) -> VaultPageSource.Reading? {
        VaultPageSource.reading(textLayer: layer, from: path, picture: picture)
    }

    /// The page's own lines, for the cases where there is one reading.
    static func lines(_ layer: String, _ picture: VaultPageSource.Picture) -> [String]? {
        reading(layer, picture)?.lines
    }

    /// The numbers a page gives as the app reads it: each reading a page of its own.
    static func numbers(_ reading: VaultPageSource.Reading?) -> Set<String> {
        guard let reading else { return [] }
        return Set(VaultReading.read(pages: [reading.lines] + (reading.also.map { [$0] } ?? []), from: path).finds.map(\.value))
    }

    static func numbers(_ lines: [String]?) -> Set<String> {
        Set(VaultReading.finds(in: lines ?? [], from: path).map(\.value))
    }

    // MARK: A layer that gives no number

    @Test func aScanUnderAStampIsReadFromItsPicture() throws {
        let asked = Asked()
        let lines = try #require(Self.lines(Self.stamp, Self.picture(asked, reads: Self.passport)))
        #expect(lines == Self.passport)
        #expect(Self.numbers(lines) == ["L898902C3"])
        #expect(asked.reads == [false], "one render, at the usual size")
    }

    @Test func aScanUnderAFullPageOfTextThatGivesNothingIsReadToo() {
        // A scanner's own text that garbled the number, or a bill whose font maps to nothing.
        #expect(Self.letter.joined().count > VaultPageSource.stampAtMost)
        let asked = Asked()
        #expect(Self.lines(Self.letter.joined(separator: "\n"), Self.picture(asked, reads: Self.passport)) == Self.passport)
        #expect(asked.reads == [false])
        // Told by the folder it is filed in, as the app tells it: an account's paper.
        let bill = VaultPageSource.reading(
            textLayer: Self.letter.joined(separator: "\n"), from: "/Users/anna/Documents/Home/Utilities/Power/2024/Mar.pdf",
            under: ["/Users/anna/Documents"], picture: Self.picture(Asked(), reads: ["Account Number: 1234 5678 9012"]))
        #expect(bill == VaultPageSource.Reading(lines: ["Account Number: 1234 5678 9012"]), "a layer that says nothing is not kept beside it")
    }

    @Test func aTypedPageIsNeverRendered() {
        // No scan on it: its text is all there is, whether a line or a page, and whatever it gives.
        for layer in [Self.stamp, Self.letter.joined(separator: "\n"), Self.caseStamp] {
            let asked = Asked()
            #expect(Self.lines(layer, Self.picture(asked, isScan: false, reads: Self.passport))
                    == layer.components(separatedBy: "\n"))
            #expect(asked.reads.isEmpty && asked.barcodes == 0)
        }
    }

    @Test func aPictureThatGivesNothingLeavesTheLayer() {
        let nothing = Asked()
        #expect(Self.lines(Self.stamp, Self.picture(nothing, reads: ["A photograph of a garden"])) == [Self.stamp])
        #expect(nothing.reads == [false])
    }

    /// Vision refuses requests for minutes at a time (2026-11-20: seven registration scans in a
    /// row gave nothing on one read of the owner's folder, and their numbers on the next).
    @Test func aScanWhosePictureCouldNotBeReadIsLeftOutNotReadAsItsLayer() {
        // Its layer says nothing: unreadable, as a page with no layer is, never read as that layer.
        #expect(Self.lines(Self.stamp, Self.picture(Asked(), reads: nil)) == nil)
        #expect(Self.lines(Self.letter.joined(separator: "\n"), Self.picture(Asked(), reads: nil)) == nil)
        // A layer that gives a number, or names one, is kept: what it says is not lost to a retry.
        #expect(Self.lines(Self.caseStamp, Self.picture(Asked(), reads: nil)) == [Self.caseStamp])
        // Kept, and said to be read without its picture: the file is not marked read, so the
        // picture is tried again (the 2026-11-23 review). Read from its picture, it is not.
        #expect(VaultPageSource.reading(textLayer: Self.caseStamp, from: Self.path, picture: Self.picture(Asked(), reads: nil))?.pictureUnread == true)
        #expect(VaultPageSource.reading(textLayer: Self.caseStamp, from: Self.path,
                                        picture: Self.picture(Asked(), reads: [Self.caseStamp]))?.pictureUnread == false)
        let naming = "Enclosed is a copy of the beneficiary's passport, passport number L898902C3, for the file."
        #expect(!VaultReading.read(pages: [[naming]], from: Self.path).mentions.isEmpty, "the fixture names a number")
        #expect(Self.lines(naming, Self.picture(Asked(), reads: nil)) == [naming])
        // A typed page is never rendered, so nothing can fail.
        #expect(Self.lines(Self.stamp, Self.picture(Asked(), isScan: false, reads: nil)) == [Self.stamp])
    }

    /// A foil prints its zeros slashed, and Vision reads one as "Ø": the fourteen digits of a
    /// Control Number stopped at it, and a visa was kept under the eleven before it.
    @Test func aSlashedZeroBetweenDigitsIsAZero() throws {
        let foil = VaultReadingTests.zone("V", number: "H1234567", born: "740812", expires: "290930", country: "USA")
        let seen = ["Control Number", "20241234560Ø01", "Visa Type /Class", "R", "B1/B2"] + foil
        let lines = try #require(Self.lines(Self.stamp, Self.picture(Asked(), reads: seen)))
        #expect(Self.numbers(lines) == ["20241234560001"])
        // A page with no layer, and an image file, are read the same way.
        #expect(Self.numbers(VaultPageSource.seen(Self.picture(Asked(), reads: seen), from: Self.path)) == ["20241234560001"])
        // Only beside a digit: a name keeps its letter.
        #expect(VaultPageSource.zeroed("SØREN 4Ø4 ØØ7 Ø K2Ø") == "SØREN 404 007 Ø K20")
        // VT88: the diameter sign stays, before a size and a unit or the line's end; every other
        // Ø beside a digit is a zero, a foil's dates and a grouped number too (the 2026-11-25 review).
        #expect(VaultPageSource.zeroed("Ø12 mm") == "Ø12 mm")
        #expect(VaultPageSource.zeroed("Ø10.5mm bolt") == "Ø10.5mm bolt")
        // Without a unit it is a zero: a box's, or a date's last part (the second review).
        #expect(VaultPageSource.zeroed("Ø12") == "012")
        #expect(VaultPageSource.zeroed("2Ø24-Ø3-Ø9") == "2024-03-09")
        #expect(VaultPageSource.zeroed("2Ø24/Ø1/Ø5") == "2024/01/05")
        #expect(VaultPageSource.zeroed("VALID THRU 1Ø/Ø5") == "VALID THRU 10/05")
        #expect(VaultPageSource.zeroed("Ø5.Ø3.Ø9") == "05.03.09")
        #expect(VaultPageSource.zeroed("Ø2 SEP Ø9") == "02 SEP 09")
        #expect(VaultPageSource.zeroed("Ø3") == "03")
        // A diameter in brackets, or after words, is still one.
        #expect(VaultPageSource.zeroed("Bolt (Ø8 mm)") == "Bolt (Ø8 mm)")
        #expect(VaultPageSource.zeroed("Ø2SEP2Ø14") == "02SEP2014")
        #expect(VaultPageSource.zeroed("Ø1/Ø5/2Ø24") == "01/05/2024")
        #expect(VaultPageSource.zeroed("Ø12-34-5678") == "012-34-5678")
        #expect(VaultPageSource.zeroed("Ø12 34 5678") == "012 34 5678")
        #expect(VaultPageSource.zeroed("ØØ71") == "0071")
        #expect(VaultPageSource.zeroed("Ø2025123456 7") == "02025123456 7")
        // Slashed zeros with no digit among them are no number.
        #expect(VaultPageSource.zeroed("ØØØØ") == "ØØØØ")
        #expect(VaultPageSource.zeroed("no such letter") == "no such letter")
        // Each sign a slashed zero is read as; and only beside a digit of this script.
        #expect(VaultPageSource.zeroed("1Ø 2ø 3∅ 4⌀") == "10 20 30 40")
        #expect(VaultPageSource.zeroed("\u{0663}Ø") == "\u{0663}Ø")
        // The sharper reading and the ink-alone one are put back the same way.
        let card = VaultIDReadingTests.ssnCard
        let slashed = card.map { $0 == "123-45-6789" ? "123-45-67Ø9" : $0 }
        let runIn = card.map { $0 == "123-45-6789" ? "1234-56-789" : $0 }
        #expect(Self.numbers(Self.reading("", Self.picture(Asked(), reads: runIn, sharper: slashed))) == ["123456709"])
        // In its ink alone the same foil reads with a slashed zero: put back, it keeps the number
        // the first reading had, and is taken; left as read, it would be another number.
        let plain = ["Control Number", "20241234560001"] + foil
        let ink = ["Control Number", "2024123456ØØØ1", "read in its ink alone"] + foil
        let inked = VaultPageSource.Picture(isScan: { true }, read: { _ in plain }, barcodes: { [] }, inkOnly: { _ in ink })
        #expect(VaultPageSource.seen(inked, from: Self.path) == ["Control Number", "20241234560001", "read in its ink alone"] + foil)
    }

    /// How each page was read is noted for the read's summary (VT25), and only as counts: from
    /// its picture, rendered sharper, taken in its ink alone, or rendered for a barcode.
    @Test func eachPageNotesHowItWasRead() {
        // A scan with no text layer: from its picture.
        var notes = Self.reading("", Self.picture(Asked(), reads: Self.passport))?.notes
        #expect(notes?.fromPicture == 1 && notes?.sharper == 0 && notes?.inkOnly == 0)
        // A Social Security card with its number run in: read again sharper.
        let card = VaultIDReadingTests.ssnCard
        let runIn = card.map { $0 == "123-45-6789" ? "1234-56-789" : $0 }
        notes = Self.reading("", Self.picture(Asked(), reads: runIn, sharper: card))?.notes
        #expect(notes?.fromPicture == 1 && notes?.sharper == 1)
        // Colored paper whose ink alone keeps every number: taken.
        let foil = VaultReadingTests.zone("V", number: "H1234567", born: "740812", expires: "290930", country: "USA")
        let plain = ["Control Number", "20241234560001"] + foil
        let ink = ["Control Number", "20241234560001", "read in its ink alone"] + foil
        let inked = VaultPageSource.Picture(isScan: { true }, read: { _ in plain }, barcodes: { [] }, inkOnly: { _ in ink })
        notes = VaultPageSource.noted(inked, from: Self.path)?.notes
        #expect(notes?.inkOnly == 1 && notes?.fromPicture == 1)
        // A full typed page with no scan on it: nothing of the picture.
        let page = Self.letter + ["Receipt Number LIN2412345678"]
        #expect(Self.reading(page.joined(separator: "\n"), Self.picture(Asked(), isScan: false, reads: Self.passport))?.notes
                == VaultReadNotes())
        // A typed license back is rendered once for its barcode: rendered sharper, the layer kept.
        let back = (Self.letter + ["ENDORSEMENTS NONE", "RESTRICTIONS NONE"]).joined(separator: "\n")
        let rendered = Self.reading(back, Self.picture(Asked(), isScan: false, reads: nil, barcodes: ["ANSI 636014"]))
        #expect(rendered?.notes.sharper == 1 && rendered?.notes.fromPicture == 0)
        // The notes never make two readings of the same lines unequal.
        var noted = VaultPageSource.Reading(lines: ["a"])
        noted.notes.fromPicture = 3
        #expect(noted == VaultPageSource.Reading(lines: ["a"]))
    }

    @Test func theNotesAddUpAndSayOnlyWhatIsNotZero() {
        var a = VaultReadNotes(), b = VaultReadNotes()
        a.locked = 2; a.fromPicture = 40; b.unopenable = 1; b.unrecognised = 3; b.sharper = 2; b.inkOnly = 5
        #expect((a + b).summary == "; 2 locked, 1 could not be opened, 3 page(s) not recognized; "
                + "40 page(s) read from their picture, 2 rendered sharper, 5 taken in their ink alone")
        #expect(VaultReadNotes().summary == "")
        var tally = VaultReadTally()
        tally.notes = a
        #expect(tally.summary(seconds: 5).hasSuffix("; 0 new number(s) to confirm; 2 locked; 40 page(s) read from their picture"))
    }

    // MARK: A layer that gives a number

    /// The layer is the page, whatever its picture reads: there Vision more often lost the
    /// layer's number than added one.
    @Test func aFullPageThatGivesANumberIsTrustedAsItIs() {
        let page = Self.letter + ["Receipt Number LIN2412345678"]
        let layer = page.joined(separator: "\n")
        // Typed, with no scan on it: never rendered.
        let typed = Asked()
        #expect(Self.reading(layer, Self.picture(typed, isScan: false, reads: Self.passport)) == VaultPageSource.Reading(lines: page))
        #expect(typed.scans == 1 && typed.reads.isEmpty && typed.barcodes == 0)
        // Over a scan whose picture lost the number, or reads only what the layer does: the layer, alone.
        #expect(Self.reading(layer, Self.picture(Asked(), reads: Self.letter)) == VaultPageSource.Reading(lines: page))
        #expect(Self.reading(layer, Self.picture(Asked(), reads: page)) == VaultPageSource.Reading(lines: page))
        // A digit misread: kept beside the layer, to be confirmed like any other, never in its place.
        let misread = Self.letter + ["Receipt Number LIN2412345673"]
        let beside = Self.reading(layer, Self.picture(Asked(), reads: misread))
        #expect(beside == VaultPageSource.Reading(lines: page, also: misread))
        // Vision refused: the layer is kept, and its picture tried again.
        #expect(Self.reading(layer, Self.picture(Asked(), reads: nil))?.pictureUnread == true)
    }

    /// VT88: a full typed layer over a scan can hold less than the scan: one number where the scan
    /// beneath gives a second. Its picture is read, and kept beside the layer when it says
    /// something the layer does not; the layer stays the page, whatever the picture reads.
    @Test func aFullPageOverAScanKeepsWhatItsPictureAdds() throws {
        let page = Self.letter + ["Receipt Number LIN2412345678"]
        #expect(page.joined().filter { !$0.isWhitespace }.count > VaultPageSource.stampAtMost)
        // The scan gives a second number: both readings, the layer first.
        let asked = Asked()
        let added = try #require(Self.reading(page.joined(separator: "\n"), Self.picture(asked, reads: Self.passport)))
        #expect(added == VaultPageSource.Reading(lines: page, also: Self.passport))
        #expect(Self.numbers(added) == ["L898902C3", "LIN2412345678"])
        #expect(asked.scans == 1 && asked.reads == [false], "one render, at the usual size")
        #expect(added.notes.fromPicture == 1)
        // It says all the layer does and more: still both, never the picture alone.
        let both = Self.passport + ["Receipt Number LIN2412345678"]
        #expect(Self.reading(page.joined(separator: "\n"), Self.picture(Asked(), reads: both))
                == VaultPageSource.Reading(lines: page, also: both))
    }

    @Test func aStampWithANumberDoesNotHideTheScanUnderIt() {
        #expect(Self.numbers([Self.caseStamp]) == ["LIN2412345678"])
        // The picture is the page, and the stamp's own text a second reading beside it: never
        // one page made of both.
        let missed = Self.reading(Self.caseStamp, Self.picture(Asked(), reads: Self.passport))
        #expect(missed == VaultPageSource.Reading(lines: Self.passport, also: [Self.caseStamp]))
        #expect(Self.numbers(missed) == ["L898902C3", "LIN2412345678"])
        // Vision read the stamp too: its reading says all the layer does, and is the page alone.
        let both = Self.passport + [Self.caseStamp]
        #expect(Self.reading(Self.caseStamp, Self.picture(Asked(), reads: both)) == VaultPageSource.Reading(lines: both))
        // Vision read nothing new: the layer, alone.
        #expect(Self.reading(Self.caseStamp, Self.picture(Asked(), reads: [Self.caseStamp]))
                == VaultPageSource.Reading(lines: [Self.caseStamp]))
    }

    /// Joined into one page, a stamp that names a form made the card under it a form, and the
    /// card's number was dropped (`isSocialSecurityCard` reads the whole page).
    @Test func aStampNamingAFormDoesNotCostTheCardUnderIt() {
        let stamp = "Exhibit 2 to Form I-9, receipt LIN2412345678, page 3 of 12"
        #expect(Self.numbers(VaultIDReadingTests.ssnCard + ["", stamp]) == ["LIN2412345678"], "what one page of both loses")
        let reading = Self.reading(stamp, Self.picture(Asked(), reads: VaultIDReadingTests.ssnCard))
        #expect(reading == VaultPageSource.Reading(lines: VaultIDReadingTests.ssnCard, also: [stamp]))
        #expect(Self.numbers(reading) == ["123456789", "LIN2412345678"])
    }

    /// Two numbers of one kind: a misread of the stamp's, another case's notice under it, or a
    /// scanner's own text that is the misread one. Nothing tells them apart, so nothing is
    /// dropped: each waits to be confirmed.
    @Test func whereTheTwoReadingsDisagreeBothAreKept() {
        // Vision misread a digit of the stamp's number: the passport under it is still read.
        let misread = Self.caseStamp.replacingOccurrences(of: "LIN2412345678", with: "LIN2412345673")
        let reading = Self.reading(Self.caseStamp, Self.picture(Asked(), reads: Self.passport + [misread]))
        #expect(reading == VaultPageSource.Reading(lines: Self.passport + [misread], also: [Self.caseStamp]))
        #expect(Self.numbers(reading) == ["L898902C3", "LIN2412345673", "LIN2412345678"])
        // Another case's notice under the stamp: two cases, and both are real.
        let other = Self.reading(Self.caseStamp, Self.picture(Asked(), reads: ["Receipt Number EAC2190012345"]))
        #expect(Self.numbers(other) == ["EAC2190012345", "LIN2412345678"])
        // The layer is the scanner's own reading, and the wrong one: Vision's is not lost to it.
        let bill = "/Users/anna/Documents/Home/Utilities/Power/2024/Mar.pdf"
        let scanned = VaultPageSource.reading(
            textLayer: "Statement for March 2024, page 1 of 2.\nAccount Number: 1234 5678 9072", from: bill,
            under: ["/Users/anna/Documents"], picture: Self.picture(Asked(), reads: ["Account Number: 1234 5678 9012"]))
        let pages = [scanned?.lines ?? []] + (scanned?.also.map { [$0] } ?? [])
        #expect(Set(VaultReading.read(pages: pages, from: bill, under: ["/Users/anna/Documents"]).finds.map(\.value))
                == ["1234 5678 9012", "1234 5678 9072"])
    }

    /// A number the picture only names (a letter quoting a passport number) counts as something
    /// the layer does not say.
    @Test func aNumberThePictureOnlyNamesIsNotLostUnderAStamp() throws {
        let naming = ["Enclosed is a copy of the beneficiary's passport, passport number L898902C3, for the file."]
        #expect(VaultReading.read(pages: [naming], from: Self.path).finds.isEmpty)
        let reading = try #require(Self.reading(Self.stamp, Self.picture(Asked(), reads: naming)))
        #expect(reading == VaultPageSource.Reading(lines: naming))
        #expect(VaultReading.read(pages: [reading.lines], from: Self.path).mentions.map(\.value) == ["L898902C3"])
        // And a number the layer only names is kept beside a picture that gives another.
        let typed = naming[0]
        #expect(Self.reading(typed, Self.picture(Asked(), reads: ["Receipt Number EAC2190012345"]))
                == VaultPageSource.Reading(lines: ["Receipt Number EAC2190012345"], also: naming))
    }

    /// The layer gives the number and the picture the same one, with whose it is: nothing new to
    /// add, but more known. The layer speaks first, and the picture fills what it is silent on.
    @Test func aPictureThatKnowsMoreOfTheLayersNumberIsThePage() throws {
        // The layer gives the number; the picture the same one, and whose it is.
        let typed = "Receipt Number LIN2412345678 is on file with the service center."
        let notice = ["I-797C Receipt Notice", "Receipt Number LIN2412345678", "Applicant ERIKSSON, ANNA", "Form I-539"]
        #expect(Self.reading(typed, Self.picture(Asked(), reads: notice)) == VaultPageSource.Reading(lines: notice))
        // Each knows something of it the other does not: both, the typed one first.
        let dated = "Receipt Number LIN2412345678, I-797A approval notice. Valid from 10/01/2026 to 09/30/2029."
        let reading = try #require(Self.reading(dated, Self.picture(Asked(), reads: notice)))
        #expect(reading == VaultPageSource.Reading(lines: [dated], also: notice))
        let find = try #require(VaultReading.read(pages: [reading.lines, reading.also ?? []], from: Self.path).finds.first)
        #expect(find.holder == "Anna Eriksson" && find.validUntil != nil, "one number, with what each page knows of it")
        // The same number printed another way is the same number, and a picture that knows no
        // more of it is not kept: the layer, alone.
        let bill = "/Users/anna/Documents/Home/Utilities/Power/2024/Mar.pdf"
        let same = VaultPageSource.reading(textLayer: "Statement, page 1 of 2.\nAccount Number: 1234 5678 9012", from: bill,
                                           under: ["/Users/anna/Documents"],
                                           picture: Self.picture(Asked(), reads: ["Account Number: 1234-5678-9012"]))
        #expect(same == VaultPageSource.Reading(lines: ["Statement, page 1 of 2.", "Account Number: 1234 5678 9012"]))
    }

    /// The layer only names the number (a cover sheet: "passport number L898902C3 enclosed");
    /// the picture reads it, from the passport itself. Naming is less than reading: on the
    /// owner's papers two passport scans gave nothing while the two were counted alike.
    @Test func aNumberTheLayerOnlyNamesIsReadFromThePicture() {
        let naming = "Enclosed is a copy of the beneficiary's passport, passport number L898902C3, for the file."
        #expect(Self.numbers([naming]).isEmpty)
        #expect(Self.reading(naming, Self.picture(Asked(), reads: Self.passport)) == VaultPageSource.Reading(lines: Self.passport))
    }

    // MARK: The lengths the rule turns on

    @Test func aFewLettersThatGiveANumberAreAStampNotStrayMarks() {
        let stamp = "Receipt Number LIN2412345678"
        #expect(stamp.filter { $0 != " " }.count <= VaultPageSource.leastText)
        // Over a scan: both, where the stamp was dropped as marks. So short a layer is on a
        // scan whatever the file's pictures say, so the picture is read without asking.
        let asked = Asked()
        let reading = Self.reading(stamp, Self.picture(asked, isScan: false, reads: Self.passport))
        #expect(reading == VaultPageSource.Reading(lines: Self.passport, also: [stamp]))
        #expect(asked.scans == 0 && asked.reads == [false])
        // The picture unreadable: the stamp is still what the page says.
        #expect(Self.reading(stamp, Self.picture(Asked(), reads: nil)) == VaultPageSource.Reading(lines: [stamp]))
    }

    @Test func theLayersLengthIsCountedInLettersNotSpaces() {
        // Forty letters or fewer are a blank scan's stray marks: the picture, whatever it is.
        let forty = String(repeating: "x", count: VaultPageSource.leastText)
        #expect(Self.lines(forty + " \n ", Self.picture(Asked(), isScan: false, reads: Self.passport)) == Self.passport)
        #expect(Self.lines(forty + "x", Self.picture(Asked(), isScan: false, reads: Self.passport)) == [forty + "x"])
        // A layer that gives a number may be a stamp up to four hundred: there a picture with a
        // number of its own is the page. Past it the layer is, the picture beside it (VT88).
        let number = "Receipt Number LIN2412345678 "
        let most = number + String(repeating: "x", count: VaultPageSource.stampAtMost - number.filter { $0 != " " }.count)
        #expect(most.filter { $0 != " " }.count == VaultPageSource.stampAtMost)
        let under = Asked(), over = Asked()
        #expect(Self.reading(most, Self.picture(under, reads: Self.passport)) == VaultPageSource.Reading(lines: Self.passport, also: [most]))
        #expect(Self.reading(most + "x", Self.picture(over, reads: Self.passport))
                == VaultPageSource.Reading(lines: [most + "x"], also: Self.passport))
        #expect(under.reads == [false] && over.reads == [false])
    }

    // MARK: Pages with no layer, and license backs

    @Test func aPageWithNoLayerIsItsPicture() {
        let asked = Asked()
        #expect(Self.lines("", Self.picture(asked, isScan: false, reads: Self.passport)) == Self.passport)
        #expect(asked.reads == [false] && asked.scans == 0)
        #expect(Self.lines("  3 \n", Self.picture(Asked(), reads: nil)) == nil, "not read, which is not a blank page")
        // A card whose number ran a digit in is read again, sharper, and that reading is kept.
        let misread = VaultIDReadingTests.ssnCard.map { $0 == "123-45-6789" ? "1234-56-789" : $0 }
        let again = Asked()
        #expect(Self.lines("", Self.picture(again, reads: misread, sharper: VaultIDReadingTests.ssnCard))
                == VaultIDReadingTests.ssnCard)
        #expect(again.reads == [false, true])
    }

    static let licenseBack = ["CLASS: C - Veh w/GVWR", "ENDORSEMENTS: None", "RESTRICTIONS: None",
                              "This license is issued as a license to drive a motor vehicle"]

    @Test func aTypedLicenseBacksLayerIsGivenItsBarcode() {
        let asked = Asked()
        let lines = Self.lines(Self.licenseBack.joined(separator: "\n"),
                               Self.picture(asked, isScan: false, reads: nil, barcodes: VaultIDReadingTests.barcode))
        #expect(lines == Self.licenseBack + VaultIDReadingTests.barcode)
        #expect(asked.barcodes == 1 && asked.reads.isEmpty)
    }

    @Test func aScannedLicenseBackIsNotRenderedAThirdTime() {
        // Its layer gives nothing, so its picture is read; no barcode, so again at 4000 pixels.
        // That read looked for the barcode too: a third render for it alone would find the same.
        let none = Asked()
        #expect(Self.lines(Self.licenseBack.joined(separator: "\n"),
                           Self.picture(none, reads: Self.licenseBack, sharper: Self.licenseBack)) == Self.licenseBack)
        #expect(none.reads == [false, true] && none.barcodes == 0)
        // The sharper read decodes it: that reading is the page.
        let decoded = Asked()
        let lines = Self.lines(Self.licenseBack.joined(separator: "\n"),
                               Self.picture(decoded, reads: Self.licenseBack, sharper: Self.licenseBack + VaultIDReadingTests.barcode))
        #expect(lines == Self.licenseBack + VaultIDReadingTests.barcode)
        #expect(decoded.reads == [false, true] && decoded.barcodes == 0)
        // A license's front and back on one page, its layer giving the number: the sharper read
        // decodes the barcode. It adds no number, but says more of the layer's (a birth date, an
        // expiry), so it is the page; once it was thrown away, with the barcode in it.
        let front = ["DRIVER LICENSE", "DL D1234567", "LN ERIKSSON", "FN ANNA"] + Self.licenseBack
        #expect(Self.numbers(front) == ["D1234567"] && VaultReading.wantsSharperRead(front), "the fixture is a license with no barcode")
        let both = Asked()
        let given = Self.reading(front.joined(separator: "\n"),
                                 Self.picture(both, reads: front, sharper: front + VaultIDReadingTests.barcode,
                                              barcodes: VaultIDReadingTests.barcode))
        #expect(given == VaultPageSource.Reading(lines: front + VaultIDReadingTests.barcode))
        #expect(both.reads == [false, true] && both.barcodes == 0)
        // The sharper render failed: the barcode is still looked for, once.
        let failed = Asked()
        _ = Self.lines(Self.licenseBack.joined(separator: "\n"),
                       Self.picture(failed, reads: Self.licenseBack, sharper: nil, barcodes: VaultIDReadingTests.barcode))
        #expect(failed.reads == [false, true] && failed.barcodes == 1)
    }
}
