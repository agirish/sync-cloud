import Foundation
import Testing
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

    @Test func onlyTheRasterKindsGetPixelModes() {
        #expect(PairContentKind.pdf.hasPixelModes)
        #expect(PairContentKind.image.hasPixelModes)
        #expect(!PairContentKind.text.hasPixelModes)
        #expect(!PairContentKind.other.hasPixelModes)
    }
}
