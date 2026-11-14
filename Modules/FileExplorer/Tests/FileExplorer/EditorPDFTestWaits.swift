import Testing
import AppKit
import PDFKit
import SwiftUI
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

extension PDFFixtures {
    /// Waits until `done` holds, a lane turn and 5 ms at a time. Bounded in turns, not seconds
    /// (`docs/flaky-tests.md`, "The wait that hangs instead of failing"), so a load that never comes
    /// records `label` and returns false instead of hanging.
    @MainActor
    @discardableResult
    static func waitInLane(_ label: String, turns: Int = 1000, until done: () -> Bool) async -> Bool {
        for _ in 0..<turns {
            if done() { return true }
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never happened in \(turns) lane turns: \(label)")
        return false
    }

    /// Opens `file` in a reader model reading `defaults`, its cloud check off, and waits for the load
    /// to land in any phase: a locked or unreadable file too, which ``opened(_:defaults:sourceLocation:)``
    /// would fail.
    @MainActor
    static func openedAnyPhase(_ file: String, defaults: UserDefaults, turns: Int = 1000) async -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.open(path: file, log: { _ in })
        await waitInLane("\((file as NSString).lastPathComponent) to open", turns: turns) { pdf.phase != .loading }
        return pdf
    }
}

extension PDFFixtures {
    /// Mounts `pdf` in the whole workspace, runs `action`, lets `settle` wait for its effect, and
    /// checks the page view was kept and neither its frame nor page 1's place in the window moved.
    /// `what` names the action in each failure.
    @MainActor
    static func expectPageStaysPut(_ pdf: EditorPDFDocument, defaults: UserDefaults, when what: String,
                                   after action: () -> Void,
                                   settle: (NSWindow, NSView) async throws -> Void) async throws {
        let host = NSHostingView(rootView: EditorWorkspaceView.fixture(pdf: pdf).readingSettings(from: defaults)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        defer { window.contentView = nil }
        func reader(in view: NSView) -> ReaderPDFView? {
            if let found = view as? ReaderPDFView { return found }
            for sub in view.subviews { if let found = reader(in: sub) { return found } }
            return nil
        }
        let settled = await LayoutPumpWait.pump(window, upTo: 10) { (reader(in: host)?.bounds.width ?? 0) > 0 }
        try #require(settled.held, "no page view in the document card")
        _ = await LayoutPumpWait.pump(window, upTo: 1) { false }
        let view = try #require(reader(in: host))
        let page = try #require(pdf.document?.page(at: 0))
        func pageInWindow() -> CGRect { view.convert(view.convert(page.bounds(for: view.displayBox), from: page), to: nil) }
        let frameBefore = view.convert(view.bounds, to: nil), pageBefore = pageInWindow()
        action()
        try await settle(window, host)
        #expect(reader(in: host) === view, "\(what) rebuilt the page view")
        let frameAfter = view.convert(view.bounds, to: nil), pageAfter = pageInWindow()
        #expect(frameAfter == frameBefore, "\(what) moved the pages: \(frameBefore) → \(frameAfter)")
        #expect(abs(pageAfter.minY - pageBefore.minY) < 0.5 && abs(pageAfter.minX - pageBefore.minX) < 0.5,
                "\(what) moved the page: \(pageBefore) → \(pageAfter)")
    }
}
