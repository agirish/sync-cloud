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

    /// `.rtf` is why the text set is a written list, not `UTType.text` conformance: it conforms,
    /// but it is markup, so a text diff would show control words where Quick Look shows the
    /// document.
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

    /// Only the kind with no canvas says nothing synchronises. A caption on a synced viewer would
    /// be false, and none on an unsynced one would let the surface pretend it syncs.
    @Test func onlyTheUntypedKindWearsTheUnsyncedCaption() {
        #expect(PairContentKind.other.unsyncedCaption != nil)
        for kind in PairContentKind.allCases where kind != .other {
            #expect(kind.unsyncedCaption == nil, "\(kind) claims it does not synchronise")
        }
    }

    // MARK: An image type is only an image if something can decode it

    /// SVG conforms to `public.image` but ImageIO can't decode it, so it goes to Quick Look
    /// (`.other`), not two image views over nil. The premise is asserted first: an OS SVG codec
    /// fails it and says to re-decide.
    @Test func svgIsAnImageThatOnlyQuickLookCanRender() throws {
        let svg = try #require(UTType(filenameExtension: "svg"))
        #expect(svg.conforms(to: .image), "premise: SVG still conforms to public.image")
        #expect(!PairContentKind.imageIOCanDecode(svg), "premise: ImageIO still has no SVG codec")
        #expect(PairContentKind.classify(ext: "svg") == .other)
    }

    /// A camera RAW is why this asks ImageIO rather than a list: the answer tracks the OS's codecs.
    /// The premise is asserted apart, so a machine lacking the codec says so.
    @Test func aCameraRawGetsTheTypedViewer() throws {
        let raw = try #require(UTType(filenameExtension: "arw"))
        #expect(PairContentKind.imageIOCanDecode(raw), "premise: this machine decodes Sony RAW")
        #expect(PairContentKind.classify(ext: "arw") == .image)
    }

    /// The drop of the `public.image` umbrella in `decodableTypes(in:)`, which no real listing
    /// exercises, so the listing is supplied: without it SVG and every image type read decodable.
    @Test func anUmbrellaInTheListingDoesNotReadmitEveryImageType() throws {
        let listing: Set<String> = ["public.image", "public.png"]
        let resolved = PairContentKind.decodableTypes(in: listing)
        #expect(!resolved.contains(.image), "the umbrella survived into the resolved list")

        let svg = try #require(UTType("public.svg-image"))
        #expect(!PairContentKind.canDecode(svg, listing: listing, resolved: resolved),
                "a listing naming public.image readmits SVG to the image viewer it cannot fill")

        // The positive control: dropping the umbrella must not cost the listing what it really
        // names, by identifier or by conformance to a concrete type.
        let png = try #require(UTType(filenameExtension: "png"))
        #expect(PairContentKind.canDecode(png, listing: listing, resolved: resolved))
    }

    @Test func onlyTheRasterKindsGetPixelModes() {
        #expect(PairContentKind.pdf.hasPixelModes)
        #expect(PairContentKind.image.hasPixelModes)
        #expect(!PairContentKind.text.hasPixelModes)
        #expect(!PairContentKind.other.hasPixelModes)
    }
}
