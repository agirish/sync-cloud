import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// **The PDF header's width, at every text size** — Phase 6a's rungs.
///
/// The name row is the name, then Find, Fill & Sign and Tools ▾, a divider, Expand and ×. The page
/// field, the zoom and the layout left it for the floating capsule, which is what gave the name its
/// room back: before 6a the narrowest rung left it 55pt in the column at the smallest window
/// (measured 2026-10-17), and the mockup gave it about 140.
///
/// The bound is the one decided 2026-10-17: **the document column at the smallest window**, the
/// actions shedding their words together as it narrows (``EditorPDFHeaderControls/Rung``) and the name
/// keeping what is pinned here.
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

    /// **What the name keeps at the narrowest rung, at every text size.**
    ///
    /// Measured 2026-10-18 on macOS 27, at the narrowest rung: the row's chrome is 204pt at 90% and
    /// 230pt at 135%, leaving the name 164pt down to **138pt at the largest size**. Pinned 4pt
    /// under that, as the 55pt it replaces was pinned; the failure message prints what the name is
    /// left.
    static let nameFloor: CGFloat = 134

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
            EditorPDFHeader(pdf: pdf, accent: .blue, onAccent: .white, onRevealInBrowse: { _ in },
                            rowActions: .inert, onClose: {}) {
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

    /// **At the smallest window, the narrowest rung leaves the name its floor, at every step of the
    /// Text size slider** — Find, Fill & Sign and Tools as bezelled glyphs, Expand and ×.
    @Test func theNarrowestRungLeavesTheNameRoomAtTheSmallestWindow() async throws {
        let pdf = try await open(pages: 64)
        let narrowest = try #require(EditorPDFHeaderControls.Rung.allCases.last)
        for percent in FontSize.selectablePercents {
            let chrome = chrome(pdf, narrowest, scale: FontSize(percent: percent).scale)
            let left = Self.column - chrome
            #expect(left >= Self.nameFloor, """
                    at \(percent)% the narrowest PDF header is \(chrome)pt and leaves \(left)pt of name \
                    in the \(Self.column)pt column — under the \(Self.nameFloor)pt floor
                    """)
        }
    }

    /// **All three shed their words together** (revised 2026-10-19): a header with Fill & Sign
    /// worded beside a bare magnifier and wrench read as two styles at once.
    @Test func theActionsShedTheirWordsTogether() throws {
        let rungs = EditorPDFHeaderControls.Rung.allCases
        #expect(rungs == [.worded, .glyphs])
        #expect(rungs.map(\.isWorded) == [true, false])
        let source = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(source.contains("EditorPDFFindButton(find: find, accent: accent, onAccent: onAccent, worded: rung.isWorded)"))
        #expect(source.contains("EditorPDFFillSignButton(fill: fill, tools: tools, accent: accent, onAccent: onAccent, worded: rung.isWorded)"))
        #expect(source.contains("EditorPDFToolsMenu(tools: tools, accent: accent, onAccent: onAccent, worded: rung.isWorded)"))
    }

    /// **The actions keep their width when the row is short of it** — the name gives way instead.
    /// Find and Fill & Sign used to shrink their bezels under words that cannot shrink, and each
    /// word overprinted its neighbour (seen at a 380pt column, 2026-10-19).
    @Test func theActionsAreNeverSqueezed() async throws {
        let pdf = try await open(pages: 4)
        for rung in EditorPDFHeaderControls.Rung.allCases {
            let controls = EditorPDFHeaderControls(find: pdf.find, fill: pdf.fill, tools: pdf.tools,
                                                   showsReaderActions: true, showsTools: true,
                                                   accent: .blue, onAccent: .white, rung: rung)
            let ideal = width(controls, scale: 1)
            let short = NSHostingController(rootView: controls)
                .sizeThatFits(in: CGSize(width: ideal - 40, height: 100)).width
            #expect(short == ideal, "at \(rung) the actions measure \(ideal)pt and squeeze to \(short)pt in \(ideal - 40)pt")
        }
    }

    /// **Each rung is narrower than the one before it**, at every text size — or `ViewThatFits`
    /// has nothing to choose between, and the floor above is measuring the only rung there is.
    @Test func eachRungShedsWidth() async throws {
        let pdf = try await open(pages: 64)
        for percent in FontSize.selectablePercents {
            let widths = EditorPDFHeaderControls.Rung.allCases.map { chrome(pdf, $0, scale: FontSize(percent: percent).scale) }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 > $1 + 10 },
                    "at \(percent)% the rungs measure \(widths) — not each narrower than the last")
        }
    }

    /// **The three file actions keep their bezel when they lose their words** — one style for all
    /// three (decided 2026-10-19), and Expand and × outside it.
    @Test func theFileActionsShareOneBezelledStyle() throws {
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let tools = try ChromeGlassWiringTests.source("EditorPDFToolViews.swift")
        #expect(ChromeGlassWiringTests.count(".modifier(EditorPDFActionStyle(accent: accent))", in: card) == 2,
                "Find and Fill & Sign do not both wear the file actions' style")
        #expect(tools.contains(".modifier(EditorPDFActionStyle(accent: accent))"), "Tools does not wear the file actions' style")
        #expect(tools.contains("symbol: \"wrench.and.screwdriver\""), "Tools lost the wrench it has always drawn")
        // The bezel is the style's, not the word's: nothing in it reads the rung.
        let style = try #require(card.range(of: "struct EditorPDFActionStyle: ViewModifier {"))
        // To the struct's own closing brace: a fixed-length window ran on into Find's button, which
        // does read it.
        let rest = card[style.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"))
        let styleBody = String(rest[..<end.lowerBound])
        #expect(styleBody.contains(".buttonStyle(.hoverAffordance(.segment"), "the style's body was not found — vacuous")
        #expect(!styleBody.contains("worded"), "the bezel depends on whether the word is drawn")
    }

    /// **The header chooses among all of them, widest first** — the name row's `ViewThatFits`.
    @Test func theHeaderChoosesAmongTheRungs() throws {
        let source = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(source.contains("ForEach(EditorPDFHeaderControls.Rung.allCases, id: \\.self) { rung in"))
        #expect(source.contains("accent: accent, onAccent: onAccent, rung: rung)"), "the actions are not drawn at the chosen rung")
    }

    /// **No "PDF" tag beside the name, and no page, zoom or layout control in the header** — the
    /// name ends in .pdf, and the capsule moves around the page now.
    @Test func theNameRowHoldsTheFileAndWhatActsOnIt() throws {
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let start = try #require(card.range(of: "func nameRow(_ rung: EditorPDFHeaderControls.Rung) -> some View {"))
        let end = try #require(card.range(of: "private var metaRow: some View {", range: start.upperBound..<card.endIndex))
        let row = String(card[start.upperBound..<end.lowerBound])
        for gone in ["EditorPDFZoom", "pageField", "EditorPDFLayoutMenu", "Text(\"PDF\")", "EditorPDFCapsule"] {
            #expect(!row.contains(gone), "the name row draws \(gone) again")
        }
    }
}
