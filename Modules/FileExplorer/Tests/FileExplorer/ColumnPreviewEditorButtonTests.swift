import AppKit
import Design
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The preview column's Edit button, as it is actually DRAWN.
///
/// `ColumnPreviewTests` pins the decision — `offersEditor(source:path:)` — and a pure decision is
/// where this repo puts anything a rendered assertion cannot see. But the decision being right is
/// not the same claim as the button existing: `PreviewAccessory`'s own doc records a swap replaced
/// by `if false` leaving every suite green, and the whole reason that value exists is that nothing
/// could observe the control. So this suite observes the control.
///
/// **Identity by measured width, because a hosted SwiftUI button exposes no readable text.**
/// SwiftUI builds no accessibility tree without an assistive client attached, so
/// `accessibilityChildren()` on a hosted view comes back empty under `swift test` — measured here
/// and in `OrganizeRailTests`. What AppKit does give is one focus-ring view per `Button`, at the
/// button's own intrinsic width. Rendering the same label alone yields that width, so the button
/// can be found inside the whole column without reading a single pixel of hard-coded geometry.
/// Nothing here is machine-pinned: every number is measured against another measurement.
@MainActor
@Suite struct ColumnPreviewEditorButtonTests {

    private static let root = "/editor-button"

    /// Main-queue turns allowed for the answered probe to reach a committed render: state write →
    /// `body` → layout is several turns, and bounding an ABSENCE by one turn makes "it did not
    /// happen" and "it has not happened yet" the same reading — mechanism 2 in
    /// `docs/flaky-tests.md`. The same budget is spent on every case here, so the positive and
    /// negative readings are comparable; the positive case failing to draw within it would fail
    /// this suite loudly rather than quietly weakening the negatives.
    private static let turnsToCommit = 24

    /// The column, with its probe answered by the test rather than by a `lstat`. `.cloudOnly` is
    /// unreachable otherwise (`SF_DATALESS` is settable only by a File Provider), and a real
    /// `.quickLook` would need a real file — this suite is about what is drawn from an answer, not
    /// about where the answer comes from.
    private struct Harness: View {
        let item: ColumnPreviewItem
        let source: ColumnPreviewSource
        let opened: Recorder

        var body: some View {
            ColumnPreviewColumn(item: item, paneToken: .singleSource, isAwaitingDownload: false,
                                onOpenInEditor: { opened.paths.append($0) })
                .environment(\.columnPreviewProbe, ColumnPreviewProbeReader { [source, opened] path in
                    await MainActor.run {
                        opened.probed.append(path)
                        return ColumnPreviewProbe(source: source, created: nil)
                    }
                })
        }
    }

    /// What the column told this test: which paths it probed, and which it handed to the editor.
    final class Recorder: @unchecked Sendable {
        var paths: [String] = []
        var probed: [String] = []
    }

    private static func item(_ name: String) throws -> ColumnPreviewItem {
        let path = "\(root)/\(name)"
        let node = FileNode(id: path, name: name, isDirectory: false, fileSize: 120)
        return try #require(ColumnPreview.item(
            selection: [path], deepestRows: PaneRow.project([node], side: .left, version: 1)))
    }

    /// Every focus-ring view in a hosted tree — one per `Button` — top to bottom, **in the root's
    /// coordinate space**. A ring's own `frame` is relative to its immediate superview, and nesting
    /// here is several levels deep: read raw, the button below reported `y = 0` in a 620pt column
    /// and a geometry assertion against it would have been about nothing at all.
    private static func focusRings(_ root: NSView) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRing") {
                found.append(v.convert(v.bounds, to: root))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found.sorted { $0.minY < $1.minY }
    }

    /// Whether a drawn control is the one whose solo render measured `width`.
    ///
    /// **A tolerance, and the reason is measured**: the same button renders 63pt alone and 62pt
    /// inside the identity block's constrained `HStack`. A point of layout rounding is not an
    /// identity change, and the controls this has to tell apart are 22pt apart (Edit 63, Download
    /// 85), so the window is wide enough to be robust and far too narrow to confuse them.
    private static func matches(_ frame: CGRect, _ width: CGFloat) -> Bool {
        abs(frame.width - width) <= 2
    }

    /// The width the Download button renders at — the OTHER control this column can draw, kept
    /// beside the one under test so "it drew something" can never stand in for "it drew Edit".
    private static func downloadButtonWidth() -> CGFloat {
        let host = NSHostingView(rootView: AnyView(Button("Download") {}))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        host.layoutSubtreeIfNeeded()
        return focusRings(host).first?.width ?? 0
    }

    /// The width the Edit button renders at on its own — the handle used to find it in the column.
    private static func editButtonWidth() -> CGFloat {
        let host = NSHostingView(rootView: AnyView(
            Button {} label: { Label("Edit", systemImage: "square.and.pencil") }
                .buttonStyle(.bordered)
                .controlSize(.small)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        host.layoutSubtreeIfNeeded()
        return focusRings(host).first?.width ?? 0
    }

    /// Mounts a column in a real window and pumps until its probe has been answered.
    private func mounted(_ item: ColumnPreviewItem, source: ColumnPreviewSource,
                         opened: Recorder, width: CGFloat = 420) async -> NSWindow {
        let host = NSHostingView(rootView: Harness(item: item, source: source, opened: opened)
            .frame(width: width, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        // **Bounded by the probe, then by turns — never by a condition this suite also asserts.**
        // Waiting for the button itself would make the positive case circular and give the negative
        // case no bound at all; waiting for the PROBE is the same budget for every case, and the
        // absence assertions are then about a column that has been told its answer.
        let answered = await LayoutPumpWait.pump(window, upTo: 10) { !opened.probed.isEmpty }
        #expect(answered.held, "the column never probed its file — nothing below can be observed")
        for _ in 0..<Self.turnsToCommit {
            window.layoutIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        window.layoutIfNeeded()
        return window
    }

    /// **A text file on disk draws the button; a PDF beside it does not.**
    ///
    /// The negative half is what makes the positive one a fact about this button rather than about
    /// whatever else the column happens to draw: same column, same mount, same wait, one extension
    /// of difference. Measured, the text column draws exactly one control and the PDF column draws
    /// none at all.
    @Test func aTextFileDrawsTheEditButtonAndAPDFDoesNot() async throws {
        let width = Self.editButtonWidth()
        #expect(width > 0, "the Edit button drew nothing even on its own — this suite is blind")

        let opened = Recorder()
        let text = await mounted(try Self.item("notes.md"), source: .quickLook, opened: opened)
        defer { text.contentView = nil }
        let drawnOnText = Self.focusRings(text.contentView!)
        #expect(drawnOnText.count == 1, "the text column drew \(drawnOnText.count) controls, not one")
        #expect(drawnOnText.allSatisfy { Self.matches($0, width) },
                "the one control drawn is not the Edit button: \(drawnOnText.map(\.width))")

        let pdf = await mounted(try Self.item("scan.pdf"), source: .quickLook, opened: opened)
        defer { pdf.contentView = nil }
        #expect(Self.focusRings(pdf.contentView!).isEmpty,
                "a PDF on disk drew a control the text file's Edit button is supposed to be")
    }

    /// **A cloud-only placeholder draws Download and not Edit.** The two are mutually exclusive by
    /// construction — `offersEditor` requires `.quickLook`, `PreviewAccessory.offer` requires
    /// `.cloudOnly` — and this is that exclusion as drawn, in the form where it would actually
    /// hurt: an Edit button over a dataless file asks the provider for every byte of it.
    ///
    /// Asserting WHICH control is drawn, not merely that Edit is absent: "no Edit button" is also
    /// true of a column that drew nothing, which would make this pass while the placeholder lost
    /// its Download button entirely.
    @Test func aCloudOnlyPlaceholderDrawsDownloadAndNotEdit() async throws {
        let edit = Self.editButtonWidth()
        let download = Self.downloadButtonWidth()
        #expect(abs(edit - download) > 4, "the two controls no longer measure apart — this cannot tell them apart")

        let opened = Recorder()
        let window = await mounted(try Self.item("notes.md"), source: .cloudOnly, opened: opened)
        defer { window.contentView = nil }
        let rings = Self.focusRings(window.contentView!)
        #expect(rings.count == 1, "the placeholder drew \(rings.count) controls, not just Download")
        #expect(rings.allSatisfy { Self.matches($0, download) },
                "the placeholder's control is not Download: \(rings.map(\.width))")
        #expect(!rings.contains { Self.matches($0, edit) }, "a cloud-only text file drew Edit")
    }

    /// **The button is drawn in the identity block, below the preview area** — never over a hosted
    /// `QLPreviewView`, which brings its own controls and is why this column deliberately has no
    /// click catcher of its own. Measured at 553pt down a 620pt column, against the placeholder's
    /// Download button at 332pt, which is what the preview area's own control looks like.
    @Test func theButtonIsDrawnInTheIdentityBlockNotOverThePreview() async throws {
        let width = Self.editButtonWidth()
        let opened = Recorder()
        let window = await mounted(try Self.item("notes.md"), source: .quickLook, opened: opened)
        defer { window.contentView = nil }
        let host = try #require(window.contentView)
        let button = try #require(Self.focusRings(host).first { Self.matches($0, width) },
                                  "the Edit button is not drawn at all")
        #expect(button.minY > host.frame.height / 2,
                "the Edit button is drawn in the preview's half of the column, at y \(button.minY)")
    }

    /// **A long name keeps its line; the button moves under it.**
    ///
    /// Found by rendering at the preview's 220pt floor, after this suite had shipped green: beside
    /// a long name the button took the name's line from "Quarterly planning notes / for the
    /// hous…ew 2026.md" down to "Quarterly / planni…26.md". Nothing here was checking the name,
    /// because every fixture was eight characters long.
    ///
    /// Asserted by where the button lands horizontally, which is the one reading that tells the two
    /// layouts apart: beside the name it is trailing-aligned, under the name it is leading-aligned.
    /// A short name at the same width is the control — it still gets the one-line layout, so this
    /// cannot pass by the button simply always stacking.
    @Test func aLongNameKeepsItsLineAndTheButtonMovesUnderIt() async throws {
        let width: CGFloat = 220
        let edit = Self.editButtonWidth()
        let opened = Recorder()

        let short = await mounted(try Self.item("notes.md"), source: .quickLook, opened: opened,
                                  width: width)
        defer { short.contentView = nil }
        let beside = try #require(Self.focusRings(short.contentView!).first { Self.matches($0, edit) },
                                  "no Edit button beside a short name")
        #expect(beside.minX > width / 2, "a short name no longer gets the one-line layout: x \(beside.minX)")

        let long = await mounted(
            try Self.item("Quarterly planning notes for the household budget review 2026.md"),
            source: .quickLook, opened: opened, width: width)
        defer { long.contentView = nil }
        let rings = Self.focusRings(long.contentView!)
        #expect(rings.count == 1, "the stacked layout drew \(rings.count) buttons — ViewThatFits built both")
        let under = try #require(rings.first { Self.matches($0, edit) }, "no Edit button under a long name")
        #expect(under.minX < width / 2,
                "the button stayed beside a long name at x \(under.minX), taking the name's line")
    }
}
