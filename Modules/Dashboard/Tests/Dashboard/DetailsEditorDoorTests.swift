import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Dashboard

/// The Info inspector's door into Edit — the decision, and the button that carries it.
///
/// **The survey that preceded this change found no test at all of this action row**: not its count,
/// not its titles, not its order. So the rule is pinned as a value (it is one), and the row itself
/// is pinned by mounting it — the pure half alone would pass just as happily with the button never
/// added to the `HStack`.
@MainActor
@Suite struct DetailsEditorDoorTests {

    /// The inspector's own default width — `compareInspectorWidth`, 270. Every measurement here is
    /// taken at the width people actually have, because that is where this row went wrong.
    static let inspectorWidth: CGFloat = 270

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
    /// order. Sorted by line first: the row wraps, so x alone scrambles the order it is read in.
    private static func focusRings(_ root: NSView) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRing") {
                found.append(v.convert(v.bounds, to: root))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Mounts the inspector over a real path and pumps until its action row has drawn.
    ///
    /// A real file, because the row renders from a real `stat` — this is the one part of the card
    /// that cannot be faked from here. The wait is bounded on the row appearing AT ALL (three
    /// buttons draw whatever the hand-off says), never on the button under test.
    private func rings(over path: String, handOff: EditorHandOff?,
                       width: CGFloat = Self.inspectorWidth) async -> [CGRect] {
        let view = DetailsSidebar(syncManager: FileSyncManager(), leftPath: "", rightPath: "",
                                  compact: true, overridePath: path, singleSource: false,
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

    /// **The button is drawn, first in the row, and only with a hand-off.**
    ///
    /// Counted against the very same mount without one, so the claim is about this button rather
    /// than about how many controls the card happens to carry. First by x, because the order is
    /// the point: the row leads with the editor exactly as the row context menu now does.
    @Test func aTextFileGainsOneButtonAtTheHeadOfTheRow() async throws {
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

        // **The extra button is at the HEAD, and this is the assertion that says so.**
        //
        // The first version of this check compared leading x-positions and "the second button is
        // right of the first" — both of which are ALSO true when the button is appended to the end
        // of the row. Measured: moving it after Quick Look left all six tests green, which is the
        // finding that produced this one. What distinguishes the two is the row AFTER the first
        // button: lead with the editor and the remainder is the original row, in order, width for
        // width; append it and the tail is a different set of widths entirely.
        let tail = Array(with.dropFirst())
        #expect(tail.count == without.count)
        #expect(zip(tail, without).allSatisfy { abs($0.width - $1.width) <= 1 },
                "after the first button this is not the row it was: \(tail.map(\.width)) vs \(without.map(\.width))")
        #expect(abs((with.first?.width ?? 0) - (without.first?.width ?? 0)) > 1,
                "the first button is the same control it was — the editor did not take the head")
        #expect(asked.offered.contains(file.path), "the row never asked the host about this file")
    }

    /// **The row WRAPS rather than squeezing, at the width people actually have.**
    ///
    /// This is the finding that changed the shape of this change. The inspector is 270pt by
    /// default, and the action row was an `HStack`: rendered there with its three shipped buttons
    /// it already read "Reve… / Cop… / Quic…", and a fourth took two of them to an icon and a bare
    /// ellipsis — a control with no letters in it at all. `FlowLayout` exists for exactly this
    /// ("an `HStack` that squeezed rather than wrapped" is the defect its own doc names), so the
    /// row uses it and every title survives at every width.
    ///
    /// Asserted as "the same buttons measure the same at 270 as at 700": a squeezing row's widths
    /// collapse as the container narrows, a wrapping row's do not. And it really does wrap at 270 —
    /// otherwise this would hold for a row that simply fitted.
    @Test func theRowWrapsRatherThanSqueezingAtTheInspectorsWidth() async throws {
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

        #expect(narrow.count == wide.count, "the narrow row dropped a button")
        #expect(zip(narrow, wide).allSatisfy { abs($0.width - $1.width) <= 1 },
                "the buttons squeezed at \(Self.inspectorWidth)pt: \(narrow.map(\.width)) vs \(wide.map(\.width))")
        #expect(Set(narrow.map(\.minY)).count > 1,
                "the row did not wrap at \(Self.inspectorWidth)pt, so this proves nothing about squeezing")
        #expect(Set(wide.map(\.minY)).count == 1, "the wide row wrapped, where everything fits on one line")
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
