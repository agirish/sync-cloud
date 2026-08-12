import Foundation
import Testing
@testable import Sync

/// `FilingEngine.looksLikeAFileName` — the rule that strips a trailing *document* off a verdict's
/// destination, so `Immigration/OCI/Divit/eOCI.pdf` files into `Immigration/OCI/Divit`.
///
/// It had no test. Its condition was `$0.isASCII && $0.isLetter || $0.isNumber`, which Swift reads
/// as `($0.isASCII && $0.isLetter) || $0.isNumber` — so `isNumber` was asked without the ASCII
/// guard and any non-ASCII digit qualified. Every extension in the shipped fixtures agrees under
/// both spellings, so the whole suite stayed green either way: these are the cases that separate
/// them.
@Suite struct FilingFileNameSegmentTests {

    /// What the rule is for, and must keep doing.
    @Test func anOrdinaryDocumentSegmentIsAFileName() {
        #expect(FilingEngine.looksLikeAFileName("eOCI.pdf"))
        #expect(FilingEngine.looksLikeAFileName("statement.PDF"))
        #expect(FilingEngine.looksLikeAFileName("scan.jpeg"))
        #expect(FilingEngine.looksLikeAFileName("data.7z"))
    }

    /// A folder that merely contains a dot is not a document.
    @Test func aFolderNameWithADotIsNotAFileName() {
        #expect(!FilingEngine.looksLikeAFileName("U.S. Passport"))
        #expect(!FilingEngine.looksLikeAFileName("Dr. Smith"))
        #expect(!FilingEngine.looksLikeAFileName("Form 1099-B"))
        #expect(!FilingEngine.looksLikeAFileName("Immigration"))
    }

    /// **The precedence case.** A non-ASCII digit after the final dot is not an extension, and the
    /// rule's own doc says 1–5 *ASCII* alphanumerics. With the operators mis-grouped these all
    /// answered true, and a real folder — Devanagari, Arabic-Indic, fullwidth or a Roman numeral —
    /// would have been stripped off the destination and the document filed one level up.
    @Test func aNonAsciiDigitIsNotAnExtension() {
        for segment in ["Taxes.٢٠٢٥", "Bills.２０２５", "Notes.Ⅷ", "Chai.½", "Records.१२"] {
            #expect(!FilingEngine.looksLikeAFileName(segment),
                    "“\(segment)” was read as a document and would be stripped off the destination")
        }
    }

    /// And the ASCII digits it is actually about still count.
    @Test func anAsciiNumericExtensionIsStillAFileName() {
        #expect(FilingEngine.looksLikeAFileName("archive.001"))
        #expect(FilingEngine.looksLikeAFileName("part.2"))
    }

    /// The length bounds, so the "1–5" in the doc is a rule rather than a description.
    @Test func theExtensionLengthBoundsHold() {
        #expect(!FilingEngine.looksLikeAFileName("folder."), "an empty extension is not a document")
        #expect(FilingEngine.looksLikeAFileName("a.x"))
        #expect(FilingEngine.looksLikeAFileName("a.abcde"))
        #expect(!FilingEngine.looksLikeAFileName("a.abcdef"), "six characters is past the bound")
    }

    /// The consequence at the level the resolver works: a destination ending in a real document
    /// loses it, one ending in a non-ASCII-digit folder keeps it.
    @Test func theResolverStripsOnlyRealFileNames() throws {
        let existing: Set<String> = ["Immigration", "Immigration/OCI", "Immigration/OCI/Divit",
                                     "Taxes", "Taxes.٢٠٢٥"]
        func resolved(_ path: String) throws -> String {
            let verdict = FilingVerdict(relativePath: path, confidence: .high, reason: "t",
                                        proposesNewFolder: false)
            let dest = try #require(FilingEngine.destination(from: verdict, providerRoot: "/root",
                                                             existingRelative: existing))
            return FilingEngine.relative(dest.path, under: "/root")
        }
        #expect(try resolved("Immigration/OCI/Divit/eOCI.pdf") == "Immigration/OCI/Divit")
        #expect(try resolved("Taxes.٢٠٢٥") == "Taxes.٢٠٢٥",
                "a folder whose name ends in non-ASCII digits was stripped as if it were a document")
    }
}
