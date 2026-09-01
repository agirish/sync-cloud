import Testing
import Foundation
@testable import FileExplorer

/// Which image sources the preview will draw, and which it refuses.
///
/// **The refusals are the point.** Drawing a local file is the easy half; the rules that matter are
/// the ones that stop the preview fetching a URL or materialising a cloud placeholder because
/// somebody opened a note.
@Suite struct MarkdownImageSourceTests {

    private func temporaryFolder() throws -> String {
        let path = NSTemporaryDirectory() + "mdimg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ name: String, bytes: Int = 8, in folder: String) throws -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func resolve(_ source: String, in folder: String?,
                         cloudOnly: Set<String> = []) -> MarkdownImageSource {
        MarkdownImageSource.resolve(source, relativeTo: folder,
                                    isCloudOnly: { cloudOnly.contains($0) })
    }

    @Test func aFileBesideTheDocumentResolves() throws {
        let folder = try temporaryFolder()
        let path = try write("shot.png", in: folder)
        #expect(resolve("shot.png", in: folder) == .local(path))
    }

    /// A path written the way Markdown writes one with a space in it. Left encoded, this reports
    /// "not found" about a file that is right there.
    @Test func aPercentEncodedPathIsDecoded() throws {
        let folder = try temporaryFolder()
        let path = try write("a b.png", in: folder)
        #expect(resolve("a%20b.png", in: folder) == .local(path))
    }

    @Test func aSubfolderAndAParentBothResolve() throws {
        let folder = try temporaryFolder()
        let nested = (folder as NSString).appendingPathComponent("img")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let path = try write("img/deep.png", in: folder)
        #expect(resolve("img/deep.png", in: folder) == .local(path))

        let sibling = try write("up.png", in: folder)
        #expect(resolve("../up.png", in: nested) == .local(sibling))
    }

    // MARK: The refusals

    @Test func aRemoteURLIsNotFetched() {
        #expect(resolve("https://example.com/a.png", in: "/tmp")
                == .refused("Remote images aren’t downloaded."))
        #expect(resolve("http://example.com/a.png", in: "/tmp")
                == .refused("Remote images aren’t downloaded."))
        #expect(resolve("data:image/png;base64,AAAA", in: "/tmp")
                == .refused("Remote images aren’t downloaded."))
    }

    /// The rule with teeth: drawing this would download somebody's file, over their connection and
    /// into their disk quota, because they opened a note that links to it.
    @Test func aCloudOnlyFileIsRefusedRatherThanMaterialised() throws {
        let folder = try temporaryFolder()
        let path = try write("cloud.png", in: folder)
        let outcome = resolve("cloud.png", in: folder, cloudOnly: [path])
        #expect(outcome == .refused("Not downloaded — the preview won’t fetch it."))
    }

    @Test func aMissingFileAndAFolderAreBothRefused() throws {
        let folder = try temporaryFolder()
        #expect(resolve("nothing.png", in: folder) == .refused("Not found."))
        let nested = (folder as NSString).appendingPathComponent("dir")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        #expect(resolve("dir", in: folder) == .refused("Not found."))
    }

    /// A relative path with nothing to be relative to is a refusal rather than a guess at the
    /// process's working directory — a folder the user has never heard of.
    @Test func aRelativePathWithNoFolderIsRefused() {
        #expect(resolve("shot.png", in: nil) == .refused("Nothing to resolve this path against."))
        #expect(resolve("shot.png", in: "") == .refused("Nothing to resolve this path against."))
    }

    @Test func anEmptySourceIsRefused() {
        #expect(resolve("   ", in: "/tmp") == .refused("No image path."))
    }

    @Test func aFileOverTheCapIsRefusedBeforeDecoding() throws {
        let folder = try temporaryFolder()
        _ = try write("huge.png", bytes: MarkdownImageSource.maxBytes + 1, in: folder)
        guard case .refused(let reason) = resolve("huge.png", in: folder) else {
            Issue.record("an oversized file was accepted")
            return
        }
        #expect(reason.hasPrefix("Too large to draw"), "the refusal read \(reason)")
    }

    /// An absolute path is taken as written — an image kept somewhere central rather than beside
    /// the note is still a local file.
    @Test func anAbsolutePathIsUsedAsIs() throws {
        let folder = try temporaryFolder()
        let path = try write("abs.png", in: folder)
        #expect(resolve(path, in: "/somewhere/else") == .local(path))
        #expect(resolve("file://" + path, in: nil) == .local(path))
    }
}

/// Which paragraphs become pictures.
@Suite struct MarkdownImageBlockTests {

    private func kinds(_ source: String) -> [MarkdownBlock.Kind] {
        MarkdownBlocks.blocks(from: source).map(\.kind)
    }

    @Test func aParagraphThatIsOnlyAnImageBecomesOne() {
        guard case .image(let source, let alt)? = kinds("![the rail](shot.png)\n").first else {
            Issue.record("the image did not become an image block: \(kinds("![a](b.png)\n"))")
            return
        }
        #expect(source == "shot.png")
        #expect(alt == "the rail")
    }

    /// Trailing whitespace parses as an empty text node beside the image; treating that as a mixed
    /// paragraph would send every image in every file back to the placeholder.
    @Test func whitespaceAroundItDoesNotCount() {
        if case .image? = kinds("  ![a](b.png)  \n").first {} else {
            Issue.record("whitespace stopped the image being recognised")
        }
    }

    /// An image inside a sentence stays inline: a sentence is drawn by `Text` concatenation and a
    /// picture is not a `Text`.
    @Test func anImageInASentenceStaysInline() {
        guard case .paragraph(let text)? = kinds("Look at ![this](b.png) closely.\n").first else {
            Issue.record("an inline image was promoted to a block")
            return
        }
        #expect(text.plain.contains("🖼"), "the inline placeholder is gone: \(text.plain)")
    }

    @Test func twoImagesInOneParagraphStayInline() {
        guard case .paragraph? = kinds("![a](1.png) ![b](2.png)\n").first else {
            Issue.record("a row of two images was drawn as one picture")
            return
        }
    }
}
