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
    static let passport = ["PASSPORT", "UTOPIA", VaultReadingTests.nameLine, VaultReadingTests.numberLine]

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

    @Test func aScanUnderAStampIsReadFromItsPicture() throws {
        let asked = Asked()
        let lines = try #require(Self.lines(Self.stamp, Self.picture(asked, reads: Self.passport)))
        #expect(lines == Self.passport)
        #expect(VaultReading.finds(in: lines, from: Self.path).map(\.value) == ["L898902C3"])
        #expect(asked.reads == [false], "one render, at the usual size")
    }

    @Test func aLayerThatGivesANumberIsNeverRendered() {
        let asked = Asked()
        let layer = (Self.passport + [Self.stamp]).joined(separator: "\n")
        #expect(Self.lines(layer, Self.picture(asked, reads: ["never asked for"])) == Self.passport + [Self.stamp])
        #expect(asked.reads.isEmpty && asked.scans == 0 && asked.barcodes == 0)
    }

    @Test func onlyAScanUnderAShortLayerIsRendered() {
        // Text with no picture under it is a page that was typed: its layer is all there is.
        let typed = Asked()
        #expect(Self.lines(Self.stamp, Self.picture(typed, isScan: false, reads: Self.passport)) == [Self.stamp])
        #expect(typed.reads.isEmpty)
        // A full page of text over a picture is a scan its scanner read, or a letter with a
        // photograph: trusted as before, or every such page would cost a second.
        let full = Asked()
        let letter = (0..<12).map { "Line \($0) of a letter that says nothing the Vault keeps." }
        #expect(Self.lines(letter.joined(separator: "\n"), Self.picture(full, reads: Self.passport)) == letter)
        #expect(full.reads.isEmpty && full.scans == 0)
    }

    @Test func aPictureThatGivesNothingLeavesTheLayer() {
        let nothing = Asked()
        #expect(Self.lines(Self.stamp, Self.picture(nothing, reads: ["A photograph of a garden"])) == [Self.stamp])
        #expect(nothing.reads == [false])
        let failed = Asked()
        #expect(Self.lines(Self.stamp, Self.picture(failed, reads: nil)) == [Self.stamp], "Vision failing loses nothing")
    }

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

    @Test func aLicenseBacksLayerIsGivenItsBarcode() {
        let back = ["CLASS: C - Veh w/GVWR", "ENDORSEMENTS: None", "RESTRICTIONS: None",
                    "This license is issued as a license to drive a motor vehicle"]
        let asked = Asked()
        let lines = Self.lines(back.joined(separator: "\n"),
                               Self.picture(asked, isScan: false, reads: nil, barcodes: VaultIDReadingTests.barcode))
        #expect(lines == back + VaultIDReadingTests.barcode)
        #expect(asked.barcodes == 1 && asked.reads.isEmpty)
    }
}
