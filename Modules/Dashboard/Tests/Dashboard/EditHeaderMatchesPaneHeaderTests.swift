import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
@testable import FileExplorer

/// **Edit's document header against the pane's toolbar card, both real, side by side** (TE43).
///
/// The request was that the document's header card be the file pane's toolbar card's height, and
/// that the text card start where the list card does — at every text size. Each view's own suite
/// can only compare itself to `LiquidGlass.headerHeight`, which is a constant agreeing with itself;
/// this suite is the one place both views can be laid out in one window, so it compares the two
/// LAID-OUT results against each other.
///
/// The pane half is `PaneHeader` over a `List`, carded exactly as `ContentView.paneColumn` cards
/// them — `.paneCardIfNeeded` on each in `.cards`, one `.panesRegionFrame` round the pair in
/// `.unified` (what `editorLayout`'s expanded arm applies). The app's `paneColumn` itself cannot be
/// built outside the app target; the pieces it is made of can.
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

    @ViewBuilder
    private static func pane(_ style: SurfaceStyle) -> some View {
        let list = List { Text("Test.md"); Text("Budget.md") }
        switch style {
        case .cards:
            VStack(spacing: 0) {
                paneHeader().paneCardIfNeeded(.cards, level: .solid)
                list.paneCardIfNeeded(.cards, level: .solid)
            }
        case .unified:
            VStack(spacing: 0) {
                paneHeader()
                list
            }
            .panesRegionFrame(.unified, level: .solid)
        }
    }

    private static func document(_ name: String) throws -> EditorDocument {
        let folder = NSTemporaryDirectory() + "edit-vs-pane-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try "# Budget\n\nhello".write(toFile: path, atomically: true, encoding: .utf8)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: path, into: document)
        return document
    }

    static func workspace(_ document: EditorDocument, style: EditorDocumentLocation.Style,
                          segments: [EditorDocumentLocation.Segment]? = nil,
                          showsRail: Bool = false, railIsHidden: Bool = false) -> EditorWorkspaceView {
        let segments = segments ?? [
            .init(name: "iCloud", target: ""), .init(name: "Documents", target: "Documents"),
            .init(name: "Finance", target: "Documents/Finance"),
        ]
        return EditorWorkspaceView(
            document: document, autosavePolicy: EditorAutosavePolicy(), folder: "/n/Finance",
            entries: [EditorRailEntry(path: "/n/Finance/Test.md", name: "Test.md", size: 12,
                                      isCloudOnly: false)],
            showsRail: showsRail, railIsHidden: railIsHidden, accent: .blue, onAccent: .white,
            mode: .constant(.edit), splitFraction: .constant(0.5), isNaming: .constant(false),
            typedName: .constant(""), railFilter: .constant(""),
            railFilterIsExpanded: .constant(false), railTab: .constant(.files),
            railOutlineAnchors: .constant([:]), undoManager: UndoManager(),
            prefilledName: { "Untitled.md" }, refusal: { _ in nil },
            onOpen: { _ in }, onCreate: { _ in true }, onRevealInBrowse: { _ in },
            location: EditorDocumentLocation(
                segments: segments, style: style,
                help: segments.map(\.name).joined(separator: " › ")),
            onLocationDoor: { _ in }, onToggleJustTheText: {})
    }

    /// Both halves in one window, the way `editorLayout`'s expanded arm puts them.
    private static func mount(_ document: EditorDocument, style: SurfaceStyle, scale: CGFloat,
                              defaults: UserDefaults) -> NSHostingView<AnyView> {
        let size = CGSize(width: paneWidth + editorWidth, height: height)
        let host = NSHostingView(rootView: AnyView(
            HStack(spacing: 0) {
                pane(style).frame(width: paneWidth)
                workspace(document, style: .folderName).frame(width: editorWidth)
            }
            .frame(width: size.width, height: size.height)
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The top of the pane's list and of the document's text, in the window's coordinates — each is
    /// the first thing in its card, so its top IS the card's content top.
    private static func tops(in host: NSView) -> (list: CGFloat?, text: CGFloat?) {
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

    private static func defaults(_ style: SurfaceStyle) -> ScratchDefaults {
        let defaults = ScratchDefaults("EditHeaderMatchesPaneHeaderTests")
        defaults.set(style.rawValue, forKey: LiquidGlass.surfaceStyleKey)
        defaults.set(GlassLevel.solid.rawValue, forKey: LiquidGlass.levelKey)
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        return defaults
    }

    /// **The text card starts where the list card does**, in both surface styles, at every text
    /// size, for Markdown and plain text. Mutation: drop the header card's pinned height and every
    /// case fails; give `.unified` two cards and its half fails by a gutter.
    @Test func theTextStartsWhereTheListDoesAtEveryTextSize() throws {
        let markdown = try Self.document("Budget.md")
        let plain = try Self.document("Budget.txt")
        for style in [SurfaceStyle.cards, .unified] {
            let defaults = Self.defaults(style)
            for doc in [markdown, plain] {
                for size in FontSize.allCases {
                    let host = Self.mount(doc, style: style, scale: size.scale, defaults: defaults)
                    let (list, text) = Self.tops(in: host)
                    let listTop = try #require(list, "no pane list mounted (\(style)) — vacuous")
                    let textTop = try #require(text, "no text view mounted (\(style)) — vacuous")
                    #expect(abs(listTop - textTop) < 0.51,
                            "\(style), \(doc.name), \(size.percent)%: list at \(listTop), text at \(textTop)")
                }
            }
        }
    }

    /// **The header card is the toolbar card's height**, each measured as the card it is drawn as,
    /// at every text size. This is the claim in the request's words; the test above is the same
    /// claim seen where it shows.
    ///
    /// **And on the empty page** — no document open, the header card is still drawn and still this
    /// height, so the toolbar card and the header card go on sharing an edge after a close.
    @Test func theHeaderCardIsTheToolbarCardsHeightAtEveryTextSize() throws {
        let doc = try Self.document("Budget.md")
        for size in FontSize.allCases {
            for style in [EditorDocumentLocation.Style.folderName, .crumb] {
                let toolbar = Self.laidOutHeight(
                    Self.paneHeader().paneCardIfNeeded(.cards, level: .solid)
                        .environment(\.appFontScale, size.scale))
                for document in [doc, EditorDocument()] {
                    let header = Self.laidOutHeight(
                        Self.workspace(document, style: style).headerCard
                            .bottomSectionCard(.cards, level: .solid)
                            .environment(\.appFontScale, size.scale))
                    #expect(abs(toolbar - header) < 0.51,
                            "\(size.percent)% \(style) \(document.path == nil ? "empty page" : document.name): toolbar card \(toolbar)pt, header card \(header)pt")
                }
            }
        }
    }

    private static func laidOutHeight<V: View>(_ view: V) -> CGFloat {
        let defaults = defaults(.cards)
        let host = NSHostingView(rootView: AnyView(view.frame(width: editorWidth)
                                                    .defaultAppStorage(defaults)))
        host.frame = CGRect(x: 0, y: 0, width: editorWidth, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
