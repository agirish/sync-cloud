import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// Where the open document lives, on the Edit header's meta row — and the header as a card of its
/// own, the height of the pane's toolbar card (TE43).
///
/// The doors are pinned as data (`parts(rung:)`) because a `swift test` host cannot synthesize a
/// click into a hosted SwiftUI control; what the view DRAWS is pinned by focus rings, one per
/// control, the handle `PaneHeaderHeightTests.buttonCount` reaches for. The header card's height is
/// measured on the laid-out card, never compared as a constant to itself.
@MainActor
@Suite(.serialized) struct EditorHeaderLocationTests {

    // MARK: Fixtures

    private static let finance = [
        EditorDocumentLocation.Segment(name: "iCloud", target: ""),
        .init(name: "Documents", target: "Documents"),
        .init(name: "Finance", target: "Documents/Finance"),
    ]

    private static let deep = [
        EditorDocumentLocation.Segment(name: "iCloud", target: ""),
        .init(name: "Documents", target: "Documents"),
        .init(name: "Household Paperwork Archive", target: "Documents/Household Paperwork Archive"),
        .init(name: "Taxes and Statements 2019–2026", target: "Documents/Household Paperwork Archive/Taxes and Statements 2019–2026"),
        .init(name: "Quarterly Estimates", target: "Documents/Household Paperwork Archive/Taxes and Statements 2019–2026/Quarterly Estimates"),
    ]

    private static func location(_ segments: [EditorDocumentLocation.Segment],
                                 _ style: EditorDocumentLocation.Style) -> EditorDocumentLocation {
        EditorDocumentLocation(segments: segments, style: style,
                               help: segments.map(\.name).joined(separator: " › "))
    }

    private func document(named name: String) throws -> EditorDocument {
        let folder = NSTemporaryDirectory() + "loc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try "hello".write(toFile: path, atomically: true, encoding: .utf8)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: path, into: document)
        return document
    }

    private func workspace(_ document: EditorDocument, location: EditorDocumentLocation?,
                           showsRail: Bool = false) -> EditorWorkspaceView {
        EditorWorkspaceView(
            document: document,
            autosavePolicy: EditorAutosavePolicy(),
            folder: "/n/Finance",
            entries: [],
            showsRail: showsRail,
            railIsHidden: false,
            accent: .blue,
            onAccent: .white,
            mode: .constant(.edit),
            splitFraction: .constant(0.5),
            isNaming: .constant(false),
            typedName: .constant(""),
            railFilter: .constant(""),
            railFilterIsExpanded: .constant(false),
            railTab: .constant(.files),
            railOutlineAnchors: .constant([:]),
            undoManager: UndoManager(),
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            onOpen: { _ in },
            onCreate: { _ in true },
            onRevealInBrowse: { _ in },
            location: location,
            onLocationDoor: { _ in },
            onToggleJustTheText: {},
            onNewTextFile: {},
            onCloseDocument: {})
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil) -> NSHostingView<AnyView> {
        let root = AnyView(height.map { AnyView(view.frame(width: width, height: $0)) }
                           ?? AnyView(view.frame(width: width)))
        let hosted = NSHostingView(rootView: root)
        hosted.frame = CGRect(x: 0, y: 0, width: width, height: height ?? 400)
        let window = NSWindow(contentRect: hosted.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        return hosted
    }

    /// One `_FocusRingView` per focusable control — see `PaneHeaderHeightTests.buttonCount`.
    private func controls(in host: NSView) -> Int {
        var count = 0
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") { count += 1 }
            v.subviews.forEach(walk)
        }
        walk(host)
        return count
    }

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    // MARK: Which reading, by the pane's state

    /// #1 with the pane open, #2 with it collapsed — the pane's one bit, nothing else.
    /// Mutation: invert the ternary in `forPane(isOpen:)` and both lines fail.
    @Test func thePaneDecidesWhichReading() {
        #expect(EditorDocumentLocation.Style.forPane(isOpen: true) == .folderName)
        #expect(EditorDocumentLocation.Style.forPane(isOpen: false) == .crumb)
    }

    // MARK: The doors, as data

    /// **#1: one word, and it shows the file in the pane.** The folder's name after "in", with the
    /// whole path as its tooltip.
    @Test func theFolderNameIsOneDoorOntoThePane() {
        let parts = Self.location(Self.finance, .folderName).parts(rung: [])
        #expect(parts == [.control(title: "in Finance", door: .showInPane,
                                   help: "iCloud › Documents › Finance")])
    }

    /// **#2: every level is a door onto that level**, the target being the pane-relative path its
    /// crumb in the pane's own breadcrumb would navigate to — the source's top is `""`.
    @Test func everyCrumbIsADoorOntoItsOwnLevel() {
        let location = Self.location(Self.finance, .crumb)
        let parts = location.parts(rung: [0, 1, 2])
        #expect(parts == [
            .control(title: "iCloud", door: .goTo(""), help: "Go to iCloud"),
            .chevron,
            .control(title: "Documents", door: .goTo("Documents"), help: "Go to iCloud › Documents"),
            .chevron,
            .control(title: "Finance", door: .goTo("Documents/Finance"),
                     help: "Go to iCloud › Documents › Finance"),
        ])
    }

    /// A folder the pane cannot reach is still NAMED — the header must say where the file is — but
    /// offers no door, in either reading.
    @Test func aFolderOutsideTheSourceIsNamedButNotADoor() {
        let outside = EditorDocumentLocation(
            segments: [.init(name: "Scratch", target: nil)], style: .folderName, help: "~/Scratch")
        #expect(outside.parts(rung: []) == [.text("in Scratch", help: "~/Scratch")])
        let crumb = EditorDocumentLocation(
            segments: [.init(name: "Scratch", target: nil)], style: .crumb, help: "~/Scratch")
        #expect(crumb.parts(rung: [0]) == [.text("Scratch", help: "~/Scratch")])
    }

    /// The folded middle is a word, not a door, and its tooltip is the whole path it folds.
    @Test func theFoldedMiddleIsNotADoor() {
        let parts = Self.location(Self.finance, .crumb).parts(rung: [0, nil, 2])
        #expect(parts[2] == .text("…", help: "iCloud › Documents › Finance"))
        #expect(parts.filter { if case .control = $0 { return true } else { return false } }.count == 2)
    }

    // MARK: Fitting a long path

    /// **Widest first; middle levels go first; the source and the folder stay to the end.** The last
    /// rung is the folder alone — the one the view lets truncate.
    @Test func theRungsFoldTheMiddleFirst() {
        #expect(EditorDocumentLocation.rungs(segmentCount: 0).isEmpty)
        #expect(EditorDocumentLocation.rungs(segmentCount: 1) == [[0]])
        #expect(EditorDocumentLocation.rungs(segmentCount: 2) == [[0, 1], [1]])
        #expect(EditorDocumentLocation.rungs(segmentCount: 5) == [
            [0, 1, 2, 3, 4],
            [0, nil, 2, 3, 4],
            [0, nil, 3, 4],
            [0, nil, 4],
            [4],
        ])
        // Every rung but the last keeps both ends.
        for rung in EditorDocumentLocation.rungs(segmentCount: 5).dropLast() {
            #expect(rung.first == 0 && rung.last == 4, "rung \(rung) dropped the source or the folder")
        }
    }

    // MARK: What the header draws

    /// **The reading really branches, in what is drawn.** Measured in controls: `in Finance` is one
    /// more than no location at all, the three-level crumb three more — so a header that drew the
    /// crumb with the pane open, or the folder name with it collapsed, fails here.
    @Test func theHeaderDrawsOneDoorOpenAndOnePerLevelCollapsed() throws {
        let doc = try document(named: "Test.md")
        let none = controls(in: host(workspace(doc, location: nil).headerContent, width: 620))
        let open = controls(in: host(workspace(doc, location: Self.location(Self.finance, .folderName))
                                        .headerContent, width: 620))
        let collapsed = controls(in: host(workspace(doc, location: Self.location(Self.finance, .crumb))
                                             .headerContent, width: 620))
        #expect(open == none + 1, "pane open: \(open) controls against \(none) with no location")
        #expect(collapsed == none + 3, "pane collapsed: \(collapsed) controls against \(none) with no location")
    }

    /// **A long path shortens; it never wraps the header taller** — neither itself nor its
    /// neighbours. In the narrowest column the document can have, the deep crumb draws fewer doors
    /// than it has levels (a rung was taken), and the header is exactly as tall as the same header
    /// with NO location at all, at every text size, in both readings.
    ///
    /// The baseline is the header without a location, not one with a short path: the first version
    /// compared two locations, and at 135% both had squeezed "Autosave" onto two lines, so they
    /// agreed with each other while both were wrong. Mutation: drop the location's
    /// `layoutPriority(-1)` and 135% fails here.
    @Test func aLongPathFoldsAndNeverGrowsTheHeader() throws {
        let doc = try document(named: "Test.md")
        let width = EditorLayoutMetrics.minDocumentWidth
        for scale in scales {
            let bare = host(workspace(doc, location: nil)
                                .headerContent.environment(\.appFontScale, scale), width: width)
            for style in [EditorDocumentLocation.Style.crumb, .folderName] {
                let long = host(workspace(doc, location: Self.location(Self.deep, style))
                                   .headerContent.environment(\.appFontScale, scale), width: width)
                #expect(abs(long.fittingSize.height - bare.fittingSize.height) < 0.51,
                        "at \(scale), \(style): the header is \(long.fittingSize.height)pt with the long path, \(bare.fittingSize.height)pt with none")
            }
            let long = host(workspace(doc, location: Self.location(Self.deep, .crumb))
                               .headerContent.environment(\.appFontScale, scale), width: width)
            let none = controls(in: bare)
            let drawn = controls(in: long) - none
            #expect(drawn >= 1 && drawn < Self.deep.count,
                    "at \(scale) the deep crumb drew \(drawn) doors in \(width)pt — it did not fold")
        }
        // The control: with room, the whole path is drawn.
        let wide = controls(in: host(workspace(doc, location: Self.location(Self.deep, .crumb)).headerContent,
                                     width: 1_400))
        let wideNone = controls(in: host(workspace(doc, location: nil).headerContent, width: 1_400))
        #expect(wide - wideNone == Self.deep.count, "given 1,400pt the crumb still folded")
    }

    // MARK: The header card

    /// **The header card is the pane toolbar card's height, `LiquidGlass.headerHeight`, at every
    /// text size, for Markdown and plain text, in both readings** — measured on the laid-out card.
    /// And the rows inside it FIT: a pinned frame over content taller than itself would clip the
    /// meta row rather than grow, so the content's own height is held under the pin too.
    ///
    /// Mutation: drop `.frame(height: LiquidGlass.headerHeight)` from `headerCard` and the first
    /// expectation fails at every size.
    @Test func theHeaderCardIsTheToolbarCardsHeightAtEveryTextSize() throws {
        let markdown = try document(named: "note.md")
        let plain = try document(named: "note.txt")
        for doc in [markdown, plain] {
            for style in [EditorDocumentLocation.Style.folderName, .crumb] {
                for scale in scales {
                    let view = workspace(doc, location: Self.location(Self.finance, style))
                    let card = host(view.headerCard.environment(\.appFontScale, scale), width: 520)
                    #expect(abs(card.fittingSize.height - LiquidGlass.headerHeight) < 0.01,
                            "\(doc.name) \(style) at \(scale): the header card is \(card.fittingSize.height)pt")
                    let rows = host(EditorDocumentHeader { view.headerContent }
                                        .environment(\.appFontScale, scale), width: 520)
                    #expect(rows.fittingSize.height <= LiquidGlass.headerHeight,
                            "\(doc.name) \(style) at \(scale): the rows need \(rows.fittingSize.height)pt in a \(LiquidGlass.headerHeight)pt card")
                }
            }
        }
    }

    // MARK: Two cards

    /// Mounts the whole workspace in a surface style, and answers where the text view's scroll view
    /// starts — the top of the text card's content.
    private func textTop(_ doc: EditorDocument, style: SurfaceStyle, scale: CGFloat,
                         showsRail: Bool = false) throws -> CGFloat {
        let defaults = ScratchDefaults("EditorHeaderLocationTests")
        defaults.set(style.rawValue, forKey: LiquidGlass.surfaceStyleKey)
        let hosted = host(workspace(doc, location: Self.location(Self.finance, .crumb), showsRail: showsRail)
                            .defaultAppStorage(defaults)
                            .environment(\.appFontScale, scale),
                          width: 800, height: 500)
        var top: CGFloat?
        func walk(_ v: NSView) {
            if top != nil { return }
            if let scroll = v as? NSScrollView, scroll.documentView is NSTextView {
                top = scroll.convert(scroll.bounds, to: hosted).minY
                return
            }
            v.subviews.forEach(walk)
        }
        walk(hosted)
        return try #require(top, "no text view mounted — the measurement would be vacuous")
    }

    /// **Where the text card starts: under the header card, by the pane's own arithmetic.** In
    /// `.cards` that is two card insets and one header — header card's top inset, the header, its
    /// bottom inset — plus the text card's own top inset: the list card's top beside it. In
    /// `.unified` it is one region inset and the header, flush, as the pane's list is. At every
    /// text size, with and without the rail beside it.
    ///
    /// The cross-view half — this number against the REAL pane toolbar card's — is
    /// `EditHeaderMatchesPaneHeaderTests` in the Dashboard package, which can see both views.
    ///
    /// Mutations: put the header back inside the text card (one card) and `.cards` fails by a
    /// gutter; give `.unified` two cards and it fails by a gutter the other way.
    @Test func theTextCardStartsWhereThePanesListCardDoes() throws {
        let doc = try document(named: "note.md")
        let inset = LiquidGlass.cardInset
        for scale in scales {
            for showsRail in [false, true] {
                let cards = try textTop(doc, style: .cards, scale: scale, showsRail: showsRail)
                #expect(abs(cards - (3 * inset + LiquidGlass.headerHeight)) < 0.51,
                        "cards at \(scale), rail \(showsRail): the text starts at \(cards)")
                let unified = try textTop(doc, style: .unified, scale: scale, showsRail: showsRail)
                #expect(abs(unified - (inset + LiquidGlass.headerHeight)) < 0.51,
                        "unified at \(scale), rail \(showsRail): the text starts at \(unified)")
            }
        }
    }

    /// The meta row carries the location AFTER the autosave switch, so a folder name's width never
    /// slides the switch — a source scan of `metaRow`, comments stripped. Mutation: move the
    /// location block above `autosaveSwitch` and this fails.
    @Test func theLocationFollowsTheSwitch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/EditorWorkspaceView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in line.drop { $0 == " " }.hasPrefix("//") ? "" : line }
            .joined(separator: "\n")
        let row = try #require(code.range(of: "private var metaRow: some View {"))
        let end = try #require(code.range(of: "private func statusWord", range: row.upperBound..<code.endIndex))
        let body = String(code[row.upperBound..<end.lowerBound])
        let theSwitch = try #require(body.range(of: "autosaveSwitch"), "the switch left the meta row")
        let label = try #require(body.range(of: "EditorLocationLabel("), "the location is not on the meta row")
        #expect(theSwitch.lowerBound < label.lowerBound, "the location is drawn before the switch")
    }

    // MARK: The empty page

    /// **With no document open the header card is still drawn, at the same height, with its rows
    /// the height a document's rows are** — so nothing jumps when a file opens or closes. At every
    /// text size, with the pane open (`in Finance`), folded (the crumb) and with no folder at all.
    ///
    /// The rows are compared against a Markdown document's, the tallest header there is. Mutations:
    /// drop the hidden capsule from the empty title row, or the hidden switch from its meta row, and
    /// the rows come out shorter than a document's — the title would sit lower in the card on the
    /// empty page than on an open file.
    @Test func theEmptyPageKeepsTheHeaderCardAndItsRowsAtEveryTextSize() throws {
        let empty = EditorDocument()
        let markdown = try document(named: "note.md")
        let locations: [EditorDocumentLocation?] = [
            Self.location(Self.finance, .folderName), Self.location(Self.finance, .crumb), nil,
        ]
        for scale in scales {
            for location in locations {
                let view = workspace(empty, location: location)
                let card = host(view.headerCard.environment(\.appFontScale, scale), width: 520)
                #expect(abs(card.fittingSize.height - LiquidGlass.headerHeight) < 0.01,
                        "empty page at \(scale), \(String(describing: location?.style)): the header card is \(card.fittingSize.height)pt")
                let rows = host(view.emptyHeaderContent.environment(\.appFontScale, scale), width: 520)
                let open = host(workspace(markdown, location: location).headerContent
                                    .environment(\.appFontScale, scale), width: 520)
                #expect(abs(rows.fittingSize.height - open.fittingSize.height) < 0.51,
                        "at \(scale), \(String(describing: location?.style)): the empty header's rows are \(rows.fittingSize.height)pt, an open file's \(open.fittingSize.height)pt")
            }
        }
    }

    /// **The empty page draws its header, in both surface styles, and names the pane's folder** —
    /// counted in controls on the whole mounted workspace, since the header is the only thing on the
    /// empty page with any. The ＋ is one; the crumb's folder is words (the host hands the empty page
    /// a location whose own level has no door), so a three-level crumb adds two doors and
    /// `in Finance` adds none.
    ///
    /// Mutation: restore the empty page's one-card branch in `documentColumn` and both styles draw
    /// no header — zero controls.
    @Test func theEmptyPageDrawsItsHeaderAndNamesThePanesFolder() throws {
        let empty = EditorDocument()
        let paneFolder = Array(Self.finance.dropLast()) + [.init(name: "Finance", target: nil)]
        for style in [SurfaceStyle.cards, .unified] {
            let defaults = ScratchDefaults("EditorHeaderLocationTests.empty")
            defaults.set(style.rawValue, forKey: LiquidGlass.surfaceStyleKey)
            let crumb = host(workspace(empty, location: Self.location(paneFolder, .crumb))
                                .defaultAppStorage(defaults), width: 700, height: 400)
            #expect(controls(in: crumb) == 3,
                    "\(style): the empty page draws \(controls(in: crumb)) controls with a three-level crumb — the ＋ and two doors expected")
            let named = host(workspace(empty, location: Self.location(paneFolder, .folderName))
                                .defaultAppStorage(defaults), width: 700, height: 400)
            #expect(controls(in: named) == 1,
                    "\(style): the empty page draws \(controls(in: named)) controls with `in Finance` — the ＋ alone expected; the folder's name is words")
        }
        // The words themselves, as data: the folder's own level is text.
        #expect(Self.location(paneFolder, .folderName).parts(rung: [])
                == [.text("in Finance", help: "iCloud › Documents › Finance")])
    }

    /// The empty page says so in the header, and in the words a static carries so the test can read
    /// them. Mutation: change the string and this fails.
    @Test func theEmptyHeaderSaysNoDocumentIsOpen() {
        #expect(EditorWorkspaceView.emptyTitle == "No document open")
    }
}
