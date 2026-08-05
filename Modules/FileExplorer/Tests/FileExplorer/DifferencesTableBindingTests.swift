import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// Does a selection-aware modifier still bind when it is applied to the `Group` that chooses
/// between the differences table's two forms, rather than to each `Table` inside it?
///
/// `DifferencesView.standardTableSection` branches between a sectioned Table
/// (`Table(of:selection:sortOrder:columns:rows:)`) and a flat one (`Table(_:selection:sortOrder:)`)
/// inside a `Group { if … else … }`, and hangs `.contextMenu(forSelectionType:)` and the ⌘←/⌘→
/// `.onKeyPress` off the Group. The columns cannot be hoisted (a `@TableColumnBuilder` result is
/// generic over its row type), so the alternative is duplicating both modifiers into both branches.
/// This suite is what says that duplication is unnecessary — and what will say so again if a future
/// macOS changes its mind.
///
/// **This characterises SwiftUI, not `DifferencesView`.** The view's own structure is private and
/// needs a live `FileSyncManager`; what is reproduced here is the SHAPE it depends on. That makes
/// this a canary rather than a proof of the shipped view, and it is worth having precisely because
/// the failure it watches for is silent: a context menu that never opens and a shortcut that never
/// fires look exactly like a table nobody right-clicked.
///
/// Every assertion below is paired with a control that must come out the other way — a subject with
/// no menu attached, a subject with no key handler. Without them a probe that returned "bound" for
/// everything would read as a clean pass.
@MainActor
@Suite(.serialized) struct DifferencesTableBindingTests {

    private static func diff(_ relativePath: String) -> FileDifference {
        FileDifference(relativePath: relativePath,
                       leftItemPath: "/l/\(relativePath)",
                       rightItemPath: "/r/\(relativePath)",
                       type: .missingOnRight,
                       action: .copyToRight,
                       description: "test")
    }

    /// One folder, so the sectioned form has exactly ONE header — which is what makes the row
    /// arithmetic below (`section header at 0, data from 1`) legible.
    private static let rows: [FileDifference] = (0..<8).map { diff("Work/file-\($0).pdf") }

    /// What the menu builder and the key handler were handed. A reference type: the closures are
    /// escaping and run inside SwiftUI's own update, not on this test's stack.
    private final class Recorder: @unchecked Sendable {
        var menuSelections: [Set<FileDifference.ID>] = []
        var keyModifiers: [EventModifiers] = []
    }

    // MARK: Subjects

    @ViewBuilder
    private func table(grouped: Bool, selection: Binding<Set<FileDifference.ID>>) -> some View {
        if grouped {
            Table(of: FileDifference.self, selection: selection,
                  sortOrder: .constant([KeyPathComparator(\FileDifference.fileName)])) {
                TableColumn("Name", value: \.fileName) { DifferenceNameCell(difference: $0) }
            } rows: {
                ForEach(DifferenceGrouping.sections(Self.rows)) { section in
                    SwiftUI.Section {
                        ForEach(section.rows) { TableRow($0) }
                    } header: {
                        Text(section.folder)
                    }
                }
            }
        } else {
            Table(Self.rows, selection: selection,
                  sortOrder: .constant([KeyPathComparator(\FileDifference.fileName)])) {
                TableColumn("Name", value: \.fileName) { DifferenceNameCell(difference: $0) }
            }
        }
    }

    /// The shipped shape: both modifiers on the Group that chooses the branch.
    private func groupWrapped(grouped: Bool, into recorder: Recorder?) -> some View {
        Group {
            table(grouped: grouped, selection: .constant([]))
        }
        .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
            if let recorder { let _ = recorder.menuSelections.append(ids) }
            Button("Probe") {}
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
            recorder?.keyModifiers.append(press.modifiers)
            return .handled
        }
    }

    /// The control the review proposed: each modifier applied inside each branch instead.
    @ViewBuilder
    private func perBranch(grouped: Bool, into recorder: Recorder) -> some View {
        table(grouped: grouped, selection: .constant([]))
            .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
                let _ = recorder.menuSelections.append(ids)
                Button("Probe") {}
            }
    }

    // MARK: Harness

    /// Hosts `view` in a real (never ordered-in) window and lays it out. Borderless and offscreen:
    /// nothing may appear on the machine running the suite.
    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let size = CGSize(width: 700, height: 420)
        let hostView = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        hostView.layoutSubtreeIfNeeded()
        // NSTableView fills its rows off a display pass, not off layout alone.
        if let rep = hostView.bitmapImageRepForCachingDisplay(in: hostView.bounds) {
            hostView.cacheDisplay(in: hostView.bounds, to: rep)
        }
        hostView.layoutSubtreeIfNeeded()
        return (window, hostView)
    }

    private func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTableView(in: $0) }.first
    }

    /// Right-clicks `row` and returns the menu AppKit would show, having let SwiftUI build it.
    private func rightClick(_ view: some View, row: Int) -> NSMenu? {
        let (window, hostView) = host(view)
        guard let table = firstTableView(in: hostView), table.numberOfRows > row else { return nil }
        let rect = table.rect(ofRow: row)
        let event = NSEvent.mouseEvent(with: .rightMouseDown,
                                       location: table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil),
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = table.menu(for: event)
        menu?.update()
        return menu
    }

    // MARK: Right-click

    /// The headline: right-clicking a data row opens a menu in BOTH branches, with the modifier
    /// where it ships — on the Group.
    @Test func rightClickOpensAMenuThroughTheGroupInBothBranches() {
        for grouped in [true, false] {
            let menu = rightClick(groupWrapped(grouped: grouped, into: nil), row: grouped ? 1 : 0)
            #expect(menu != nil, "grouped=\(grouped)")
            #expect(menu?.items.map(\.title) == ["Probe"], "grouped=\(grouped)")
        }
    }

    /// The control that makes the test above mean something: the same harness, the same tables, no
    /// `.contextMenu` — and it must find nothing. A probe that cannot report absence cannot report
    /// presence either.
    @Test func aTableWithNoContextMenuReportsNone() {
        for grouped in [true, false] {
            let bare = Group { table(grouped: grouped, selection: .constant([])) }
            #expect(rightClick(bare, row: grouped ? 1 : 0) == nil, "grouped=\(grouped)")
        }
    }

    /// Binding is not enough — `.contextMenu(forSelectionType:)` is SELECTION-aware, and the whole
    /// differences context menu is built from the ids it hands over. An empty set would render a
    /// menu that opens and offers nothing.
    ///
    /// Row indices differ by branch because the sectioned table counts its header as a row: with one
    /// folder, table row 0 is the "Work" header and data starts at 1. (Row 0 of the sectioned table
    /// really does deliver an empty set — correctly, a header is not a difference.)
    @Test func theClickedRowIsDeliveredToTheMenuBuilder() {
        for grouped in [true, false] {
            for dataIndex in 0..<3 {
                let recorder = Recorder()
                _ = rightClick(groupWrapped(grouped: grouped, into: recorder),
                               row: dataIndex + (grouped ? 1 : 0))
                let names = recorder.menuSelections.map { ids in
                    ids.compactMap { id in Self.rows.first(where: { $0.id == id })?.fileName }
                }
                #expect(names.contains(["file-\(dataIndex).pdf"]),
                        "grouped=\(grouped) dataIndex=\(dataIndex) got \(names)")
            }
        }
    }

    /// On the Group and on the Table are the same thing. This is the comparison that says moving the
    /// modifier into each branch would buy nothing — if the two ever diverge, THAT is the signal to
    /// duplicate them.
    @Test func theGroupAndPerBranchFormsDeliverTheSameSelection() {
        for grouped in [true, false] {
            let onGroup = Recorder(), onTable = Recorder()
            let row = grouped ? 2 : 1
            _ = rightClick(groupWrapped(grouped: grouped, into: onGroup), row: row)
            _ = rightClick(perBranch(grouped: grouped, into: onTable), row: row)
            #expect(!onGroup.menuSelections.filter { !$0.isEmpty }.isEmpty, "grouped=\(grouped)")
            #expect(onGroup.menuSelections == onTable.menuSelections, "grouped=\(grouped)")
        }
    }

    // MARK: ⌘←/⌘→

    /// The directional-copy shortcut reaches the handler through the Group, in both branches, with
    /// its modifiers intact — `KeyboardCopyIntent` reads ⌘ and ⇧ off the press, so a press that
    /// arrived stripped of them would silently do nothing.
    @Test func arrowKeysReachTheHandlerThroughTheGroup() {
        for grouped in [true, false] {
            let recorder = Recorder()
            let (window, hostView) = host(groupWrapped(grouped: grouped, into: recorder))
            guard let table = firstTableView(in: hostView) else {
                Issue.record("no table for grouped=\(grouped)"); continue
            }
            #expect(window.makeFirstResponder(table), "grouped=\(grouped)")
            for modifiers in [NSEvent.ModifierFlags.command, [.command, .shift], []] {
                window.sendEvent(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                    isARepeat: false, keyCode: 124)!)
            }
            #expect(recorder.keyModifiers.count == 3, "grouped=\(grouped) got \(recorder.keyModifiers)")
            #expect(recorder.keyModifiers.first?.contains(.command) == true, "grouped=\(grouped)")
            #expect(recorder.keyModifiers.dropFirst().first?.contains(.shift) == true, "grouped=\(grouped)")
            #expect(recorder.keyModifiers.last?.isEmpty == true, "grouped=\(grouped)")
        }
    }

    /// The matching control: no `.onKeyPress`, no presses recorded.
    @Test func aTableWithNoKeyHandlerRecordsNothing() {
        for grouped in [true, false] {
            let recorder = Recorder()
            let (window, hostView) = host(Group { table(grouped: grouped, selection: .constant([])) })
            guard let table = firstTableView(in: hostView) else {
                Issue.record("no table for grouped=\(grouped)"); continue
            }
            _ = window.makeFirstResponder(table)
            window.sendEvent(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                isARepeat: false, keyCode: 124)!)
            #expect(recorder.keyModifiers.isEmpty, "grouped=\(grouped)")
        }
    }
}
