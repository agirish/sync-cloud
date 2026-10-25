import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// **The disk banner floats over the text's foot** (TE210, his call CC, 2026-10-25): it was a row
/// above the text, so the format bar and every line jumped down when a change from elsewhere was
/// noticed. Now nothing under it moves, and the text view gains room to scroll its last lines clear
/// of it — in Source and in editable Preview, the two text views it can stand over.
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

    private func mount(_ file: URL, banner: EditorDiskBanner?, mode: EditorMode) -> NSWindow {
        let document = EditorDocument()
        _ = EditorFileStore.load(path: file.path, into: document)
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

    private func measure(_ file: URL, banner: EditorDiskBanner?, mode: EditorMode) async throws -> Measured {
        let window = mount(file, banner: banner, mode: mode)
        defer { window.close() }
        let host = try #require(window.contentView)
        // A banner's inset lands a pass after its height is measured.
        await LayoutPumpWait.pump(window, upTo: 10) {
            guard let scroll = textScroll(in: host) else { return false }
            return banner == nil || scroll.contentInsets.bottom > 0
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
