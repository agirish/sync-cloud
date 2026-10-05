import Testing
import Foundation
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport

/// TE56's file half, against a real folder: where a dropped or pasted image is written, what it is
/// called, and every refusal — each one asserted to leave the folder exactly as it was.
@Suite(.serialized) struct EditorImageImportTests {

    private let fm = FileManager.default

    /// A note in a fresh folder of its own.
    private func note(_ name: String = "Pasta.md") throws -> String {
        try TestTextFiles.write("# Pasta\n", named: name)
    }

    private func folder(of note: String) -> String { (note as NSString).deletingLastPathComponent }

    /// A real PNG, so the bytes are an image and not a placeholder string.
    private func png(_ side: Int = 2) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// An image file somewhere else on disk, as Finder would hand it over.
    private func imageElsewhere(_ name: String = "IMG_4120.png") throws -> String {
        let path = try TestTextFiles.write("", named: name)
        try png(3).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func listing(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    // MARK: - Where it goes, and what it is called

    @Test func aPasteMakesTheImagesFolderAndAPNGNamedForTheNote() throws {
        let note = try note()
        let report = EditorImageImport.importImages([.png(png())], forNote: note)
        let images = (folder(of: note) as NSString).appendingPathComponent("Images")
        #expect(report == .wrote(files: [images + "/Pasta-1.png"], madeFolder: images,
                                 linked: ["Images/Pasta-1.png"]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: images + "/Pasta-1.png")) == png())
    }

    @Test func theFolderIsReusedAndTheNumbersCountOn() throws {
        let note = try note()
        _ = EditorImageImport.importImages([.png(png())], forNote: note)
        let second = EditorImageImport.importImages([.png(png()), .png(png())], forNote: note)
        guard case .wrote(let files, let made, let links, _) = second else {
            Issue.record("refused: \(second)")
            return
        }
        #expect(made == nil, "the folder was made twice")
        #expect(links == ["Images/Pasta-2.png", "Images/Pasta-3.png"])
        #expect(files.map { ($0 as NSString).lastPathComponent } == ["Pasta-2.png", "Pasta-3.png"])
        #expect(listing(folder(of: note) + "/Images") == ["Pasta-1.png", "Pasta-2.png", "Pasta-3.png"])
    }

    /// **Never over an existing file — and never into a number a deleted image left**, because the
    /// note may still link that name and a new picture would appear in its place.
    @Test func anExistingNameIsNeverReused() throws {
        let note = try note()
        let images = folder(of: note) + "/Images"
        try fm.createDirectory(atPath: images, withIntermediateDirectories: false)
        let theirs = Data("not mine".utf8)
        try theirs.write(to: URL(fileURLWithPath: images + "/pasta-1.JPG"))
        try theirs.write(to: URL(fileURLWithPath: images + "/Pasta-7.gif"))
        let report = EditorImageImport.importImages([.png(png())], forNote: note)
        #expect(report == .wrote(files: [images + "/Pasta-8.png"], madeFolder: nil, linked: ["Images/Pasta-8.png"]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: images + "/pasta-1.JPG")) == theirs)
        #expect(try Data(contentsOf: URL(fileURLWithPath: images + "/Pasta-7.gif")) == theirs)
    }

    /// **The write itself refuses an existing file** — the guard against a file landing between the
    /// listing and the write, which no listing can see.
    @Test func theNewFileDoorNeverReplaces() throws {
        let note = try note()
        let target = folder(of: note) + "/taken.png"
        try Data("theirs".utf8).write(to: URL(fileURLWithPath: target))
        #expect(throws: EditorFileStore.AlreadyExists.self) { try EditorFileStore.createNew(png(), atPath: target) }
        #expect(throws: EditorFileStore.AlreadyExists.self) {
            try EditorFileStore.createNew(copying: try imageElsewhere(), toPath: target)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("theirs".utf8))
        // …and leaves no staged file behind.
        #expect(listing(folder(of: note)).filter { $0.hasPrefix(".tmp_") }.isEmpty)
    }

    /// **A failed write gives the reason, not the hidden staged file's name** — Foundation's own
    /// sentence names `.tmp_<UUID>`, which the reader never asked for and cannot find.
    @Test func aFailedWriteSaysWhyAndNotWhere() throws {
        let note = try note()
        let locked = folder(of: note) + "/Locked"
        try fm.createDirectory(atPath: locked, withIntermediateDirectories: false)
        chmod(locked, 0o555)
        defer { chmod(locked, 0o755) }
        do {
            try EditorFileStore.createNew(png(), atPath: locked + "/x.png")
            Issue.record("wrote into a folder that cannot be written to")
        } catch let failure as EditorFileStore.Failure {
            #expect(!failure.message.contains(".tmp_"), "\(failure.message)")
            #expect(failure.message == "Permission denied", "\(failure.message)")
        }
    }

    @Test func aDroppedFileIsCopiedNeverMoved() throws {
        let note = try note()
        let source = try imageElsewhere("IMG_4120.JPG")
        let report = EditorImageImport.importImages([.file(source)], forNote: note)
        #expect(report == .wrote(files: [folder(of: note) + "/Images/Pasta-1.JPG"], madeFolder: folder(of: note) + "/Images",
                                 linked: ["Images/Pasta-1.JPG"]))
        #expect(fm.fileExists(atPath: source), "the dropped file was moved")
        #expect(try Data(contentsOf: URL(fileURLWithPath: source))
                == Data(contentsOf: URL(fileURLWithPath: folder(of: note) + "/Images/Pasta-1.JPG")))
    }

    /// An image already in the folder is linked where it is, not copied in beside itself.
    @Test func anImageAlreadyThereIsLinkedNotCopied() throws {
        let note = try note()
        _ = EditorImageImport.importImages([.png(png())], forNote: note)
        let already = folder(of: note) + "/Images/Pasta-1.png"
        let report = EditorImageImport.importImages([.file(already)], forNote: note)
        #expect(report == .wrote(files: [], madeFolder: nil, linked: ["Images/Pasta-1.png"]))
        #expect(listing(folder(of: note) + "/Images") == ["Pasta-1.png"])
    }

    /// **A folder made as `images` is used, and linked by ITS name** — `Images/` would open it on
    /// this disk and not on a case-sensitive one, or on GitHub.
    @Test func aDifferentlyCasedFolderIsUsedByItsOwnName() throws {
        let note = try note()
        try fm.createDirectory(atPath: folder(of: note) + "/images", withIntermediateDirectories: false)
        let report = EditorImageImport.importImages([.png(png())], forNote: note)
        guard case .wrote(_, let made, let links, _) = report else {
            Issue.record("refused: \(report)")
            return
        }
        #expect(made == nil)
        #expect(links == ["images/Pasta-1.png"])
        #expect(listing(folder(of: note)).contains("images"))
    }

    @Test(arguments: [
        ("Weeknight Pasta.md", "Images/Weeknight%20Pasta-1.png"),
        ("Café (2).md", "Images/Caf%C3%A9%20%282%29-1.png"),
        ("100%.md", "Images/100%25-1.png"),
        (".hidden.md", "Images/hidden-1.png"),
    ])
    func aNameIsEncodedIntoOnePortableLink(_ noteName: String, _ link: String) throws {
        let note = try note(noteName)
        guard case .wrote(let files, _, let links, _) = EditorImageImport.importImages([.png(png())], forNote: note) else {
            Issue.record("refused")
            return
        }
        #expect(links == [link])
        // **The preview finds the file from the link Edit wrote** — through the image paragraph
        // and `MarkdownImageSource`, the two things that draw it.
        let blocks = MarkdownBlocks.blocks(from: "![](\(link))")
        guard case .image(let source, _)? = blocks.first?.kind else {
            Issue.record("\(link) is not an image paragraph")
            return
        }
        #expect(MarkdownImageSource.resolve(source, relativeTo: folder(of: note))
                == .local((folder(of: note) as NSString).appendingPathComponent(
                    "Images/" + (files[0] as NSString).lastPathComponent)))
    }

    /// **The name actually written** for the longest note name a disk allows — 240 bytes of "é" —
    /// fits the 255-byte limit, the stem shortened and the number and extension kept.
    @Test func aLongNoteNameStillFitsTheLimit() throws {
        let note = try note(String(repeating: "é", count: 120) + ".md")
        let source = try imageElsewhere("photo.jpeg")
        guard case .wrote(let files, _, let links, _) = EditorImageImport.importImages([.file(source)], forNote: note) else {
            Issue.record("refused")
            return
        }
        let name = try #require(files.first.map { ($0 as NSString).lastPathComponent })
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix("-1.jpeg"))
        #expect(fm.fileExists(atPath: files[0]))
        #expect(links.count == 1)
    }

    /// **A decomposed note name gives a composed image name and link** — git stores names composed,
    /// so a decomposed link would not find the file once the folder is pushed. A link the note
    /// already holds counts in either form.
    @Test func aDecomposedNameIsWrittenComposed() throws {
        let note = try note("Cafe\u{301}.md")
        guard case .wrote(_, _, let links, _) = EditorImageImport.importImages(
            [.png(png())], forNote: note, linkedIn: "![](Images/Cafe%CC%81-4.png)") else {
            Issue.record("refused")
            return
        }
        #expect(links == ["Images/Caf%C3%A9-5.png"])
    }

    /// An unreadable photo is refused as unreadable, before anything is written — not reported
    /// as one that "couldn't be saved".
    @Test func anUnreadableSourceIsRefusedAsUnreadable() throws {
        let note = try note()
        let source = try imageElsewhere()
        chmod(source, 0)
        defer { chmod(source, 0o644) }
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.file(source)], forNote: note),
                      in: folder(of: note), before: before, mentioning: "can't be read")
    }

    /// **An image Preview will not draw is said so at once**, not found out by looking.
    @Test func anImageTooLargeToDrawIsSaidSo() throws {
        let small = try imageElsewhere()
        #expect(EditorImageImport.drawWarning(for: [small]) == nil)
        let large = try TestTextFiles.write("", named: "Huge.png")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: large))
        try handle.truncate(atOffset: UInt64(MarkdownImageSource.maxBytes + 1))
        try handle.close()
        let warning = try #require(EditorImageImport.drawWarning(for: [small, large]))
        #expect(warning.contains("“Huge.png”"))
        #expect(warning.contains("too large to draw"))
        #expect(EditorImageImport.drawWarning(for: [large, large])?.contains("2 of the images") == true)
    }

    // MARK: - Refusals: nothing written, a reason given

    /// Every refusal below asserts this: the note's folder is exactly as it was.
    private func expectRefusal(_ report: EditorImageImport.Report, in folder: String, before: [String],
                               mentioning words: String) {
        guard case .refused(let reason) = report else {
            Issue.record("not refused: \(report)")
            return
        }
        #expect(reason.contains(words), "\(reason)")
        #expect(listing(folder) == before, "a refusal changed the folder")
    }

    @Test func aFileCalledImagesIsInTheWay() throws {
        let note = try note()
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder(of: note) + "/Images"))
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.png(png())], forNote: note),
                      in: folder(of: note), before: before, mentioning: "file called “Images”")
    }

    @Test func aFolderThatCannotBeWrittenIsRefused() throws {
        let note = try note()
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.png(png())], forNote: note, isWritable: { _ in false }),
                      in: folder(of: note), before: before, mentioning: "can't be written to")
        // And an Images folder that cannot be written, named as such.
        try fm.createDirectory(atPath: folder(of: note) + "/Images", withIntermediateDirectories: false)
        let after = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.png(png())], forNote: note,
                                                     isWritable: { !$0.hasSuffix("/Images") }),
                      in: folder(of: note), before: after, mentioning: "Images folder here can't be written")
    }

    /// **The real permission, not the injected one** — a read-only folder on disk.
    @Test func aReallyReadOnlyFolderIsRefused() throws {
        let note = try note()
        let folder = folder(of: note)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let before = listing(folder)
        expectRefusal(EditorImageImport.importImages([.png(png())], forNote: note),
                      in: folder, before: before, mentioning: "can't be written to")
    }

    /// **A cloud-only file is refused, not fetched** — copying it would download it on the main
    /// thread, for as long as the provider takes.
    @Test func aCloudOnlySourceIsRefused() throws {
        let note = try note()
        let source = try imageElsewhere()
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.file(source)], forNote: note, isCloudOnly: { $0.hasSuffix(".png") }),
                      in: folder(of: note), before: before, mentioning: "still in the cloud")
    }

    @Test func aCloudOnlyImagesFolderIsRefused() throws {
        let note = try note()
        try fm.createDirectory(atPath: folder(of: note) + "/Images", withIntermediateDirectories: false)
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.png(png())], forNote: note,
                                                     isCloudOnly: { $0.hasSuffix("/Images") }),
                      in: folder(of: note), before: before, mentioning: "Images folder here is still in the cloud")
    }

    @Test func aSourceThatIsGoneIsRefused() throws {
        let note = try note()
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.file("/nonexistent/IMG.png")], forNote: note),
                      in: folder(of: note), before: before, mentioning: "isn't there any more")
    }

    // MARK: - Found by the 2026-10-04 review

    /// **A Finder-locked, read-only image is copied as bytes alone** — the lock and the mode stay
    /// with the original, the new file is an ordinary writable one, and nothing hidden is left
    /// behind in the synced folder.
    @Test func aLockedReadOnlyImageCopiesCleanly() throws {
        let note = try note()
        let source = try imageElsewhere()
        try fm.setAttributes([.posixPermissions: 0o444, .immutable: true], ofItemAtPath: source)
        defer { try? fm.setAttributes([.immutable: false, .posixPermissions: 0o644], ofItemAtPath: source) }
        let report = EditorImageImport.importImages([.file(source)], forNote: note)
        let copy = folder(of: note) + "/Images/Pasta-1.png"
        #expect(report == .wrote(files: [copy], madeFolder: folder(of: note) + "/Images", linked: ["Images/Pasta-1.png"]))
        let attributes = try fm.attributesOfItem(atPath: copy)
        #expect((attributes[.immutable] as? Bool) != true, "the lock came with it")
        #expect(fm.isWritableFile(atPath: copy), "the copy is read-only")
        #expect(listing(folder(of: note) + "/Images") == ["Pasta-1.png"], "something hidden was left behind")
    }

    /// **An import that wrote nothing takes back the folder it made** — only an empty one — and is
    /// a refusal with the disk as it was.
    @Test func aFailureAfterTheFolderWasMadeLeavesNoFolder() throws {
        let note = try note()
        let source = try imageElsewhere()
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source) }
        let before = listing(folder(of: note))
        let report = EditorImageImport.importImages([.file(source)], forNote: note)
        guard case .refused(let reason) = report else {
            Issue.record("not refused: \(report)")
            return
        }
        #expect(reason.contains("IMG_4120.png"), "the refusal does not say which image: \(reason)")
        #expect(listing(folder(of: note)) == before, "the made folder was left behind")
    }

    /// **A number the note still links is never given out again**, even with its file gone.
    @Test func aNumberTheNoteLinksIsNotReused() throws {
        let note = try note("Weeknight Pasta.md")
        let text = "![](Images/Weeknight%20Pasta-5.png)\n\n![](<Images/Weeknight Pasta-7.png>)"
        let report = EditorImageImport.importImages([.png(png())], forNote: note, linkedIn: text)
        guard case .wrote(_, _, let links, _) = report else {
            Issue.record("refused: \(report)")
            return
        }
        #expect(links == ["Images/Weeknight%20Pasta-8.png"])
    }

    /// A note whose name is long enough to be shortened still counts on from its own images — 250
    /// characters, which no volume takes with `-1.png` after it unshortened.
    @Test func aLongNamesImagesStillCountOn() throws {
        let stem = String(repeating: "x", count: 250)
        let note = try note(stem + ".md")
        _ = EditorImageImport.importImages([.png(png())], forNote: note)
        let second = EditorImageImport.importImages([.png(png())], forNote: note)
        guard case .wrote(let files, _, _, _) = second else {
            Issue.record("refused: \(second)")
            return
        }
        #expect(files.first.map { ($0 as NSString).lastPathComponent.hasSuffix("-2.png") } == true,
                "\(files) did not count on")
    }

    /// Names that only look like a number — too long to be one, or signed — are not counted on from.
    @Test func onlyRealNumbersCount() {
        #expect(EditorImageImport.highestNumber(for: "Pasta", among: ["Pasta-99999999999999999999.png",
                                                                      "Pasta-+5.png", "Pasta-3.png"]) == 3)
    }

    /// **Through a symlinked Images folder, the folder it leads to is the one asked about.**
    @Test func aSymlinkedImagesFolderIsAskedAboutWhereItLeads() throws {
        let note = try note()
        let target = try TestTextFiles.write("", named: "x")
        let real = (target as NSString).deletingLastPathComponent + "/RealImages"
        try fm.createDirectory(atPath: real, withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: folder(of: note) + "/Images", withDestinationPath: real)
        let resolved = URL(fileURLWithPath: real).resolvingSymlinksInPath().path
        let before = listing(folder(of: note))
        expectRefusal(EditorImageImport.importImages([.png(png())], forNote: note,
                                                     isCloudOnly: { $0 == resolved }),
                      in: folder(of: note), before: before, mentioning: "still in the cloud")
    }

    /// A FOLDER named like an image is not an image drop: AppKit's drop goes ahead.
    @MainActor
    @Test func aFolderNamedLikeAnImageIsNotAnImage() throws {
        let note = try note()
        let trip = folder(of: note) + "/Trip.png"
        try fm.createDirectory(atPath: trip, withIntermediateDirectories: false)
        let board = NSPasteboard(name: NSPasteboard.Name("te56-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: trip) as NSURL])
        #expect(EditorTextView.imageFiles(on: board) == nil)
    }

    // MARK: - Which files count as images

    @Test(arguments: [("a.png", true), ("a.JPG", true), ("a.heic", true), ("a.gif", true), ("a.tiff", true),
                      ("a.pdf", false), ("a.md", false), ("a.txt", false), ("noext", false), ("a.zip", false)])
    func anImageIsDecidedByItsType(_ name: String, _ isImage: Bool) {
        #expect(EditorImageImport.isImageFile("/x/" + name) == isImage)
    }
}
