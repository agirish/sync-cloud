import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// Does a selection-aware modifier still bind when it is applied to a `Group` that chooses between
/// two forms of a differences table, rather than to each `Table` inside it?
///
/// The shape: a sectioned Table (`Table(of:selection:sortOrder:columns:rows:)`) and a flat one
/// (`Table(_:selection:sortOrder:)`) inside a `Group { if … else … }`, with
/// `.contextMenu(forSelectionType:)` and an `.onKeyPress` on the Group. If this holds, neither
/// modifier needs duplicating into each branch.
///
/// This characterises SwiftUI, not `DifferencesView`, which now builds one `Table(of:)` for both
/// shapes. It is a canary for a silent failure: a context menu that never opens and a shortcut that
/// never fires look exactly like a table nobody right-clicked.
///
/// Each assertion has a control that must come out the other way (no menu attached, no key
/// handler), so a probe that reported "bound" for everything can't pass.
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

    /// One folder, so the sectioned form has one header: row 0 is the header, data starts at 1.
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

    /// The shape under test: both modifiers on the Group that chooses the branch.
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

    /// The alternative: the menu modifier applied inside each branch instead.
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

    /// Right-clicking a data row opens a menu in both branches, with the modifier on the Group.
    @Test func rightClickOpensAMenuThroughTheGroupInBothBranches() {
        for grouped in [true, false] {
            let menu = rightClick(groupWrapped(grouped: grouped, into: nil), row: grouped ? 1 : 0)
            #expect(menu != nil, "grouped=\(grouped)")
            #expect(menu?.items.map(\.title) == ["Probe"], "grouped=\(grouped)")
        }
    }

    /// The control for the test above: the same tables with no `.contextMenu` must find nothing.
    @Test func aTableWithNoContextMenuReportsNone() {
        for grouped in [true, false] {
            let bare = Group { table(grouped: grouped, selection: .constant([])) }
            #expect(rightClick(bare, row: grouped ? 1 : 0) == nil, "grouped=\(grouped)")
        }
    }

    /// The menu builder gets the clicked row's id: the differences menu is built from those ids, so
    /// an empty set would open a menu that offers nothing. The sectioned table counts its header
    /// as row 0, which correctly delivers an empty set.
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

    /// On the Group and on each Table deliver the same selection, so moving the modifier into each
    /// branch buys nothing. If the two ever diverge, that is the signal to duplicate it.
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

    // MARK: A key handler hung off the Group

    /// A `.onKeyPress` on the Group reaches its handler in both branches, with modifiers intact. A
    /// press stripped of its modifiers would silently do nothing. (⌘←/⌘→ in the app are menu key
    /// equivalents, not `.onKeyPress`.)
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
