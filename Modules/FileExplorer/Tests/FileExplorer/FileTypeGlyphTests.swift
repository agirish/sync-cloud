import Testing
import Foundation
@testable import FileExplorer

/// The medium classification behind the shared row glyph. The rule that could rot: an unknown
/// or extensionless file must stay `.generic` (quiet, untinted) — the vocabulary makes distinct
/// mediums findable, it must not invent a colorful category for arbitrary data.
@Suite struct FileTypeGlyphTests {

    @Test func theCommonMediumsClassify() {
        #expect(FileTypeGlyph.classify(ext: "pdf", isDirectory: false) == .pdf)
        #expect(FileTypeGlyph.classify(ext: "JPG", isDirectory: false) == .image)
        #expect(FileTypeGlyph.classify(ext: "heic", isDirectory: false) == .image)
        #expect(FileTypeGlyph.classify(ext: "mp3", isDirectory: false) == .audio)
        #expect(FileTypeGlyph.classify(ext: "m4a", isDirectory: false) == .audio)
        #expect(FileTypeGlyph.classify(ext: "mp4", isDirectory: false) == .video)
        #expect(FileTypeGlyph.classify(ext: "mov", isDirectory: false) == .video)
        #expect(FileTypeGlyph.classify(ext: "docx", isDirectory: false) == .wordProcessing)
        #expect(FileTypeGlyph.classify(ext: "pages", isDirectory: false) == .wordProcessing)
        #expect(FileTypeGlyph.classify(ext: "xlsx", isDirectory: false) == .spreadsheet)
        #expect(FileTypeGlyph.classify(ext: "csv", isDirectory: false) == .spreadsheet)
        #expect(FileTypeGlyph.classify(ext: "pptx", isDirectory: false) == .presentation)
        #expect(FileTypeGlyph.classify(ext: "zip", isDirectory: false) == .archive)
    }

    @Test func unknownAndExtensionlessStayGeneric() {
        #expect(FileTypeGlyph.classify(ext: "", isDirectory: false) == .generic)
        #expect(FileTypeGlyph.classify(ext: "xyzzy123", isDirectory: false) == .generic)
        #expect(FileTypeGlyph.tint(for: .generic) == nil)
    }

    @Test @MainActor func theCacheAnswersExactlyAsTheLookupDoes() {
        // The cache must be an invisible optimization: for every kind the vocabulary
        // distinguishes (and the generic fallbacks), cached and direct classification agree.
        for (name, isDir) in [("a.pdf", false), ("b.JPG", false), ("c.mp3", false),
                              ("d.docx", false), ("e.xyzzy", false), ("f", false),
                              ("Reports.pdf", true)] {
            let direct = FileTypeGlyph.classify(ext: (name as NSString).pathExtension,
                                                isDirectory: isDir)
            #expect(FileTypeGlyph.cachedKind(name: name, isDirectory: isDir) == direct,
                    "cache disagrees with classify for \(name)")
            // And again, now that it is warm.
            #expect(FileTypeGlyph.cachedKind(name: name, isDirectory: isDir) == direct)
        }
    }

    @Test func directoriesAreFoldersWhateverTheirName() {
        #expect(FileTypeGlyph.classify(ext: "pdf", isDirectory: true) == .folder)
        #expect(FileTypeGlyph.tint(for: .folder) == nil)
    }

    @Test func everyDistinctMediumCarriesATint() {
        // The findability claim: each named medium must be tinted, or shape alone carries it.
        for kind in [FileTypeGlyph.Kind.pdf, .image, .audio, .video,
                     .wordProcessing, .spreadsheet, .presentation, .archive] {
            #expect(FileTypeGlyph.tint(for: kind) != nil, "\(kind) lost its tint")
        }
    }
}
