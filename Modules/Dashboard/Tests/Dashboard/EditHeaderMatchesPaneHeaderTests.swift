import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
@testable import FileExplorer
import FileExplorerTestSupport

/// Edit's document header against the pane's toolbar card, both real, side by side. The header
/// card must be the toolbar card's height, and the text card must start where the list card does,
/// at every text size. Each view's own suite can only compare itself to the constant
/// `LiquidGlass.headerHeight`; this one lays both out in one window and compares the results.
///
/// The pane half is `PaneHeader` over a `List`, carded as `ContentView.paneColumn` cards them:
/// `.paneCardIfNeeded` on each in `.cards`, one `.panesRegionFrame` round the pair in `.unified`.
/// `paneColumn` itself can't be built outside the app target; its pieces can.
@MainActor
@Suite(.serialized) struct EditHeaderMatchesPaneHeaderTests {

    private static let paneWidth: CGFloat = 320
    private static let editorWidth: CGFloat = 560
    private static let height: CGFloat = 520

    private static func paneHeader() -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Finance",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
    }

    /// The pane's tab strip, as `paneColumn` draws it above the header: two tabs, washed and
    /// carded the same way.
    private static func tabStrip() -> some View {
        PaneTabStrip(
            items: [
                .init(id: UUID(), title: "Finance", markImageName: "icloud-logo", isActive: true,
                      fullPath: "/Users/test/iCloud/Documents/Finance"),
                .init(id: UUID(), title: "Photos", markImageName: "icloud-logo", isActive: false,
                      fullPath: "/Users/test/iCloud/Photos"),
            ],
            onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in }, onDuplicate: { _ in },
            onCopyPath: { _ in }, onNew: {})
            .contentSurface(hue: .blue, tint: 0)
    }

    @ViewBuilder
    static func pane(_ style: SurfaceStyle, tabStrip showsStrip: Bool = false) -> some View {
        let list = List { Text("Test.md"); Text("Budget.md") }
        switch style {
        case .cards:
            VStack(spacing: 0) {
                if showsStrip { tabStrip().paneCardIfNeeded(.cards, level: .solid) }
                paneHeader().paneCardIfNeeded(.cards, level: .solid)
                list.paneCardIfNeeded(.cards, level: .solid)
            }
        case .unified:
            VStack(spacing: 0) {
                if showsStrip { tabStrip() }
                paneHeader()
                list
            }
            .panesRegionFrame(.unified, level: .solid)
        }
    }

    private static func document(_ name: String) throws -> EditorDocument {
        try TestTextFiles.document(named: name, text: "# Budget\n\nhello")
    }

    static func workspace(_ document: EditorDocument, style: EditorDocumentLocation.Style,
                          segments: [EditorDocumentLocation.Segment]? = nil,
                          showsRail: Bool = false, railIsHidden: Bool = false,
                          paneShowsTabStrip: Bool = false) -> EditorWorkspaceView {
        let segments = segments ?? [
            .init(name: "iCloud", target: ""), .init(name: "Documents", target: "Documents"),
            .init(name: "Finance", target: "Documents/Finance"),
        ]
        return .fixture(
            document: document, folder: "/n/Finance",
            entries: [EditorRailEntry(path: "/n/Finance/Test.md", name: "Test.md", size: 12,
                                      isCloudOnly: false)],
            showsRail: showsRail, railIsHidden: railIsHidden,
            location: EditorDocumentLocation(
                segments: segments, style: style,
                help: segments.map(\.name).joined(separator: " › ")),
            paneShowsTabStrip: paneShowsTabStrip)
    }

    /// Both halves in one window, the way `editorLayout`'s expanded arm puts them.
    static func mount(_ document: EditorDocument, style: SurfaceStyle, scale: CGFloat,
                      defaults: UserDefaults, tabStrip: Bool = false,
                      railIsHidden: Bool = false) -> NSHostingView<AnyView> {
        let size = CGSize(width: paneWidth + editorWidth, height: height)
        return ProbeRig(AnyView(
            HStack(spacing: 0) {
                pane(style, tabStrip: tabStrip).frame(width: paneWidth)
                workspace(document, style: .folderName, railIsHidden: railIsHidden,
                          paneShowsTabStrip: tabStrip)
                    .frame(width: editorWidth)
            }
            .frame(width: size.width, height: size.height)
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
        ), size: size).host
    }

    /// The top of the pane's list and of the document's text, in window coordinates. Each is the
    /// first thing in its card, so its top is the card's content top.
    static func tops(in host: NSView) -> (list: CGFloat?, text: CGFloat?) {
        var list: CGFloat?
        var text: CGFloat?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView {
                let frame = scroll.convert(scroll.bounds, to: host)
                if scroll.documentView is NSTextView {
                    if text == nil { text = frame.minY }
                } else if frame.midX < paneWidth, scroll.documentView is NSTableView {
                    if list == nil { list = frame.minY }
                }
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return (list, text)
    }

    /// The format bar is off unless asked for: with it on, the text card's first content is the bar,
    /// not the text. ``theFormatBarIsTheTextCardsFirstContent`` measures that case.
    static func defaults(_ style: SurfaceStyle, formatBar: Bool = false) -> ScratchDefaults {
        let defaults = ScratchDefaults("EditHeaderMatchesPaneHeaderTests")
        defaults.set(style.rawValue, forKey: LiquidGlass.surfaceStyleKey)
        defaults.set(GlassLevel.solid.rawValue, forKey: LiquidGlass.levelKey)
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(formatBar, forKey: EditorTextSettings.showsFormatBarKey)
        return defaults
    }

    /// The text card starts where the list card does, in both surface styles, at every text size,
    /// for Markdown and plain text, and under the pane's tab strip. The strip pushes the pane's
    /// toolbar card and list down by its slot (34pt, plus the gutter under its card in `.cards`);
    /// the document column has no strip, so it must be told about the pane's. Dropping the header
    /// card's pinned height must fail every case; giving `.unified` two cards must fail its half by
    /// a gutter; leaving out the strip's gutter must fail `.cards`, and not passing its presence both.
    @Test func theTextStartsWhereTheListDoesAtEveryTextSize() throws {
        let markdown = try Self.document("Budget.md")
        let plain = try Self.document("Budget.txt")
        for style in [SurfaceStyle.cards, .unified] {
            let defaults = Self.defaults(style)
            for (doc, strip) in [(markdown, false), (plain, false), (markdown, true)] {
                for size in FontSize.allCases {
                    let host = Self.mount(doc, style: style, scale: size.scale, defaults: defaults, tabStrip: strip)
                    let (list, text) = Self.tops(in: host)
                    let listTop = try #require(list, "no pane list mounted (\(style)) — vacuous")
                    let textTop = try #require(text, "no text view mounted (\(style)) — vacuous")
                    #expect(abs(listTop - textTop) < 0.51,
                            "\(style), \(doc.name)\(strip ? ", tab strip" : ""), \(size.percent)%: list at \(listTop), text at \(textTop)")
                }
            }
        }
    }

    /// The header card is the toolbar card's height, each measured as drawn, at every text size.
    /// Also on the empty page, where the header card is still drawn, so the two cards keep sharing
    /// an edge after a close. Also with Expand lit: its button at the end of the row wears a word
    /// ("Expand", then "Files"), and on the empty page is drawn only lit; neither may grow the card.
    /// Giving the worded pill vertical padding must fail the lit cases.
    @Test func theHeaderCardIsTheToolbarCardsHeightAtEveryTextSize() throws {
        let doc = try Self.document("Budget.md")
        let plain = try Self.document("Budget.txt")
        for size in FontSize.allCases {
            for style in [EditorDocumentLocation.Style.folderName, .crumb] {
                let toolbar = Self.laidOutHeight(
                    Self.paneHeader().paneCardIfNeeded(.cards, level: .solid)
                        .environment(\.appFontScale, size.scale))
                for document in [doc, plain, EditorDocument()] {
                    for railIsHidden in [false, true] {
                        let header = Self.laidOutHeight(
                            Self.workspace(document, style: style, railIsHidden: railIsHidden).headerCard
                                .bottomSectionCard(.cards, level: .solid)
                                .environment(\.appFontScale, size.scale))
                        #expect(abs(toolbar - header) < 0.51,
                                "\(size.percent)% \(style) \(document.path == nil ? "empty page" : document.name), Expand \(railIsHidden ? "lit" : "off"): toolbar card \(toolbar)pt, header card \(header)pt")
                        // The card is pinned, so its frame proves little: the rows the app draws
                        // must fit too, or the pin is clipping a header that grew. On the empty
                        // page those are its own rows, not a document's.
                        let ws = Self.workspace(document, style: style, railIsHidden: railIsHidden)
                        let content = document.path == nil ? AnyView(ws.emptyHeaderContent) : AnyView(ws.headerContent)
                        let rows = Self.laidOutHeight(
                            content
                                .padding(.vertical, 8)
                                .environment(\.appFontScale, size.scale))
                        #expect(rows <= LiquidGlass.headerHeight + 0.5,
                                "\(size.percent)% \(style) \(document.path == nil ? "empty page" : document.name), Expand \(railIsHidden ? "lit" : "off"): the rows need \(rows)pt in a \(LiquidGlass.headerHeight)pt card")
                    }
                }
            }
        }
    }

    /// With the format bar on, the bar is the text card's first content: it starts where the pane's
    /// list does, less its inset, and the text starts under it. The bar lives in the text card so
    /// the header stays pinned. Drawing the bar in the header must fail the header test above (its
    /// rows are measured with the bar on); padding the bar from below must fail this one.
    @Test func theFormatBarIsTheTextCardsFirstContent() throws {
        let markdown = try Self.document("Budget.md")
        for style in [SurfaceStyle.cards, .unified] {
            let on = Self.defaults(style, formatBar: true)
            for size in FontSize.allCases {
                let (list, withBar) = Self.tops(in: Self.mount(markdown, style: style, scale: size.scale, defaults: on))
                let listTop = try #require(list, "no pane list mounted (\(style)) — vacuous")
                let barTop = try #require(withBar, "no text view mounted under the bar (\(style)) — vacuous")
                let bar = NSHostingView(rootView: AnyView(
                    EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in },
                                    forcedRung: EditorFormatBar.ladder(showsLabels: true, inTable: false)[0])
                        .environment(\.appFontScale, size.scale))).fittingSize.height
                #expect(abs(barTop - listTop - (EditorWorkspaceView.formatBarInset + bar)) < 0.51,
                        "\(style), \(size.percent)%: the text starts \(barTop - listTop)pt under the list's top, not the bar's \(EditorWorkspaceView.formatBarInset) + \(bar)")
            }
        }
    }

    private static func laidOutHeight<V: View>(_ view: V) -> CGFloat {
        // The bar on, so a bar moved into the header would grow the rows this measures.
        let defaults = defaults(.cards, formatBar: true)
        return ProbeRig(AnyView(view.frame(width: editorWidth).defaultAppStorage(defaults)),
                        size: CGSize(width: editorWidth, height: 1_000)).host.fittingSize.height
    }
}
