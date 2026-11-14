import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// The PDF header's width at every text size, and its rungs.
///
/// The name row is the name, then Find, Fill & Sign and Tools ▾, a divider, Expand and ×; the page
/// field, zoom and layout live in the floating capsule, which leaves the name its room. The bound
/// is the document column at the smallest window: the actions shed their words together as it
/// narrows (``EditorPDFHeaderControls/Rung``), and the name keeps what is pinned here.
@MainActor
@Suite(.serialized) final class EditorPDFHeaderWidthTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-header-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFHeaderWidthTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    /// The document column at the app's 760pt window floor, with the folder sidebar at its own
    /// 150pt minimum and the rail open: `EditorLayoutTests`' conservative reading, ~368pt.
    static var column: CGFloat { 760 - 150 - EditorLayoutMetrics.railWidth - 2 * LiquidGlass.cardGutter }

    /// What the name keeps at the narrowest rung, at every text size. Measured on macOS 27, the
    /// row's chrome is 204pt at 90% and 230pt at 135%, leaving the name 164pt down to 138pt at the
    /// largest size; pinned 4pt under that. The failure message prints what the name is left.
    static let nameFloor: CGFloat = 134

    private func open(pages: Int) async throws -> EditorPDFDocument {
        let file = (folder as NSString).appendingPathComponent("r.pdf")
        PDFFixtures.write(file, pages: pages)
        return try await PDFFixtures.openedWhenLoaded(file, defaults: defaults)
    }

    private func width<V: View>(_ view: V, scale: CGFloat) -> CGFloat {
        NSHostingView(rootView: view.environment(\.appFontScale, scale)).fittingSize.width
    }

    /// The name row at `rung`, inside the document header's own padding, with the workspace's own
    /// Expand button, measured as a column holds it.
    private func row(_ pdf: EditorPDFDocument, _ rung: EditorPDFHeaderControls.Rung) -> some View {
        let workspace = EditorWorkspaceView.fixture(pdf: pdf).readingSettings(from: defaults)
        return EditorDocumentHeader {
            EditorPDFHeader(pdf: pdf, accent: .blue, accentFill: .blue, onAccent: .white, onRevealInBrowse: { _ in },
                            rowActions: .inert, onClose: {}) { rung in
                workspace.expandButton(worded: rung.isWorded)
            }
            .nameRow(rung)
        }
    }

    /// Everything in the row but the name, at `rung`: the row's width less the name's own.
    private func chrome(_ pdf: EditorPDFDocument, _ rung: EditorPDFHeaderControls.Rung, scale: CGFloat) -> CGFloat {
        width(row(pdf, rung), scale: scale)
            - width(Text(pdf.name).scaledFont(.system(size: 13, weight: .semibold)), scale: scale)
    }

    /// At the smallest window, the narrowest rung (Find, Fill & Sign and Tools as bezelled glyphs,
    /// Expand and ×) leaves the name its floor at every step of the Text size slider.
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

    /// All three shed their words together: Fill & Sign worded beside a bare magnifier and wrench
    /// would read as two styles at once.
    @Test func theActionsShedTheirWordsTogether() throws {
        let rungs = EditorPDFHeaderControls.Rung.allCases
        #expect(rungs == [.worded, .glyphs])
        #expect(rungs.map(\.isWorded) == [true, false])
        let source = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(source.contains("EditorPDFFindButton(find: find, accent: accent, accentFill: accentFill, onAccent: onAccent, worded: rung.isWorded)"))
        #expect(source.contains("EditorPDFFillSignButton(fill: fill, tools: tools, accent: accent, accentFill: accentFill, onAccent: onAccent, worded: rung.isWorded)"))
        #expect(source.contains("EditorPDFToolsMenu(tools: tools, accent: accent, accentFill: accentFill, onAccent: onAccent, worded: rung.isWorded)"))
    }

    /// The actions keep their width when the row is short of it, and the name gives way instead.
    /// A bezel squeezed under words that can't shrink would overprint its neighbour.
    @Test func theActionsAreNeverSqueezed() async throws {
        let pdf = try await open(pages: 4)
        for rung in EditorPDFHeaderControls.Rung.allCases {
            let controls = EditorPDFHeaderControls(find: pdf.find, fill: pdf.fill, tools: pdf.tools,
                                                   showsReaderActions: true, showsTools: true,
                                                   accent: .blue, accentFill: .blue, onAccent: .white, rung: rung)
            let ideal = width(controls, scale: 1)
            let short = NSHostingController(rootView: controls)
                .sizeThatFits(in: CGSize(width: ideal - 40, height: 100)).width
            #expect(short == ideal, "at \(rung) the actions measure \(ideal)pt and squeeze to \(short)pt in \(ideal - 40)pt")
        }
    }

    /// Each rung is narrower than the one before it, at every text size, or `ViewThatFits` has
    /// nothing to choose between and the floor above measures the only rung there is.
    @Test func eachRungShedsWidth() async throws {
        let pdf = try await open(pages: 64)
        for percent in FontSize.selectablePercents {
            let widths = EditorPDFHeaderControls.Rung.allCases.map { chrome(pdf, $0, scale: FontSize(percent: percent).scale) }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 > $1 + 10 },
                    "at \(percent)% the rungs measure \(widths) — not each narrower than the last")
        }
    }

    /// The three file actions keep their bezel when they lose their words: one style for all three,
    /// with Expand and × outside it.
    @Test func theFileActionsShareOneBezelledStyle() throws {
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let tools = try ChromeGlassWiringTests.source("EditorPDFToolViews.swift")
        #expect(ChromeGlassWiringTests.count(".modifier(EditorPDFActionStyle(accent: accent))", in: card) == 2,
                "Find and Fill & Sign do not both wear the file actions' style")
        #expect(tools.contains(".modifier(EditorPDFActionStyle(accent: accent))"), "Tools does not wear the file actions' style")
        #expect(tools.contains("symbol: \"wrench.and.screwdriver\""), "Tools lost the wrench it has always drawn")
        // The bezel is the style's, not the word's: nothing in it reads the rung.
        let style = try #require(card.range(of: "struct EditorPDFActionStyle: ViewModifier {"))
        // Up to the struct's own closing brace: a fixed-length window would run on into Find's
        // button, which does read it.
        let rest = card[style.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"))
        let styleBody = String(rest[..<end.lowerBound])
        #expect(styleBody.contains(".buttonStyle(.hoverAffordance(.segment"), "the style's body was not found — vacuous")
        #expect(!styleBody.contains("worded"), "the bezel depends on whether the word is drawn")
    }

    /// The header chooses among all the rungs, widest first, in the name row's `ViewThatFits`.
    @Test func theHeaderChoosesAmongTheRungs() throws {
        let source = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(source.contains("ForEach(EditorPDFHeaderControls.Rung.allCases, id: \\.self) { rung in"))
        #expect(source.contains("accent: accent, accentFill: accentFill, onAccent: onAccent, rung: rung)"), "the actions are not drawn at the chosen rung")
    }
}
