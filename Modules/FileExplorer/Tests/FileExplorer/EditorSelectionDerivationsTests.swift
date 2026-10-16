import Testing
import SwiftUI
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport

/// **The selection's two answers, derived beside the workspace (TE60)** — the status line's counts
/// and the format bar's lit state, from the length a drag writes into ``EditorLiveSelection``.
/// Mounted with a live box and bindings, so what is tested is the view the workspace draws, fed
/// the way a drag feeds it; then the whole path in a mounted workspace, read off its status line.
///
/// **Waits await, never spin.** The answers come from main-actor tasks, and a synchronous run-loop
/// spin on the main actor starves them — they wake only after the test has returned, cancelled.
@MainActor
@Suite(.serialized) struct EditorSelectionDerivationsTests {

    final class Answers: ObservableObject {
        @Published var facts: EditorSelectionFacts?
        @Published var format: MarkupFormatState = .none
        /// The document's counts the workspace would hand over, and the version they were taken at.
        @Published var documentFacts: EditorDocumentFacts = .empty
        @Published var factsVersion: Int?
    }

    struct Harness: View {
        let document: EditorDocument
        let live: EditorLiveSelection
        let showsFormatBar: Bool
        @ObservedObject var answers: Answers
        var body: some View {
            EditorSelectionDerivations(document: document, live: live,
                                       version: document.textVersion, path: document.path,
                                       caretOffset: 0, facts: answers.documentFacts,
                                       factsVersion: answers.factsVersion,
                                       mode: .edit, showsFormatBar: showsFormatBar,
                                       selectionFacts: $answers.facts, formatState: $answers.format)
        }
    }

    private struct Rig {
        let window: NSWindow
        let live: EditorLiveSelection
        let answers: Answers
        let version: Int
    }

    /// `staleBy` sets the document's counts that many versions behind the text — as they are for
    /// their own debounce after every edit.
    private func mount(_ text: String, named name: String, showsFormatBar: Bool = false,
                       documentFacts: EditorDocumentFacts = .empty, staleBy: Int = 0) throws -> Rig {
        let document = try TestTextFiles.document(named: name, text: text)
        let live = EditorLiveSelection()
        let answers = Answers()
        answers.documentFacts = documentFacts
        answers.factsVersion = document.textVersion - staleBy
        let host = NSHostingView(rootView: Harness(document: document, live: live,
                                                   showsFormatBar: showsFormatBar, answers: answers))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        return Rig(window: window, live: live, answers: answers, version: document.textVersion)
    }

    /// **A drag counts once, where it rests, and a bare caret clears.** Each tick lays the view out
    /// before the next, as a drag's do; the count that lands is the last tick's, not one on the way.
    @Test func aDragIsCountedWhereItRests() async throws {
        let rig = try mount("one two three\nfour five\n", named: "drag.txt")
        defer { rig.window.orderOut(nil) }
        for length in [1, 3, 5, 7, 9, 13, 16] {
            rig.live.set(length: length)
            rig.window.layoutIfNeeded()
        }
        let counted = await LayoutPumpWait.pump(rig.window, upTo: 5) { rig.answers.facts != nil }
        // "one two three\nfo" — four words (the cut one counts), 16 characters, across two lines.
        #expect(rig.answers.facts == EditorSelectionFacts(words: 4, characters: 16, lines: 2),
                "the drag counted \(String(describing: rig.answers.facts)) after \(counted.pumps) passes")
        rig.live.set(length: 0)
        let cleared = await LayoutPumpWait.pump(rig.window, upTo: 5) { rig.answers.facts == nil }
        #expect(cleared.held, "a bare caret still shows \(String(describing: rig.answers.facts))")
    }

    /// **The format bar's lit state follows the selection while the bar is drawn**, and is nothing
    /// while it is not — nobody reads it then. The bar-off rig is waited out on the bar-on one's
    /// answer (the probe), so its silence is a verdict and not an impatient look.
    @Test func theBarsLitStateFollowsTheSelectionWhileTheBarIsDrawn() async throws {
        let text = "**bold** and plain\n"
        let shown = try mount(text, named: "lit.md", showsFormatBar: true)
        let hidden = try mount(text, named: "unlit.md", showsFormatBar: false)
        defer { shown.window.orderOut(nil); hidden.window.orderOut(nil) }
        shown.live.set(length: 8)
        hidden.live.set(length: 8)
        let lit = await LayoutPumpWait.pump(shown.window, upTo: 5) { shown.answers.format != .none }
        #expect(shown.answers.format.lit.contains(.bold),
                "selecting **bold** lit \(shown.answers.format.lit) after \(lit.pumps) passes")
        _ = await LayoutPumpWait.pump(hidden.window, upTo: 0) { false }
        #expect(hidden.answers.format == .none, "the bar is off and its state was derived anyway")
    }

    /// **A selection is not counted beside the document's counts of another text** (TE60 review) —
    /// just after an edit those are the last text's for their own debounce, and the pair read "13 of
    /// 12 words". It waits, and is counted the moment they catch up — reusing them for a select-all.
    ///
    /// The marker counts are deliberately wrong for the text, so a reuse shows as 900 words and a
    /// fresh count as 3. The current rig is the probe the stale one is waited out on.
    @Test func aSelectionWaitsForTheDocumentsCountsOfThisText() async throws {
        let text = "one two three"
        let marker = EditorDocumentFacts(words: 900, characters: 901, lines: 902, lineEnding: nil, encoding: nil)
        let current = try mount(text, named: "current.txt", documentFacts: marker)
        let stale = try mount(text, named: "stale.txt", documentFacts: marker, staleBy: 1)
        defer { current.window.orderOut(nil); stale.window.orderOut(nil) }
        let all = (text as NSString).length
        current.live.set(length: all)
        stale.live.set(length: all)
        let probe = await LayoutPumpWait.pump(current.window, upTo: 5) { current.answers.facts != nil }
        #expect(current.answers.facts == EditorSelectionFacts(words: 900, characters: 901, lines: 902),
                "a select-all beside this text's counts did not reuse them (\(probe.pumps) passes)")
        _ = await LayoutPumpWait.pump(stale.window, upTo: 0) { false }
        #expect(stale.answers.facts == nil,
                "counted beside the last text's counts: \(String(describing: stale.answers.facts))")

        // The document's counts catch up: the selection is counted, and the select-all reuses them.
        stale.answers.documentFacts = EditorDocumentFacts.of(text, encoding: nil)
        stale.answers.factsVersion = stale.version
        let caught = await LayoutPumpWait.pump(stale.window, upTo: 5) { stale.answers.facts != nil }
        #expect(stale.answers.facts == EditorSelectionFacts(words: 3, characters: 13, lines: 1),
                "after the counts caught up: \(String(describing: stale.answers.facts)) (\(caught.pumps) passes)")
    }

    // MARK: Several ranges

    /// **Several ranges keep the document's counts** — an ⌥-drag's column or a ⌘-drag. The line counts
    /// one selection, and the first range's count beside the others still lit would be a number
    /// about something else. The single-range rig is the probe the other is waited out on.
    @Test func severalRangesAreNotCounted() async throws {
        let text = "alpha beta gamma delta\n"
        let single = try mount(text, named: "single.txt")
        let several = try mount(text, named: "several.txt")
        defer { single.window.orderOut(nil); several.window.orderOut(nil) }
        single.live.set(length: 5)
        several.live.set(rangeCount: 2)
        several.live.set(length: 5)
        let probe = await LayoutPumpWait.pump(single.window, upTo: 5) { single.answers.facts != nil }
        #expect(single.answers.facts == EditorSelectionFacts(words: 1, characters: 5, lines: 1),
                "one range was not counted (\(probe.pumps) passes)")
        _ = await LayoutPumpWait.pump(several.window, upTo: 0) { false }
        #expect(several.answers.facts == nil, "two ranges counted as \(String(describing: several.answers.facts))")
        // Back to one range, the same length: counted.
        several.live.set(rangeCount: 1)
        let back = await LayoutPumpWait.pump(several.window, upTo: 5) { several.answers.facts != nil }
        #expect(back.held, "one range again, and still not counted")
    }

    final class Reports {
        var rangeCounts: [Int] = []
        var ranges: [NSRange] = []
    }

    /// **The text view says how many ranges are selected, with every change** — and still hands over
    /// the first range, as it always has.
    @Test func theTextViewReportsHowManyRangesAreSelected() throws {
        let reports = Reports()
        let source = EditorSourceStorage(text: "alpha beta gamma delta\n")
        let host = NSHostingView(rootView: PlainTextEditor(source: source, isEditable: true, fontScale: 1,
                                                           documentID: "/ranges.txt", undoManager: UndoManager(),
                                                           onSelectionChange: { reports.ranges.append($0) },
                                                           onSelectionRangeCount: { reports.rangeCounts.append($0) })
            .frame(width: 300, height: 100)
            .editorTestDefaults("EditorSelectionDerivationsTests.ranges"))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        let view = try #require(textView(in: host), "no text view mounted — this test sees nothing")
        reports.rangeCounts = []
        reports.ranges = []
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 5)),
                                NSValue(range: NSRange(location: 11, length: 5))],
                               affinity: .downstream, stillSelecting: false)
        #expect(reports.rangeCounts.last == 2, "two ranges reported as \(reports.rangeCounts)")
        #expect(reports.ranges.last == NSRange(location: 0, length: 5))
        view.setSelectedRange(NSRange(location: 6, length: 4))
        #expect(reports.rangeCounts.last == 1, "one range reported as \(reports.rangeCounts)")
    }

    // MARK: In the workspace

    private func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    /// The bottom of the workspace — the status line — as pixels.
    private func statusStrip(_ host: NSView) -> NSBitmapImageRep? {
        let strip = NSRect(x: 0, y: host.isFlipped ? host.bounds.height - 26 : 0, width: host.bounds.width, height: 26)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: strip) else { return nil }
        host.cacheDisplay(in: strip, to: rep)
        return rep
    }

    private func differingPixels(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        guard let a, let b else { return -1 }
        var count = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    /// **A selection made in a mounted workspace reaches its status line, and leaves it again** —
    /// the whole path: the text view's report, the box, the derivations, the line. Read as pixels of
    /// the line's strip against itself with nothing selected.
    @Test func aSelectionInAMountedWorkspaceReachesTheStatusLine() async throws {
        let document = try TestTextFiles.document(named: "mounted.txt", text: "one two three\nfour five\n")
        let host = NSHostingView(rootView: EditorWorkspaceView.fixture(document: document, mode: .edit)
            .environment(\.colorScheme, .light)
            .editorTestDefaults("EditorSelectionDerivationsTests.workspace"))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // Settled: the document's own counts land on their 150 ms debounce — a full floor of
        // passes, then the strip must hold still (the control: no selection, no change).
        _ = await LayoutPumpWait.pump(window, upTo: 1) { false }
        let bare = statusStrip(host)
        _ = await LayoutPumpWait.pump(window, upTo: 0) { false }
        try #require(differingPixels(bare, statusStrip(host)) == 0, "the strip moves with nothing selected")
        let editor = try #require(textView(in: host), "no text view mounted — this test sees nothing")

        editor.setSelectedRange(NSRange(location: 0, length: 7))
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { differingPixels(bare, statusStrip(host)) > 50 }
        #expect(shown.held, "selecting changed nothing in the status line after \(shown.pumps) passes")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let gone = await LayoutPumpWait.pump(window, upTo: 5) { differingPixels(bare, statusStrip(host)) == 0 }
        #expect(gone.held, "the count stayed after the selection went (\(gone.pumps) passes)")

        // Two ranges, the first as long as the one above: the line keeps the document's counts.
        editor.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 7)),
                                  NSValue(range: NSRange(location: 14, length: 4))],
                                 affinity: .downstream, stillSelecting: false)
        _ = await LayoutPumpWait.pump(window, upTo: 0) { false }
        #expect(differingPixels(bare, statusStrip(host)) == 0, "two ranges were counted on the status line")
    }
}
