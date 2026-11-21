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

    static func lines(_ layer: String, _ picture: VaultPageSource.Picture) -> [String]? {
        VaultPageSource.lines(textLayer: layer, from: path, picture: picture)
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
        let bill = VaultPageSource.lines(
            textLayer: Self.letter.joined(separator: "\n"), from: "/Users/anna/Documents/Home/Utilities/Power/2024/Mar.pdf",
            under: ["/Users/anna/Documents"], picture: Self.picture(Asked(), reads: ["Account Number: 1234 5678 9012"]))
        #expect(bill == ["Account Number: 1234 5678 9012"])
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
    @Test func aScanWhosePictureCouldNotBeReadIsTriedAgain() {
        // Its layer says nothing: unreadable, as a page with no layer is, never read as that layer.
        #expect(Self.lines(Self.stamp, Self.picture(Asked(), reads: nil)) == nil)
        #expect(Self.lines(Self.letter.joined(separator: "\n"), Self.picture(Asked(), reads: nil)) == nil)
        // A layer that gives a number, or names one, is kept: what it says is not lost to a retry.
        #expect(Self.lines(Self.caseStamp, Self.picture(Asked(), reads: nil)) == [Self.caseStamp])
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
        #expect(VaultPageSource.zeroed("no such letter") == "no such letter")
    }

    // MARK: A layer that gives a number

    @Test func aFullPageThatGivesANumberIsTrustedAsItIs() {
        let asked = Asked()
        let page = Self.letter + ["Receipt Number LIN2412345678"]
        #expect(Self.lines(page.joined(separator: "\n"), Self.picture(asked, reads: Self.passport)) == page)
        #expect(asked.reads.isEmpty && asked.scans == 0, "not even asked whether it is a scan")
    }

    @Test func aStampWithANumberDoesNotHideTheScanUnderIt() {
        #expect(Self.numbers([Self.caseStamp]) == ["LIN2412345678"])
        // Vision read the stamp too: its reading has everything, and is the page.
        let both = Self.passport + [Self.caseStamp]
        #expect(Self.lines(Self.caseStamp, Self.picture(Asked(), reads: both)) == both)
        // Vision missed the stamp: the two readings together, an empty line between them.
        let merged = Self.lines(Self.caseStamp, Self.picture(Asked(), reads: Self.passport))
        #expect(merged == Self.passport + ["", Self.caseStamp])
        #expect(Self.numbers(merged) == ["L898902C3", "LIN2412345678"])
        // Vision read nothing new: the layer, untouched.
        #expect(Self.lines(Self.caseStamp, Self.picture(Asked(), reads: [Self.caseStamp])) == [Self.caseStamp])
    }

    @Test func whereTheTwoReadingsDisagreeTheTypedOneIsKept() {
        // One digit of the stamp's number misread by Vision: two receipt numbers, and no telling
        // which from the numbers alone. What was typed is exact.
        let misread = Self.caseStamp.replacingOccurrences(of: "LIN2412345678", with: "LIN2412345673")
        let kept = Self.lines(Self.caseStamp, Self.picture(Asked(), reads: Self.passport + [misread]))
        #expect(kept == [Self.caseStamp])
        #expect(Self.numbers(kept) == ["LIN2412345678"])
    }

    // MARK: The lengths the rule turns on

    @Test func theLayersLengthIsCountedInLettersNotSpaces() {
        // Forty letters or fewer are a blank scan's stray marks: the picture, whatever it is.
        let forty = String(repeating: "x", count: VaultPageSource.leastText)
        #expect(Self.lines(forty + " \n ", Self.picture(Asked(), isScan: false, reads: Self.passport)) == Self.passport)
        #expect(Self.lines(forty + "x", Self.picture(Asked(), isScan: false, reads: Self.passport)) == [forty + "x"])
        // A layer that gives a number is read under only up to four hundred.
        let number = "Receipt Number LIN2412345678 "
        let most = number + String(repeating: "x", count: VaultPageSource.stampAtMost - number.filter { $0 != " " }.count)
        #expect(most.filter { $0 != " " }.count == VaultPageSource.stampAtMost)
        let under = Asked(), over = Asked()
        #expect(Self.numbers(Self.lines(most, Self.picture(under, reads: Self.passport))) == ["L898902C3", "LIN2412345678"])
        #expect(Self.lines(most + "x", Self.picture(over, reads: Self.passport)) == [most + "x"])
        #expect(under.reads == [false] && over.reads.isEmpty)
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
        // The sharper render failed: the barcode is still looked for, once.
        let failed = Asked()
        _ = Self.lines(Self.licenseBack.joined(separator: "\n"),
                       Self.picture(failed, reads: Self.licenseBack, sharper: nil, barcodes: VaultIDReadingTests.barcode))
        #expect(failed.reads == [false, true] && failed.barcodes == 1)
    }
}
