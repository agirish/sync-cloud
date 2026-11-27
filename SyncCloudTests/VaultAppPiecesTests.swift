import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import Sync
import Testing
@testable import SyncCloud

/// The Vault's app-side pieces no other suite reaches (VT27): copying a number, the card's size,
/// which window's use counts, and what Read Documents leaves unread. Every number is made up; the
/// clipboard tests use a pasteboard of their own, never the user's. Serialized: there is one copy
/// waiting to be cleared at a time on each pasteboard, and a later copy takes the place of an
/// earlier one.
@MainActor
@Suite(.serialized) struct VaultAppPiecesTests {
    // MARK: Copying a number

    static func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("vault-tests-\(UUID().uuidString)")) }

    @Test func aCopyIsMarkedConcealedAndClearedOnceItsTimeIsUp() async throws {
        let board = Self.pasteboard()
        defer { board.releaseGlobally() }
        VaultPasteboard.copyConcealed("Z0000009", on: board, after: .milliseconds(100))
        let types = board.types ?? []
        #expect(types.contains(.init("org.nspasteboard.ConcealedType")) && types.contains(.init("org.nspasteboard.TransientType")),
                "clipboard-history apps skip it only when it is marked")
        #expect(board.string(forType: .string) == "Z0000009")
        await waitUntil("the copy was cleared") { board.string(forType: .string) == nil }
    }

    /// A copy on another pasteboard keeps its own clear: the second review's Cut test and this
    /// suite took the one pending clear from each other (the third review).
    @Test func aCopyOnAnotherPasteboardLeavesThisOnesClear() async throws {
        let board = Self.pasteboard(), other = Self.pasteboard()
        defer { board.releaseGlobally(); other.releaseGlobally() }
        VaultPasteboard.copyConcealed("Z0000009", on: board, after: .milliseconds(100))
        VaultPasteboard.copyConcealed("Y0000008", on: other, after: .seconds(3600))
        await waitUntil("the first copy was cleared") { board.string(forType: .string) == nil }
        #expect(other.string(forType: .string) == "Y0000008")
        VaultPasteboard.clearPending()
        #expect(other.string(forType: .string) == nil, "the other copy outlived a lock")
    }

    @Test func somethingCopiedSinceIsNeverCleared() async throws {
        let board = Self.pasteboard()
        defer { board.releaseGlobally() }
        VaultPasteboard.copyConcealed("Z0000009", on: board, after: .milliseconds(100))
        board.clearContents()
        board.setString("the user's own text", forType: .string)
        try await Task.sleep(for: .milliseconds(400))
        #expect(board.string(forType: .string) == "the user's own text")
        // Nor by quitting while the copy still waits.
        VaultPasteboard.copyConcealed("Z0000009", on: board, after: .seconds(3600))
        board.clearContents()
        board.setString("more of the user's own text", forType: .string)
        VaultPasteboard.clearPending()
        #expect(board.string(forType: .string) == "more of the user's own text")
    }

    @Test func quittingClearsACopyStillWaiting() throws {
        let board = Self.pasteboard()
        defer { board.releaseGlobally() }
        VaultPasteboard.copyConcealed("Z0000009", on: board, after: .seconds(3600))
        #expect(board.string(forType: .string) == "Z0000009")
        VaultPasteboard.clearPending()   // what the app's quit does
        #expect(board.string(forType: .string) == nil)
    }

    @Test func aPlainCopyIsUnmarkedAndOutlivesAConcealedOneWaiting() async throws {
        let board = Self.pasteboard()
        defer { board.releaseGlobally() }
        VaultPasteboard.copyConcealed("Z0000009", on: board, after: .seconds(3600))
        VaultPasteboard.copyPlain("Anna Eriksson", on: board)
        let types = board.types ?? []
        #expect(types.contains(.string) && !types.contains(.init("org.nspasteboard.ConcealedType"))
                && !types.contains(.init("org.nspasteboard.TransientType")), "a name or a date is copied as any app copies it")
        VaultPasteboard.clearPending()   // a lock, or quitting, with the number's clear still waiting
        #expect(board.string(forType: .string) == "Anna Eriksson", "the number's clear never takes what came after it")
    }

    /// Every clipboard write in the Vault's views goes through ``VaultPasteboard``, so how each
    /// kind of copy is marked and cleared is decided in one place (VT35).
    @Test func theVaultWritesTheClipboardOnlyThroughVaultPasteboard() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/Vault")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "VaultHost.swift" }
        #expect(files.count >= 8, "found only \(files.count) files: not the Vault's folder")
        var copies = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            copies += code.filter { $0.contains("VaultPasteboard.copyPlain(") }.count
            // A type named in a signature (the number field's Services override) writes nothing.
            #expect(!code.contains { $0.replacingOccurrences(of: "NSPasteboard.PasteboardType", with: "").contains("NSPasteboard") },
                    "\(file.lastPathComponent) writes the clipboard itself")
        }
        #expect(copies >= 2, "the scan reads the panel's copies")
    }

    // MARK: The card's size

    @Test func theCardIsTheRememberedSizeHeldToTheFloorAndTheWindow() {
        let big = CGSize(width: 2000, height: 1400)
        #expect(VaultCardSize.fitted(within: big) == VaultCardSize.preferred, "never resized: the preferred size")
        #expect(VaultCardSize.fitted(within: big, stored: CGSize(width: 0, height: 0)) == VaultCardSize.preferred, "0 is never resized")
        #expect(VaultCardSize.fitted(within: big, stored: CGSize(width: 1200, height: 800)) == CGSize(width: 1200, height: 800))
        #expect(VaultCardSize.fitted(within: big, stored: CGSize(width: 300, height: 200)) == VaultCardSize.minimum, "held to the floor")
        // A window that shrank since: what it can show, less the margin, but never under the floor.
        #expect(VaultCardSize.fitted(within: CGSize(width: 900, height: 600), stored: CGSize(width: 1200, height: 800))
                == CGSize(width: 900 - VaultCardSize.margin, height: 600 - VaultCardSize.margin))
        #expect(VaultCardSize.fitted(within: CGSize(width: 500, height: 300)) == VaultCardSize.minimum,
                "legible beats collapsed: it overflows a window smaller than the floor")
    }

    // MARK: Which window's use counts

    @Test func onlyUseInTheVaultsWindowOrOneOfItsOwnCounts() {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let vault = window(), child = window(), other = window()
        vault.addChildWindow(child, ordered: .above)
        defer { vault.removeChildWindow(child); for w in [vault, child, other] { w.close() } }
        #expect(VaultActivityWatch.belongs(vault, to: vault))
        #expect(VaultActivityWatch.belongs(child, to: vault), "a child window of it")
        #expect(!VaultActivityWatch.belongs(other, to: vault), "work in another window leaves the Vault idle")
        #expect(!VaultActivityWatch.belongs(nil, to: vault) && !VaultActivityWatch.belongs(vault, to: nil))
    }

    // MARK: What Read Documents leaves unread

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-pieces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A PDF of `pages` pages, each with one short typed line saying which it is (too few letters
    /// for a typed page, so each is read from its picture); locked with `password` when given.
    static func writePDF(pages: Int, to url: URL, password: String? = nil) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [:]
        if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password }
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        for page in 1...pages {
            context.beginPDFPage(nil)
            let line = NSAttributedString(string: "Page \(page) of a long letter, nothing to read here",
                                          attributes: [.font: NSFont.systemFont(ofSize: 12)])
            context.textPosition = CGPoint(x: 36, y: 740)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPDFPage()
        }
        context.closePDF()
        try data.write(to: url, options: .atomic)
    }

    @Test func aFileOverTheLimitIsPassedOverAndAnyOtherFound() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("letter.pdf"), big = folder.appendingPathComponent("book.pdf")
        try Self.writePDF(pages: 1, to: small)
        // Sparse: the size the walk reads, without the disk.
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(VaultFolderReader.largestFile + 1))
        try handle.close()
        let walked = await VaultFolderReader(folders: [folder.path]).files()
        #expect(walked.map(\.lastPathComponent) == ["letter.pdf"])
        // At the limit itself, found.
        try FileHandle(forWritingTo: big).truncate(atOffset: UInt64(VaultFolderReader.largestFile))
        #expect(await VaultFolderReader(folders: [folder.path]).files().count == 2)
    }

    @Test func onlyALongDocumentsFirstPagesAreRead() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("letter.pdf")
        try Self.writePDF(pages: 5, to: url)
        final class Count: @unchecked Sendable { var asked = 0 }
        let count = Count()
        var reader = VaultFolderReader(folders: [folder.path])
        reader.vision = { _, _ in count.asked += 1; return ["A page"] }
        let pages = await reader.pages(in: url)
        #expect(pages.count == VaultFolderReader.pagesPerDocument && VaultFolderReader.pagesPerDocument == 3)
        #expect(count.asked > 0, "the pages were read")
    }

    @Test func aLockedPDFIsPassedOverAndMarkedRead() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("statement.pdf")
        try Self.writePDF(pages: 1, to: url, password: "made-up")
        #expect(PDFDocument(url: url)?.isLocked == true, "the fixture is locked")
        var reader = VaultFolderReader(folders: [folder.path])
        final class Asked: @unchecked Sendable { var any = false }
        let asked = Asked()
        reader.vision = { _, _ in asked.any = true; return [] }
        let reading = await reader.reading(url)
        #expect(reading.pages.isEmpty && reading.complete, "its password is not the Vault's to ask for: read, nothing given")
        #expect(!asked.any)
        #expect(await reader.noted(url).notes.locked == 1, "counted for the read's summary (VT25)")
    }

    /// Why a file gave nothing is counted for the read's summary (VT25): one that is not a PDF at
    /// all, and a page Vision refused on both processors.
    @Test func whatCouldNotBeReadIsCountedByCause() async throws {
        struct Refused: Error {}
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: broken)
        var reader = VaultFolderReader(folders: [folder.path])
        reader.vision = { _, _ in throw Refused() }
        var notes = await reader.noted(broken).notes
        #expect(notes.unopenable == 1 && notes.locked == 0)
        // A scan with no text layer whose picture Vision refuses: one page not recognised.
        let scan = folder.appendingPathComponent("scan.pdf")
        try VaultFolderReaderTests.writePDF(picture: VaultFolderReaderTests.scan(of: VaultFolderReaderTests.passport), text: [], to: scan.path)
        notes = await reader.noted(scan).notes
        #expect(notes.unrecognised == 1 && notes.fromPicture == 0)
        // Read: from its picture.
        reader.vision = { _, _ in VaultFolderReaderTests.passport }
        notes = await reader.noted(scan).notes
        #expect(notes.fromPicture == 1 && notes.unrecognised == 0)
        // A picture saved as an image: one that is not an image, one Vision refuses, one read.
        let junk = folder.appendingPathComponent("photo.png")
        try Data("not an image".utf8).write(to: junk)
        #expect(await reader.noted(junk).notes.unopenable == 1)
        let image = folder.appendingPathComponent("scan.png")
        let destination = try #require(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try VaultFolderReaderTests.scan(of: VaultFolderReaderTests.passport, width: 400, height: 260), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(await reader.noted(image).notes.fromPicture == 1)
        reader.vision = { _, _ in throw Refused() }
        #expect(await reader.noted(image).notes.unrecognised == 1)
    }
}
