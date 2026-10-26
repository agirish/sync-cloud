import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// **The disk banner floats over the text's foot** (TE210, his call CC, 2026-10-25): it was a row
/// above the text, so the format bar and every line jumped down when a change from elsewhere was
/// noticed. Now nothing under it moves, and the text view gains room to scroll its last lines clear
/// of it — in Source and in editable Preview, the two text views it can stand over.
///
/// **The read-only note floats with it** (2026-10-26): a file that turned unreadable mid-session
/// put a row above the text and pushed everything down. It stands over the foot too, above the
/// banner when both are up.
@MainActor
@Suite(.serialized) struct EditorDiskBannerFloatsTests {

    private func scratchFile(_ name: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disk-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data((1...200).map { "Line \($0) of the note\n" }.joined().utf8).write(to: file)
        return file
    }

    private func mount(_ file: URL, banner: EditorDiskBanner?, mode: EditorMode, readOnly: Bool) -> NSWindow {
        let document = EditorDocument()
        _ = EditorFileStore.load(path: file.path, into: document)
        // The watch's own step when the file turns unreadable mid-session (`EditorDiskWatch`).
        if readOnly { document.reload(.readOnly(text: document.text, reason: Self.unreadable, stamp: nil)) }
        let workspace = EditorWorkspaceView(
            document: document, autosavePolicy: EditorAutosavePolicy(),
            folder: file.deletingLastPathComponent().path,
            entries: [], showsRail: false, railIsHidden: true,
            accent: .blue, accentFill: .blue, onAccent: .white,
            mode: .constant(mode), splitFraction: .constant(0.5), isNaming: .constant(false),
            typedName: .constant(""), railFilter: .constant(""), railFilterIsExpanded: .constant(false),
            railTab: .constant(.files), railOutlineAnchors: .constant([:]), undoManager: UndoManager(),
            diskBanner: banner,
            prefilledName: { "Untitled.md" }, refusal: { _ in nil },
            onOpen: { _ in }, onCreate: { _ in true }, onRevealInBrowse: { _ in }, location: nil,
            onLocationDoor: { _ in }, railRowActions: .inert, onToggleJustTheText: {}, onNewTextFile: nil,
            onCloseDocument: {}, folderTrail: nil, onGoToFolder: nil)
        let host = NSHostingView(rootView: AnyView(workspace.editorTestDefaults("EditorDiskBannerFloatsTests")))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    /// The document's text view's scroll view — Source's or editable Preview's, both of which are
    /// `EditorDocumentScrollView`s.
    private func textScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? EditorDocumentScrollView { return scroll }
        for sub in view.subviews { if let found = textScroll(in: sub) { return found } }
        return nil
    }

    private struct Measured {
        var frame: NSRect
        var bottomInset: CGFloat
        var topInset: CGFloat
    }

    private static let unreadable = EditorDiskWatch.unreadableReason("It isn’t text any more.")

    private func measure(_ file: URL, banner: EditorDiskBanner?, mode: EditorMode,
                         readOnly: Bool = false) async throws -> Measured {
        let window = mount(file, banner: banner, mode: mode, readOnly: readOnly)
        defer { window.close() }
        let host = try #require(window.contentView)
        // A banner's inset lands a pass after its height is measured.
        await LayoutPumpWait.pump(window, upTo: 10) {
            guard let scroll = textScroll(in: host) else { return false }
            return (banner == nil && !readOnly) || scroll.contentInsets.bottom > 0
        }
        let scroll = try #require(textScroll(in: host), "no text view mounted in \(mode)")
        return Measured(frame: scroll.convert(scroll.bounds, to: nil), bottomInset: scroll.contentInsets.bottom,
                        topInset: scroll.contentInsets.top)
    }

    @Test(arguments: [EditorMode.edit, .preview])
    func theBannerMovesNothingAndTheTextScrollsClearOfIt(mode: EditorMode) async throws {
        let file = try scratchFile("note.md")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let without = try await measure(file, banner: nil, mode: mode)
        for banner in [EditorDiskBanner.changed, .deleted] {
            let with = try await measure(file, banner: banner, mode: mode)
            #expect(with.frame == without.frame,
                    "\(mode), \(banner): the text view moved from \(without.frame) to \(with.frame)")
            #expect(with.bottomInset > 2 * EditorWorkspaceView.diskBannerMargin + 16,
                    "\(mode), \(banner): no room under the last line (\(with.bottomInset)pt)")
            #expect(with.topInset == without.topInset, "\(mode), \(banner): the top inset changed")
        }
        #expect(without.bottomInset == 0, "\(mode): room under the last line with no banner")
    }

    /// **The read-only note moves nothing either, and stacks with the banner**: the text view stays
    /// where it is with the note up, alone or above the banner, and the room under the last line
    /// grows by the note's height when both stand.
    ///
    /// Source and Split: a read-only Preview has no text view to keep still. The format bar over
    /// this Markdown note stays, greyed — it leaving moved the text up as the row once moved it down.
    @Test(arguments: [EditorMode.edit, .split])
    func theReadOnlyNoteFloatsAndStacksWithTheBanner(mode: EditorMode) async throws {
        let file = try scratchFile("note.md")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let without = try await measure(file, banner: nil, mode: mode)
        let note = try await measure(file, banner: nil, mode: mode, readOnly: true)
        let banner = try await measure(file, banner: .changed, mode: mode)
        let both = try await measure(file, banner: .changed, mode: mode, readOnly: true)
        for (name, with) in [("the note", note), ("note and banner", both)] {
            #expect(with.frame == without.frame, "\(mode), \(name): the text view moved from \(without.frame) to \(with.frame)")
            #expect(with.topInset == without.topInset, "\(mode), \(name): the top inset changed")
        }
        #expect(note.bottomInset > 2 * EditorWorkspaceView.diskBannerMargin + 16,
                "\(mode): no room under the last line for the note (\(note.bottomInset)pt)")
        #expect(both.bottomInset > banner.bottomInset + 16,
                "\(mode): the stack left no more room than the banner alone (\(both.bottomInset) vs \(banner.bottomInset))")
    }

    /// **Only a file that turned read-only under the document keeps its bar** — one opened read-only
    /// never had one — and becoming readable again, or another file, ends it.
    @Test func theDocumentSaysWhenItTurnedReadOnlyInPlace() throws {
        let file = try scratchFile("note.md")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let document = EditorDocument()
        _ = EditorFileStore.load(path: file.path, into: document)
        #expect(!document.becameReadOnlyInPlace)
        document.reload(.readOnly(text: document.text, reason: Self.unreadable, stamp: nil))
        #expect(document.becameReadOnlyInPlace, "a file turning unreadable under the document is not told apart")
        document.reload(.readOnly(text: document.text, reason: Self.unreadable, stamp: nil))
        #expect(document.becameReadOnlyInPlace, "a second reload, still unreadable, lost it")
        _ = EditorFileStore.load(path: file.path, into: document)
        #expect(!document.becameReadOnlyInPlace, "opening the file again kept it")
        document.open(.readOnly(text: "caf\u{FFFD}\n", reason: EditorFileStore.lossyReason), at: file.path)
        document.reload(.readOnly(text: "caf\u{FFFD}\n", reason: EditorFileStore.lossyReason, stamp: nil))
        #expect(!document.becameReadOnlyInPlace, "a file opened read-only reads as having turned read-only")
    }

    /// The room is the banner and its two margins, and none without one.
    @Test func theInsetIsTheBannerAndItsMargins() {
        let margin = EditorWorkspaceView.diskBannerMargin
        #expect(EditorWorkspaceView.diskBannerInset(bannerHeight: 40, isShown: true) == 40 + 2 * margin)
        #expect(EditorWorkspaceView.diskBannerInset(bannerHeight: 40, isShown: false) == 0)
    }

    /// **Set only when it changes, and only the bottom** — the top is whatever the scroll view had.
    @Test func applyingTheInsetLeavesTheTopAlone() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        PlainTextEditor.applyBottomInset(0, to: scroll)
        #expect(scroll.automaticallyAdjustsContentInsets, "a zero inset turned the automatic insets off")
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 7, left: 0, bottom: 0, right: 0)
        PlainTextEditor.applyBottomInset(52, to: scroll)
        #expect(scroll.contentInsets.bottom == 52)
        #expect(scroll.contentInsets.top == 7)
        PlainTextEditor.applyBottomInset(0, to: scroll)
        #expect(scroll.contentInsets.bottom == 0)
    }
}
