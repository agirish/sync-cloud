import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// **The PDF header's width, at every text size** — the first test the PDF header has had.
///
/// The header is the name, then Find, the page field, the zoom, the layout, Fill & Sign, Tools,
/// Expand and ×. **It does not fit the split's 260pt floor and never did**:
/// measured 2026-10-17, everything but the name took ~446pt at 100% before the Page / Width /
/// Actual capsule folded into the zoom menu, and 378pt after. So the bound is the one decided that
/// day: **the document column at the smallest window**, with the controls shedding words as it
/// narrows (``EditorPDFHeaderControls/Rung``) and the name keeping what is pinned here.
@MainActor
@Suite(.serialized) final class EditorPDFHeaderWidthTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-header-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFHeaderWidthTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    /// The document column at the app's 760pt window floor, with the folder sidebar at its own
    /// 150pt minimum and the rail open — `EditorLayoutTests`' conservative reading, ~368pt.
    static var column: CGFloat { 760 - 150 - EditorLayoutMetrics.railWidth - 2 * LiquidGlass.cardGutter }

    /// **Fill & Sign's room, held for it before Phase 5b built it**: its glyph form — the same 18pt
    /// glyph and 6pt gap as Tools beside it — which is what it sheds to at the narrowest rung. Its
    /// worded form is drawn only on the wider rungs, where the name has already had what it needs.
    /// Now that the button is in the row, the row's own width counts it, and this is the most its
    /// glyph form may take (`fillAndSignTakesNoMoreThanTheRoomHeldForIt`).
    static let fillAndSignGlyph: CGFloat = 18 + 6

    /// **What the name keeps at the narrowest rung, at every text size.** Measured 2026-10-17 on a
    /// 64-page PDF in Two Pages: 65pt at 100%, 57pt at 135%. Pinned below the smallest, so a control
    /// that grows by a few points fails here, naming the text size, rather than eating the name.
    static let nameFloor: CGFloat = 55

    private func open(pages: Int) async throws -> EditorPDFDocument {
        let file = (folder as NSString).appendingPathComponent("r.pdf")
        PDFFixtures.write(file, pages: pages)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where phases.isEmpty {
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(phases.first == .open)
        return pdf
    }

    private func width<V: View>(_ view: V, scale: CGFloat) -> CGFloat {
        NSHostingView(rootView: view.environment(\.appFontScale, scale)).fittingSize.width
    }

    /// The name row at `rung`, inside the document header's own padding, with the workspace's own
    /// Expand button — measured as a column holds it.
    private func row(_ pdf: EditorPDFDocument, _ rung: EditorPDFHeaderControls.Rung) -> some View {
        let workspace = EditorWorkspaceView.fixture(pdf: pdf).readingSettings(from: defaults)
        return EditorDocumentHeader {
            EditorPDFHeader(pdf: pdf, accent: .blue, onAccent: .white, onRevealInBrowse: { _ in }, onClose: {}) {
                workspace.expandButton(worded: false)
            }
            .nameRow(rung)
        }
    }

    /// Everything in the row but the name, at `rung` — the row's width less the name's own.
    private func chrome(_ pdf: EditorPDFDocument, _ rung: EditorPDFHeaderControls.Rung, scale: CGFloat) -> CGFloat {
        width(row(pdf, rung), scale: scale)
            - width(Text(pdf.name).scaledFont(.system(size: 13, weight: .semibold)), scale: scale)
    }

    /// The widest the controls get: two pages, so the field holds "63–64", and Fit Width, the
    /// longest zoom label.
    private func widest() async throws -> EditorPDFDocument {
        let pdf = try await open(pages: 64)
        pdf.view.layout = .twoPages
        pdf.view.fit = .width
        return pdf
    }

    /// **At the smallest window, the narrowest rung — Fill & Sign's glyph in it — leaves the name
    /// its floor, at every step of the Text size slider.**
    @Test func theNarrowestRungLeavesTheNameRoomAtTheSmallestWindow() async throws {
        let pdf = try await widest()
        let narrowest = try #require(EditorPDFHeaderControls.Rung.allCases.last)
        for percent in FontSize.selectablePercents {
            let chrome = chrome(pdf, narrowest, scale: FontSize(percent: percent).scale)
            let left = Self.column - chrome
            #expect(left >= Self.nameFloor, """
                    at \(percent)% the narrowest PDF header, Fill & Sign's glyph included, is \(chrome)pt \
                    and leaves \(left)pt of name in the \(Self.column)pt column — under the \(Self.nameFloor)pt floor
                    """)
        }
    }

    /// **Fill & Sign's glyph takes no more than the room held for it**, at every text size — and
    /// it IS in the narrowest row, unworded: the row with it less the row without it, gap and all.
    @Test func fillAndSignTakesNoMoreThanTheRoomHeldForIt() async throws {
        let pdf = try await widest()
        let narrowest = try #require(EditorPDFHeaderControls.Rung.allCases.last)
        #expect(!narrowest.wordsFillAndSign, "the narrowest rung words Fill & Sign")
        #expect(EditorPDFHeaderControls.Rung.worded.wordsFillAndSign, "the widest rung does not word Fill & Sign")
        for percent in FontSize.selectablePercents {
            let scale = FontSize(percent: percent).scale
            let with = width(EditorPDFHeaderControls(state: pdf.view, find: pdf.find, pageCount: 64, fill: pdf.fill,
                                                     accent: .blue, rung: narrowest), scale: scale)
            let without = width(EditorPDFHeaderControls(state: pdf.view, find: pdf.find, pageCount: 64, fill: pdf.fill,
                                                        accent: .blue, rung: narrowest, showsFillAndSign: false), scale: scale)
            #expect(with - without > 10, "at \(percent)% Fill & Sign takes \(with - without)pt — is it in the row?")
            #expect(with - without <= Self.fillAndSignGlyph,
                    "at \(percent)% Fill & Sign's glyph takes \(with - without)pt, over the \(Self.fillAndSignGlyph)pt held for it")
        }
    }

    /// **Each rung is narrower than the one before it**, at every text size — or `ViewThatFits`
    /// has nothing to choose between, and the floor above is measuring the only rung there is.
    @Test func eachRungShedsWidth() async throws {
        let pdf = try await widest()
        for percent in FontSize.selectablePercents {
            let widths = EditorPDFHeaderControls.Rung.allCases.map { chrome(pdf, $0, scale: FontSize(percent: percent).scale) }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 > $1 + 10 },
                    "at \(percent)% the rungs measure \(widths) — not each narrower than the last")
        }
    }

    /// **The header chooses among all of them, widest first** — the name row's `ViewThatFits`.
    @Test func theHeaderChoosesAmongTheRungs() throws {
        let source = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(source.contains("ForEach(EditorPDFHeaderControls.Rung.allCases, id: \\.self) { rung in"))
        #expect(source.contains("fill: pdf.fill, accent: accent, rung: rung)"), "the controls are not drawn at the chosen rung")
        #expect(source.contains("EditorPDFFillSignButton(fill: fill, accent: accent, worded: rung.wordsFillAndSign)"),
                "Fill & Sign does not shed its word with the rung")
    }
}
