import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// Which pair viewer a file gets.
@Suite struct PairContentKindTests {

    @Test func pdfsAndImagesGetTypedViewers() {
        #expect(PairContentKind.classify(ext: "pdf") == .pdf)
        #expect(PairContentKind.classify(ext: "PDF") == .pdf, "the extension is lowercased first")
        for ext in ["jpg", "jpeg", "png", "heic", "tiff", "gif"] {
            #expect(PairContentKind.classify(ext: ext) == .image, "\(ext)")
        }
    }

    @Test func theTextListIsWhatDecidesText() {
        for ext in ["txt", "md", "csv", "json", "swift", "log"] {
            #expect(PairContentKind.classify(ext: ext) == .text, "\(ext)")
        }
    }

    /// **`.rtf` is the reason the text set is a written list rather than `UTType.text`
    /// conformance.** It conforms — and it is markup, not lines: a text diff of one would show a
    /// reader a wall of control words where Quick Look shows them their document.
    @Test func markupThatConformsToTextIsStillNotDiffableText() {
        #expect(PairContentKind.classify(ext: "rtf") == .other)
        #expect(PairContentKind.classify(ext: "webarchive") == .other)
    }

    @Test func everythingElseFallsBackToIndependentPanes() {
        for ext in ["docx", "key", "zip", "mp4", "mp3", "sketch", "", "wat"] {
            #expect(PairContentKind.classify(ext: ext) == .other, "\(ext)")
        }
    }

    @Test func classifyReadsTheExtensionOffAPath() {
        #expect(PairContentKind.classify(path: "/a/b/Report (1).PDF") == .pdf)
        #expect(PairContentKind.classify(path: "/a/b/Makefile") == .other)
    }

    /// **Only the kind with no canvas says nothing synchronises.** A caption on a synced viewer
    /// would be a lie; no caption on an unsynced one is the surface pretending, which is the thing
    /// the whole phasing note exists to avoid.
    @Test func onlyTheUntypedKindWearsTheUnsyncedCaption() {
        #expect(PairContentKind.other.unsyncedCaption != nil)
        for kind in PairContentKind.allCases where kind != .other {
            #expect(kind.unsyncedCaption == nil, "\(kind) claims it does not synchronise")
        }
    }

    // MARK: An image type is only an image if something can decode it

    /// **SVG conforms to `public.image` and ImageIO cannot decode it** — so the typed viewer this
    /// once earned mounted two image views over nil, with no caption, and a difference mode that
    /// spun for ever. Quick Look renders SVG perfectly well, which is what `.other` gets it.
    ///
    /// The premise is asserted first, so this cannot quietly become a test about SVG not being an
    /// image at all: if a future macOS ships an SVG codec, the second half of this fails and says
    /// to re-decide, rather than passing for the wrong reason.
    @Test func svgIsAnImageThatOnlyQuickLookCanRender() throws {
        let svg = try #require(UTType(filenameExtension: "svg"))
        #expect(svg.conforms(to: .image), "premise: SVG still conforms to public.image")
        #expect(!PairContentKind.imageIOCanDecode(svg), "premise: ImageIO still has no SVG codec")
        #expect(PairContentKind.classify(ext: "svg") == .other)
    }

    /// The positive control the test above needs: the decodable check is not simply answering
    /// "no" to everything, which would send every image to Quick Look and silently retire the
    /// image viewer.
    @Test func theOrdinaryImageFormatsAreStillDecodable() throws {
        for ext in ["png", "jpg", "heic", "tiff", "gif"] {
            let type = try #require(UTType(filenameExtension: ext), "\(ext)")
            #expect(PairContentKind.imageIOCanDecode(type), "\(ext) should be decodable")
        }
    }

    /// A camera RAW is the reason this asks ImageIO rather than carrying a list: the answer has to
    /// track whatever codecs the OS actually has, and a written list is what stops covering a
    /// format. The premise is asserted separately from the answer, so that this cannot become a
    /// tautology about the classifier agreeing with itself — if a machine ever lacks the codec the
    /// first line says so, rather than the second quietly expecting `.other`.
    @Test func aCameraRawGetsTheTypedViewer() throws {
        let raw = try #require(UTType(filenameExtension: "arw"))
        #expect(PairContentKind.imageIOCanDecode(raw), "premise: this machine decodes Sony RAW")
        #expect(PairContentKind.classify(ext: "arw") == .image)
    }

    @Test func onlyTheRasterKindsGetPixelModes() {
        #expect(PairContentKind.pdf.hasPixelModes)
        #expect(PairContentKind.image.hasPixelModes)
        #expect(!PairContentKind.text.hasPixelModes)
        #expect(!PairContentKind.other.hasPixelModes)
    }
}
