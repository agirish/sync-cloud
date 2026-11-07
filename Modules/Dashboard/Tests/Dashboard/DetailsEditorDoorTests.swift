import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Dashboard
import FileExplorerTestSupport

/// The Info inspector's door into Edit: the decision, and the button that carries it. The rule is
/// pinned as a value, and the row by mounting it, since the pure half alone would pass with the
/// button never added to the `HStack`.
@MainActor
@Suite struct DetailsEditorDoorTests {

    /// The inspector's default width, `compareInspectorWidth`. Measurements are taken at the width
    /// people actually have, where a squeezed row would show.
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

    /// No hand-off is the package's resting state: Dashboard knows nothing about an editor, and a
    /// host without one gets the plain row.
    @Test func withNoHandOffTheRowIsUnchanged() {
        #expect(!DetailsSidebar.offersEditor(handOff: nil,
                                             data: Self.metadata(path: "/a/notes.md")))
    }

    /// A folder never offers it, even where the host says yes. The card renders for focused
    /// folders too, and `isOffered` reads only a path, so a folder named `notes.md` would
    /// otherwise go to a text editor.
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

    /// The host is asked about the path. `data.name` would compile and read plausibly, but ask the
    /// same question for every "notes.md" anywhere, and the wrong one for a host that resolves
    /// paths.
    @Test func theHostIsAskedAboutThePathAndNothingElse() {
        let asked = Asked()
        _ = DetailsSidebar.offersEditor(handOff: asked.handOff(),
                                        data: Self.metadata(path: "/a/deep/notes.md"))
        #expect(asked.offered == ["/a/deep/notes.md"], "the host was asked \(asked.offered)")
    }

    // MARK: - The button

    /// Every focus-ring view (one per drawn `Button`) in the root's coordinate space, in reading
    /// order: by line, then by x.
    private static func focusRings(_ root: NSView) -> [CGRect] {
        FocusRings.frames(in: root).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Mounts the inspector over a real path and pumps until its action row has drawn. A real file,
    /// because the row renders from a real `stat`. The wait is on the row appearing at all (three
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

    /// Open in Edit leads the row where offered, as it leads the row menu; otherwise the same three
    /// in the same order. Pinned as a value, since same-width icons can't be told apart rendered.
    @Test func openInEditLeadsTheRow() {
        typealias Action = DetailsSidebar.InspectorAction
        #expect(DetailsSidebar.inspectorActionRow(offersEditor: true)
                == [.openInEdit, .quickLook, .revealInFinder, .copyPath])
        #expect(DetailsSidebar.inspectorActionRow(offersEditor: false)
                == [.quickLook, .revealInFinder, .copyPath])
    }

    /// A fresh temp directory holding `notes.md`, which the editor takes; removed by the caller.
    private func notesFile() throws -> (dir: URL, file: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("details-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("notes.md")
        try Data("hello".utf8).write(to: file)
        return (dir, file)
    }

    /// The button is drawn only with a hand-off, counted against the same mount without one so the
    /// claim is about this button, not the panel's control count. Shows the view consults the rule.
    @Test func aTextFileGainsOneButtonInTheRow() async throws {
        let (dir, file) = try notesFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let asked = Asked()
        let without = await rings(over: file.path, handOff: nil)
        let with = await rings(over: file.path, handOff: asked.handOff())

        #expect(with.count == without.count + 1,
                "the row drew \(with.count) buttons with a hand-off and \(without.count) without")
        #expect(asked.offered.contains(file.path), "the row never asked the host about this file")
    }

    /// The row fits on one line at the inspector's default width without squeezing: every icon
    /// button keeps the width it has at 700pt.
    @Test func theRowFitsOnOneLineAtTheInspectorsWidth() async throws {
        let (dir, file) = try notesFile()
        defer { try? FileManager.default.removeItem(at: dir) }

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

    /// A folder draws the same row with or without a hand-off: the mounted negative half of the
    /// count above, since `offersEditor` refusing a directory matters only if the view consults it.
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
