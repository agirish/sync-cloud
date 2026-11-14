import Testing
import AppKit
import PDFKit
import Sync
import SwiftUI
@testable import FileExplorer
import FileExplorerTestSupport

extension PDFFixtures {
    /// Opens `file` in a reader model, the cloud check off for it and its tools, and waits a lane
    /// turn at a time, bounded, for the load to leave `.loading`; it must land `.open`.
    @MainActor
    static func opened(_ file: String, defaults: UserDefaults,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open, sourceLocation: sourceLocation)
        return pdf
    }

    /// Opens `file` in a reader model and waits, a lane turn and 5 ms at a time, bounded, for
    /// `onLoaded`; the first phase it reports must be `.open`.
    @MainActor
    static func openedWhenLoaded(_ file: String, defaults: UserDefaults,
                                 sourceLocation: SourceLocation = #_sourceLocation) async throws -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where phases.isEmpty {
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(phases.first == .open, sourceLocation: sourceLocation)
        return pdf
    }
}

/// Rigs the Editor suites share.
@MainActor
enum EditorTestRigs {

    /// A `ReaderPDFView` filling a titled window of `size`, at a fixed `scale` (no auto-scaling), laid
    /// out over `document` with `fill` attached (none when `nil`). `bury` orders the window in, key and
    /// under everything on screen, before the document goes in, for tests that need a first responder.
    static func readerWindow(_ document: PDFDocument?, fill: EditorPDFFillSign?, size: CGSize,
                             scale: CGFloat, bury: Bool = false) -> (window: NSWindow, reader: ReaderPDFView) {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: frame)
        window.contentView = reader
        if bury {
            window.isReleasedWhenClosed = false
            window.buryUnderEverything()
            window.makeKeyAndOrderFront(nil)
        }
        reader.autoScales = false
        reader.fit = nil
        reader.document = document
        reader.scaleFactor = scale
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = fill
        return (window, reader)
    }

    /// A text view in a 600×400 titled window, its scroll view marked the way
    /// `PlainTextEditor.makeNSView` marks its own. A window is required: a detached view has no
    /// first responder, and `performTextFinderAction` on one does nothing.
    static func markedTextView(text: String, scrollHeight: CGFloat = 400, usesFindBar: Bool = true,
                               allowsUndo: Bool = true) -> (scroll: NSScrollView, view: NSTextView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: scrollHeight)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        if usesFindBar {
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
        }
        if allowsUndo { view.allowsUndo = true }
        view.string = text
        return (scroll, view, window)
    }

    /// The first scroll view under `view`, depth first, carrying the editor's mark.
    static func markedScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.identifier == EditorDocumentSurface.identifier { return scroll }
        for sub in view.subviews { if let found = markedScroll(in: sub) { return found } }
        return nil
    }

    /// The editor's own text view in a resizable titled window, set up as `makeNSView` sets its
    /// own: the editor's font, no background, the base inset, `wraps` applied. `scroll` runs on the
    /// scroll view before it is framed; `bury` sinks the window before anything is put in it.
    static func editorTextView(width: CGFloat, height: CGFloat = 400, text: String, wraps: Bool = true,
                               bury: Bool = false, appearance: NSAppearance.Name? = nil,
                               scroll configure: (NSScrollView) -> Void = { _ in })
        -> (window: NSWindow, scroll: NSScrollView, view: EditorTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        if bury { window.buryUnderEverything() }
        let scroll = EditorTextView.scrollableTextView()
        configure(scroll)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        let view = scroll.documentView as! EditorTextView
        view.font = PlainTextEditor.font(scale: 1)
        view.drawsBackground = false
        view.textContainerInset = EditorReadableColumn.baseInset
        view.string = text
        PlainTextEditor.applyWrapping(wraps, to: view, in: scroll)
        return (window, scroll, view)
    }

    /// The real `PlainTextEditor` hosted `width` × 300 and laid out, with the document view
    /// `makeNSView` built inside its marked scroll view.
    static func mountedEditor(_ editor: PlainTextEditor, defaults: UserDefaults,
                              width: CGFloat) -> (host: NSHostingView<AnyView>, documentView: NSView?) {
        let host = NSHostingView(rootView: AnyView(editor.defaultAppStorage(defaults)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
        return (host, markedScroll(in: host)?.documentView)
    }

    /// A real PNG, `side` pixels square, so the bytes are an image and not a placeholder string.
    nonisolated static func png(side: Int = 2) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// An image file named `name` somewhere else on disk, as Finder would hand it over.
    nonisolated static func imageFile(named name: String, side: Int = 2) throws -> String {
        let path = try TestTextFiles.write("", named: name)
        try png(side: side).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The first text view under `view`, depth first.
    static func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }
}

/// Go to Line's popover rig, shared by the field's suite and the workspace's: a buried key window
/// (the popover presents only from a visible window, and no package run stands one on the user's
/// desktop), run-loop turns, and the popovers up.
@MainActor
protocol EditorPopoverRig {}

@MainActor
extension EditorPopoverRig {
    func spin(_ window: NSWindow, _ turns: Int = 15) {
        for _ in 0..<turns {
            _ = CFRunLoopRunInMode(.defaultMode, 0.03, true)
            window.layoutIfNeeded()
        }
    }

    /// Every popover up — each buried with the window it opened from, under everything on screen.
    func popovers(sourceLocation: SourceLocation = #_sourceLocation) -> [NSWindow] {
        let open = NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        for popover in open {
            #expect(BuriedWindow.isBuried(popover), "a popover opened above the buried window, at level \(popover.level.rawValue)",
                    sourceLocation: sourceLocation)
        }
        return open
    }

    /// `host` in a titled window at (200, 200), key, ordered in and buried, then spun.
    func window(for host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: host.frame.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.buryUnderEverything()
        window.makeKeyAndOrderFront(nil)
        #expect(BuriedWindow.isBuried(window), "the fixture window is above the desktop, at level \(window.level.rawValue)")
        spin(window)
        return window
    }
}
