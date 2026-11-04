import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Dashboard
import FileExplorerTestSupport

/// The Info inspector's door into Edit — the decision, and the button that carries it.
///
/// **The survey that preceded this change found no test at all of this action row**: not its count,
/// not its titles, not its order. So the rule is pinned as a value (it is one), and the row itself
/// is pinned by mounting it — the pure half alone would pass just as happily with the button never
/// added to the `HStack`.
@MainActor
@Suite struct DetailsEditorDoorTests {

    /// The inspector's own default width — `compareInspectorWidth`, 360 since it carries the preview
    /// (270 before). Every measurement here is taken at the width people actually have, because
    /// that is where the row once went wrong.
    static let inspectorWidth: CGFloat = 360

    private static func metadata(path: String, isDirectory: Bool = false) -> DetailsSidebar.FileMetadata {
        DetailsSidebar.FileMetadata(
            name: (path as NSString).lastPathComponent, path: path, kind: "Document",
            size: "12 bytes", creationDate: "Jan 1, 2026 at 9:00:00 AM",
            modificationDate: "Jan 1, 2026 at 9:00:00 AM", permissions: "644",
            isDirectory: isDirectory)
    }

    private final class Asked: @unchecked Sendable {
        var offered: [String] = []
        var opened: [String] = []
        func handOff(_ answer: @escaping (String) -> Bool = { _ in true }) -> EditorHandOff {
            EditorHandOff(isOffered: { self.offered.append($0); return answer($0) },
                          open: { self.opened.append($0) })
        }
    }

    // MARK: - The rule

    /// No hand-off is the resting state of the package: Dashboard knows nothing about an editor,
    /// and a host that has none gets exactly the row it always got.
    @Test func withNoHandOffTheRowIsUnchanged() {
        #expect(!DetailsSidebar.offersEditor(handOff: nil,
                                             data: Self.metadata(path: "/a/notes.md")))
    }

    /// **A folder never offers it**, even where the host says yes. This card renders for
    /// focused-FOLDER selections as well as single items, and a folder named `notes.md` would
    /// otherwise be handed to a text editor — `isOffered` reads a path and has no disk to ask.
    @Test func aFolderNeverOffersItEvenWhenTheHostSaysYes() {
        let asked = Asked()
        #expect(!DetailsSidebar.offersEditor(handOff: asked.handOff(),
                                             data: Self.metadata(path: "/a/notes.md",
                                                                 isDirectory: true)))
    }

    /// The host's answer is honoured in both directions.
    @Test func theHostDecidesForAFile() {
        let asked = Asked()
        #expect(DetailsSidebar.offersEditor(handOff: asked.handOff { _ in true },
                                            data: Self.metadata(path: "/a/notes.md")))
        #expect(!DetailsSidebar.offersEditor(handOff: asked.handOff { _ in false },
                                             data: Self.metadata(path: "/a/photo.jpg")))
    }

    /// **And it is asked about the PATH.** `data.name` would compile, read plausibly, and ask about
    /// "notes.md" for every file of that name anywhere — and about the wrong thing entirely for a
    /// host whose predicate resolves a path.
    @Test func theHostIsAskedAboutThePathAndNothingElse() {
        let asked = Asked()
        _ = DetailsSidebar.offersEditor(handOff: asked.handOff(),
                                        data: Self.metadata(path: "/a/deep/notes.md"))
        #expect(asked.offered == ["/a/deep/notes.md"], "the host was asked \(asked.offered)")
    }

    // MARK: - The button

    /// Every focus-ring view — one per drawn `Button` — in the root's coordinate space, in READING
    /// order: by line, then by x.
    private static func focusRings(_ root: NSView) -> [CGRect] {
        FocusRings.frames(in: root).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Mounts the inspector over a real path and pumps until its action row has drawn.
    ///
    /// A real file, because the row renders from a real `stat` — this is the one part of the card
    /// that cannot be faked from here. The wait is bounded on the row appearing AT ALL (three
    /// buttons draw whatever the hand-off says), never on the button under test.
    private func rings(over path: String, handOff: EditorHandOff?,
                       width: CGFloat = Self.inspectorWidth) async -> [CGRect] {
        let view = DetailsSidebar(syncManager: FileSyncManager(), leftPath: "", rightPath: "",
                                  overridePath: path, singleSource: false,
                                  cloudCoverage: nil, editorHandOff: handOff)
            .frame(width: width, height: 900)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        let drew = await LayoutPumpWait.pump(window, upTo: 10) { Self.focusRings(host).count >= 3 }
        #expect(drew.held, "the action row never drew — nothing below can be observed")
        let found = Self.focusRings(host)
        window.contentView = nil
        return found
    }

    /// **The button leads the row** — the order as a value, since the buttons are icons of one
    /// width and a rendered row cannot tell them apart: Open in Edit first where it is offered, as
    /// the row menu leads with it, and otherwise the same three in the same order.
    @Test func openInEditLeadsTheRow() {
        typealias Action = DetailsSidebar.InspectorAction
        #expect(DetailsSidebar.inspectorActionRow(offersEditor: true)
                == [.openInEdit, .quickLook, .revealInFinder, .copyPath])
        #expect(DetailsSidebar.inspectorActionRow(offersEditor: false)
                == [.quickLook, .revealInFinder, .copyPath])
    }

    /// **The button is drawn, and only with a hand-off** — counted against the very same mount
    /// without one, so the claim is about this button rather than about how many controls the
    /// panel happens to carry. The order above is a value; this is that the view consults it.
    @Test func aTextFileGainsOneButtonInTheRow() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("details-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try Data("hello".utf8).write(to: file)

        let asked = Asked()
        let without = await rings(over: file.path, handOff: nil)
        let with = await rings(over: file.path, handOff: asked.handOff())

        #expect(with.count == without.count + 1,
                "the row drew \(with.count) buttons with a hand-off and \(without.count) without")
        #expect(asked.offered.contains(file.path), "the row never asked the host about this file")
    }

    /// **The row fits on one line at the width people have, without squeezing.** The card's row of
    /// titled buttons squeezed to "Reve… / Cop… / Quic…" at 270pt and had to wrap; the inspector's
    /// is icons, and at its 360pt default every button keeps the width it has at 700.
    @Test func theRowFitsOnOneLineAtTheInspectorsWidth() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("details-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try Data("hello".utf8).write(to: file)

        let asked = Asked()
        let narrow = await rings(over: file.path, handOff: asked.handOff(),
                                 width: Self.inspectorWidth)
        let wide = await rings(over: file.path, handOff: asked.handOff(), width: 700)

        #expect(narrow.count == 4 && wide.count == 4, "the row drew \(narrow.count) and \(wide.count) buttons, not 4")
        #expect(zip(narrow, wide).allSatisfy { abs($0.width - $1.width) <= 1 },
                "the buttons squeezed at \(Self.inspectorWidth)pt: \(narrow.map(\.width)) vs \(wide.map(\.width))")
        // By centre, not top: the icons differ in height, so their rings' tops do too on one line.
        let centres = narrow.map(\.midY)
        #expect((centres.max() ?? 0) - (centres.min() ?? 0) <= 2,
                "the row wrapped at \(Self.inspectorWidth)pt: centres \(centres)")
    }

    /// **A folder draws the row it always drew.** The negative half of the count above, mounted
    /// rather than reasoned: `offersEditor` refusing a directory is only worth something if the
    /// view consults it.
    @Test func aFolderDrawsTheSameRowWithOrWithoutAHandOff() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("details-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let asked = Asked()
        let without = await rings(over: dir.path, handOff: nil)
        let with = await rings(over: dir.path, handOff: asked.handOff())
        #expect(with.count == without.count,
                "a folder gained a button: \(with.count) vs \(without.count)")
    }
}
