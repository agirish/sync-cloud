import Testing
import Foundation
import Sync
@testable import FileExplorer

/// **Every door asks about the file a link points to, not the link** (TE206, decision BY).
///
/// The cloud-only check and the size cap read `lstat`/`attributesOfItem`, which describe a link
/// itself — always local, always tiny. So a link to a cloud-only file was opened and downloaded
/// unasked, and a link to a huge text file got past Edit's cap. Each test makes real links in a
/// temp folder and says "cloud-only" through the door's own `isCloudOnly` seam, answering yes only
/// for the TARGET file — matched by inode, so neither the link nor a respelling of the path can
/// satisfy it. Asked about the link, as every door used to ask, each one answers "local".
@MainActor
@Suite(.serialized) final class LinkTargetDoorsTests {

    let folder = NSTemporaryDirectory() + "link-target-doors-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func write(_ text: String, _ name: String) throws -> String {
        let file = path(name)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    private func link(_ name: String, to target: String) throws -> String {
        let link = path(name)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        return link
    }

    private nonisolated static func inode(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// "Cloud-only" for `file` itself and nothing else — not a link to it.
    private nonisolated static func only(_ file: String) -> @Sendable (String) -> Bool {
        let wanted = inode(file)
        return { wanted != nil && inode($0) == wanted }
    }

    // MARK: Edit — text

    /// **A link to a cloud-only text file is refused as not downloaded**, in the words the file
    /// itself gets — and opens when nothing is in the cloud, so the refusal is the cloud answer's.
    @Test func editRefusesALinkToACloudOnlyTextFile() throws {
        let file = try write("in the cloud\n", "notes.md")
        let link = try link("link.md", to: file)
        let cloud = Self.only(file)

        #expect(BoundedTextRead.read(path: link, isCloudOnly: cloud) == .cloudOnly)
        let refused = EditorFileStore.Opened.refused(reason: EditorFileStore.refusal(for: .cloudOnly))
        #expect(EditorFileStore.open(path: file, isCloudOnly: cloud) == refused)
        #expect(EditorFileStore.open(path: link, isCloudOnly: cloud) == refused)
        guard case .editable = EditorFileStore.open(path: link, isCloudOnly: { _ in false }) else {
            Issue.record("the link does not open even with nothing in the cloud")
            return
        }
    }

    /// **A link to a text file over the cap is refused as too large**, measured as the file —
    /// where the link's own size, the length of the path it holds, let it through.
    @Test func editRefusesALinkToATooLargeTextFile() throws {
        let file = path("big.log")
        #expect(FileManager.default.createFile(atPath: file, contents: nil))
        let handle = try #require(FileHandle(forWritingAtPath: file))
        try handle.truncate(atOffset: UInt64(BoundedTextRead.maxBytes + 1))
        try handle.close()
        let link = try link("big-link.log", to: file)

        let tooLarge = BoundedTextRead.Outcome.tooLarge(bytes: BoundedTextRead.maxBytes + 1)
        #expect(BoundedTextRead.read(path: link, isCloudOnly: { _ in false }) == tooLarge)
        #expect(EditorFileStore.open(path: link, isCloudOnly: { _ in false })
                == .refused(reason: EditorFileStore.refusal(for: tooLarge)))
    }

    /// **The Files tab draws a link to a cloud-only file dim, with Download**, as it draws the
    /// file — and a link to a local file stays undimmed.
    @Test func theRailDrawsALinkToACloudOnlyFileAsNotDownloaded() throws {
        let cloudFile = try write("x\n", "cloud.md")
        let localFile = try write("x\n", "local.md")
        let cloudLink = try link("cloud-link.md", to: cloudFile)
        let localLink = try link("local-link.md", to: localFile)

        let rows = EditorRail.survey(in: folder, showsHidden: false, isCloudOnly: Self.only(cloudFile)).rows
        let answer = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0.isCloudOnly) })
        #expect(answer[cloudFile] == true)
        #expect(answer[cloudLink] == true)
        #expect(answer[localLink] == false)
    }

    // MARK: Edit — PDF

    /// **A link to a cloud-only PDF is refused without a parse**, as the PDF itself is.
    @Test func editRefusesALinkToACloudOnlyPDF() throws {
        let file = path("cloud.pdf")
        PDFFixtures.write(file, pages: 1)
        let link = try link("cloud-link.pdf", to: file)
        let pdf = EditorPDFDocument(isCloudOnly: Self.only(file))
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        pdf.open(path: link, log: { _ in })
        #expect(phases == [.refused(EditorPDFDocument.notDownloadedReason)])
        #expect(pdf.document == nil)
        pdf.close()
    }

    // MARK: A pane's selection — PDF Tools and Save as PDF

    /// **Selecting a link to a cloud-only PDF opens nothing**: no PDF Tools, as for the PDF itself,
    /// and the protection probe — which reads the file, on the main thread — never runs. A link to
    /// a local PDF is probed and offered, so the absence is the cloud answer.
    @Test func selectingALinkToACloudOnlyPDFOpensNothing() throws {
        let cloudFile = path("cloud.pdf"), localFile = path("local.pdf")
        PDFFixtures.write(cloudFile, pages: 1)
        PDFFixtures.write(localFile, pages: 1)
        let cloudLink = try link("cloud-link.pdf", to: cloudFile)
        let localLink = try link("local-link.pdf", to: localFile)
        CloudOnlyBadgeCache.record(cloudFile, isCloudOnly: true)
        defer { CloudOnlyBadgeCache.forget(cloudFile) }
        func node(_ path: String, isLink: Bool?) -> FileNode {
            FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                     isSymbolicLink: isLink)
        }

        let probes = PDFMenuEncryption.probes
        // The walk's flag, and a node built without one — which is asked.
        for isLink in [true, nil] as [Bool?] {
            let selected = node(cloudLink, isLink: isLink)
            #expect(PanePDFToolOffer.forSelection([selected]) == nil, "PDF Tools offered (isSymbolicLink \(String(describing: isLink)))")
        }
        #expect(PanePDFToolOffer.forSelection([node(localFile, isLink: false), node(cloudLink, isLink: true)]) == nil)
        #expect(PDFMenuEncryption.probes == probes, "selecting the link probed the file it points to")

        #expect(PanePDFToolOffer.forSelection([node(localLink, isLink: true)]) == .single(path: localLink, encryption: .none))
        #expect(PDFMenuEncryption.probes == probes + 1)
    }

    /// **Save as PDF is not offered for a link to a cloud-only note**, as for the note itself —
    /// and is for a link to a local one. (A PDF is never offered it, so a note is the case to ask.)
    @Test func saveAsPDFIsNotOfferedForALinkToACloudOnlyNote() throws {
        let cloudFile = try write("x\n", "cloud.md"), localFile = try write("x\n", "local.md")
        let cloudLink = try link("cloud-link.md", to: cloudFile)
        let localLink = try link("local-link.md", to: localFile)
        CloudOnlyBadgeCache.record(cloudFile, isCloudOnly: true)
        defer { CloudOnlyBadgeCache.forget(cloudFile) }
        func node(_ path: String) -> FileNode {
            FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false, isSymbolicLink: true)
        }
        #expect(SaveAsPDFOffer.forSelection([node(cloudLink)]) == nil)
        #expect(SaveAsPDFOffer.forSelection([node(localLink), node(cloudLink)]) == nil)
        #expect(SaveAsPDFOffer.forSelection([node(localLink)]) == .single(path: localLink))
    }

    // MARK: Markdown images

    /// **A note's image that is a link to a cloud-only picture is not fetched** for the preview.
    @Test func aMarkdownImageLinkedToACloudOnlyPictureIsRefused() throws {
        let picture = path("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: picture))
        _ = try link("photo-link.png", to: picture)
        #expect(MarkdownImageSource.resolve("photo-link.png", relativeTo: folder, isCloudOnly: Self.only(picture))
                == .refused("Not downloaded — the preview won’t fetch it."))
        #expect(MarkdownImageSource.resolve("photo-link.png", relativeTo: folder, isCloudOnly: { _ in false })
                != .refused("Not downloaded — the preview won’t fetch it."))
    }
}
