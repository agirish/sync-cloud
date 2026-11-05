import AppKit
import Design
import SwiftUI

/// The static shortcut listing behind Window ▸ Keyboard Shortcuts (⌘/). Pure data, pinned by
/// SyncCloudTests so it can't drift from the real chords: change a shortcut, update this list and
/// its pin test together.
enum ShortcutsReference {
    struct Item: Equatable {
        let keys: String
        let action: String
    }

    struct Group: Equatable {
        let title: String
        let items: [Item]
    }

    /// Where to split `groups` into two columns so their row counts come out closest. A header
    /// counts as a row. Never returns 0 or `count`, so both columns hold something. The two-column
    /// case of ``balancedColumns(_:count:)``, kept because its tests check the general form.
    static func balancedSplit(_ groups: [Group]) -> Int {
        guard groups.count > 1 else { return groups.count }
        let weights = groups.map { $0.items.count + 1 }
        let total = weights.reduce(0, +)
        var running = 0
        var best = 1
        var bestGap = Int.max
        for index in 1..<groups.count {
            running += weights[index - 1]
            let gap = abs(running - (total - running))
            if gap < bestGap { bestGap = gap; best = index }
        }
        return best
    }

    /// `groups` dealt into `count` columns, in reading order, so the tallest column is as short as
    /// it can be (a header counts as a row). Exhaustive, not greedy: greedy would put the two
    /// biggest groups in one column and leave the third nearly empty. Six groups into three
    /// columns is ten cuts, so exhaustive costs nothing.
    static func balancedColumns(_ groups: [Group], count: Int) -> [[Group]] {
        guard count > 1 else { return groups.isEmpty ? [] : [groups] }
        // Fewer groups than columns: one per column, and no empty columns after them.
        guard groups.count > count else { return groups.map { [$0] } }
        let weights = groups.map { $0.items.count + 1 }
        var best: [Int] = []
        var bestTallest = Int.max
        // Every strictly increasing choice of `count - 1` cut points in 1..<groups.count.
        func search(_ cuts: [Int], from start: Int) {
            if cuts.count == count - 1 {
                let bounds = [0] + cuts + [groups.count]
                let tallest = (0..<count).map { column in
                    weights[bounds[column]..<bounds[column + 1]].reduce(0, +)
                }.max() ?? 0
                if tallest < bestTallest { bestTallest = tallest; best = cuts }
                return
            }
            for cut in start..<groups.count where groups.count - cut >= count - 1 - cuts.count {
                search(cuts + [cut], from: cut + 1)
            }
        }
        search([], from: 1)
        let bounds = [0] + best + [groups.count]
        return (0..<count).map { Array(groups[bounds[$0]..<bounds[$0 + 1]]) }
    }

    /// How many columns the window draws. Three — see ``balancedColumns(_:count:)``.
    static let columnCount = 3

    static let groups: [Group] = [
        Group(title: "General", items: [
            // First, because it teaches all the others: hold ⌥ and the shortcuts appear on the
            // controls themselves.
            Item(keys: "Hold ⌥", action: "Show every on-screen shortcut as a key badge"),
            // Derived from the bar, not typed, so the row can't promise chords the bar no longer
            // has. `ShortcutsReferenceTests` pins the string against the enum.
            Item(keys: "⌘ 1 – ⌘ \(Workspace.allCases.count)",
                 action: "Switch workspace, in the bar’s order"),
            // Second: the one shortcut that reaches a place not on screen, which makes the rest of
            // this list optional.
            Item(keys: "⌘ K", action: "Go to — any place, folder, person, or a typed path"),
            // Routed by where the caret is, like ⌘F, so the row names both meanings.
            Item(keys: "⌘ I", action: "Show or hide the Info inspector — in Edit’s text, Italic"),
            Item(keys: "⌘ J", action: "Show or hide Ask Claude, to ask about the screen you’re on"),
            // The panel's own key, caught by `AskClaudeWindow` ahead of the field editor, not a
            // menu chord, so no registry check asks for this row.
            Item(keys: "⌥ Space", action: "In Ask Claude, talk; again to send, Esc to cancel"),
            Item(keys: "⌘ L", action: "Open Activity — runs, messages, Sync History and the log"),
            // The slider's own stops, never a size Settings can't reach. The same keys zoom a PDF
            // that has the keyboard (`PDFZoomVerbs`), so the row names both, as ⌘I's does.
            Item(keys: "⌘ + / ⌘ − / ⌘ 0", action: "Bigger / smaller / default text size, or zoom a focused PDF"),
            Item(keys: "⌘ ,", action: "Open Settings"),
            Item(keys: "⌘ /", action: "Show this shortcuts reference"),
            Item(keys: "⌘ ?", action: "Open SyncCloud Help"),
            // One row for two undo stacks, since the editor's text view keeps its own. A second
            // row would re-deal the columns and move the window.
            Item(keys: "⌘ Z / ⇧⌘ Z", action: "Undo / redo — the last file operation, or your typing in Edit"),
            // The progress window's Cancel. ⌘. and not Esc, which the window under it still owns
            // (`AppChord.cancelOperation`).
            Item(keys: "⌘ .", action: "Cancel the operation in progress"),
            // The file clipboard, not the text one — though each of these four hands the keystroke
            // back to the caret when a text field has it (`TextEditingChord`).
            Item(keys: "⌘ A", action: "Select everything in the focused pane’s current folder"),
            // No ⌘ on this one, and that is the point: it is a pane key, not a menu chord.
            Item(keys: "↩", action: "Rename the selected file or folder"),
            Item(keys: "⌘ C / ⌘ X / ⌘ V", action: "Copy or cut files, then paste — also to and from Finder"),
            Item(keys: "Esc", action: "Close the Settings overlay"),
        ]),
        Group(title: "Panes", items: [
            // First in the group: it decides which pane every row below acts on. "In Compare"
            // matters, because in Browse this chord steps tabs instead (see Tabs).
            Item(keys: "⌃ ⇥", action: "In Compare, focus the other pane — aims ⌘F, ⌘[ / ⌘] and ⇧⌘N"),
            // Routed by where the caret is (`FindInPaneCommand`), so the row names both
            // destinations.
            Item(keys: "⌘ F", action: "Find a file or folder in this pane — in Edit, in the document"),
            Item(keys: "⌘ [ / ⌘ ]", action: "Back / forward in the focused pane"),
            // One row, paired like ⌘[ / ⌘] above it, because two rows overflow the window. Placed
            // right under ⌘[ / ⌘] so the reader sees the difference: these stop at the first column.
            Item(keys: "⌘ ↓ / ⌘ ↑", action: "In Columns, open the selected folder / close the rightmost column, stopping at the first"),
            Item(keys: "⌘ R", action: "Scan both panes for changes"),
            Item(keys: "⇧⌘ N", action: "New folder in the focused pane’s current folder"),
            // ⌃⌘T shares the sidebar's row because a row of its own doesn't fit; the two toggle the
            // window's two side columns.
            Item(keys: "⌃⌘ S / ⌃⌘ T", action: "Show or hide sidebar / file list"),
            Item(keys: "⇧⌘ .", action: "Show or hide hidden files"),
            Item(keys: "⌘ ⌫", action: "Move the selected items to the Trash"),
            Item(keys: "Space", action: "Quick Look the selected item"),
            Item(keys: "⌘-click / ⇧-click", action: "Select multiple items"),
            // Under ⌘-click, which is how the two files it needs get selected.
            Item(keys: "⇧⌘ C", action: "Compare the two selected files side by side"),
            Item(keys: "⌥-click a breadcrumb", action: "Navigate both panes to that folder"),
        ]),
        // Its own group, not rows in Panes: these act on a document in Edit, and under a Panes
        // heading "Save" would read as an app-wide key.
        Group(title: "Edit", items: [
            // ⌘O shares ⌘N's row: a row of its own doesn't fit the window, and neither does a
            // longer wording that wraps. Edit's other entry points have no chord and are listed in
            // Help. "In Edit" stays because ⌘O also fires from Browse and Compare; "file", not
            // "text file", because it opens PDFs too.
            Item(keys: "⌘ N / ⌘ O", action: "New or selected file, in Edit"),
            // ⌘P shares ⌘S's row because a row of its own overflows the window; both take the open
            // document somewhere. File ▸ Export as PDF… is left out: it has no chord.
            Item(keys: "⌘ S / ⌘ P", action: "Save the open document — or print what Preview shows"),
            // One row for the three modes, which are one control. ⌃⌘E joins it as the fourth way
            // to show the document: a row of its own doesn't fit, and the action must stay at two
            // lines or the window overflows.
            Item(keys: "⌃⌘ 1 / ⌃⌘ 2 / ⌃⌘ 3 / ⌃⌘ E",
                 action: "Markdown’s Source / Preview / Split, or Expand"),
            // The Markup menu's chords. ⌘I is routed: the General row names both meanings, and this
            // one the half that applies here.
            Item(keys: "⌘ B / ⌘ I", action: "Bold / italic, with the caret in the text"),
            Item(keys: "⇧⌘ X / ⇧⌘ K / ⇧⌘ L", action: "Strikethrough / inline code / link"),
            // The find bar's verbs. No ⌘F row: its row in Panes names both destinations, and a
            // second row overflows the window. ⌃⌘L and ⇧⌘G share this row for the same reason;
            // ⇧⌘G steps back in both the text and the PDF find.
            Item(keys: "⌘ G / ⇧⌘ G / ⌘ E / ⌃⌘ L", action: "Find next / previous / use selection / go to line"),
            Item(keys: "Right-click", action: "Headings, lists and the rest of Markup — also Wrap Lines and spelling"),
        ]),
        Group(title: "Tabs", items: [
            Item(keys: "⌘ T", action: "New tab, at the folder this pane is showing"),
            Item(keys: "⌘ W", action: "Close the tab — or the window, on the last one"),
            Item(keys: "⇧⌘ ] / ⇧⌘ [", action: "Next / previous tab"),
            // States the split, since one chord doing two things is what a reference is for: ⌃⇥
            // switches panes in Compare and steps tabs in Browse, which has one pane. ⌃⇧⇥ is
            // Previous Tab everywhere, paired here to save a row.
            Item(keys: "⌃ ⇥ / ⌃⇧ ⇥", action: "Next / previous tab — in Compare, ⌃⇥ is the other pane"),
            Item(keys: "⇧⌘ T", action: "Show or hide the tab bar"),
            // No ⌘-double-click row: that gesture doesn't exist.
            // `testNoRowAdvertisesACommandDoubleClick` fails if the row comes back.
            Item(keys: "Right-click a folder", action: "Open that folder in a new tab"),
            // ⌘1…⌘9 are the workspaces', and a reader coming from Finder or Safari will try them.
            Item(keys: "⌘ 1 – ⌘ \(Workspace.allCases.count)", action: "Switch workspace — never tabs"),
        ]),
        Group(title: "Differences", items: [
            Item(keys: "⌘ → / ⌘ ←", action: "Copy the selected differences to the right / left pane"),
            Item(keys: "⇧⌘ → / ⇧⌘ ←", action: "Move the selected differences to the right / left pane"),
            Item(keys: "⇧⌘ R", action: "Step through each difference (Review)"),
            Item(keys: "⇧⌘ V", action: "Verify date-only differences by checksum"),
            Item(keys: "⌘ D", action: "Show or hide the differences list"),
            Item(keys: "⇧⌘ F", action: "Collapse or expand all folders"),
            Item(keys: "Space", action: "Quick Look the selected difference"),
        ]),
        Group(title: "Guided review", items: [
            Item(keys: "↩", action: "Copy the current item"),
            Item(keys: "⌫", action: "Skip the current item"),
            Item(keys: "Space", action: "Quick Look the current item"),
            Item(keys: "Esc", action: "End the review"),
        ]),
    ]
}

/// The Window-menu item that opens the shortcuts window, and the app's only registration of ⌘/.
/// A separate View because `openWindow` is an Environment value the App struct doesn't carry.
/// `everyDeclaredChordIsOnAMenuItem` fails if the chord loses this item.
struct ShortcutsWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: "keyboard-shortcuts") }
            .keyboardShortcut(AppChord.shortcutsReference.key, modifiers: AppChord.shortcutsReference.modifiers)
    }
}

/// The shortcuts window: titled groups of key/action rows. Static content, sized to fit — no state
/// beyond what `ShortcutsReference` provides.
struct ShortcutsReferenceView: View {
    /// The window at the default text size; ``windowSize(scale:)`` is the size drawn.
    ///
    /// The window can't be resized by hand, so this must fit every row.
    /// `theReferenceFitsItsWindowAtEveryTextSize` renders the rows and holds every text size to
    /// 12–60pt of space under the last row. Take the number from that measurement, never from
    /// adding up rows. Keep the height under ~800pt, a 13" display's usable height: when rows
    /// outgrow it, pair chords on an existing row before raising it. The ScrollView only covers a
    /// screen shorter than the window.
    static let windowSize = CGSize(width: 1240, height: 736)

    /// The keys column at the default text size.
    static let keysColumnWidth: CGFloat = 165

    /// How much the reference's type grows at `scale`, through the app's own ramp
    /// (`FontSize.scaledPointSize`). Not a flat multiply: the ramp damps above Default, and a
    /// window grown by the raw percentage would leave empty space under the last row.
    static func growth(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(12, scale: scale) / 12
    }

    /// The window at `scale`. The width grows with the type; the height grows much less, because a
    /// wider window wraps fewer action lines. Grown by the type's factor both ways, it would leave
    /// up to 150pt empty at the large sizes and still overflow at 90%.
    static func windowSize(scale: CGFloat) -> CGSize {
        let k = growth(scale: scale)
        return CGSize(width: (windowSize.width * k).rounded(),
                      height: (windowSize.height + heightPerGrowth * (k - 1)).rounded())
    }

    /// Points of window height per unit of type growth, fitted to the rows measured at every text
    /// size (656pt at 90% to 794pt at 135%) so each keeps 15–57pt under its last row. Re-measure
    /// when a row changes; Largest has the least room.
    static let heightPerGrowth: CGFloat = 260

    static func keysColumnWidth(scale: CGFloat) -> CGFloat {
        (keysColumnWidth * growth(scale: scale)).rounded()
    }

    /// `size`, held inside a screen of `visible` points with room for the title bar. At Largest the
    /// window is about 1590pt wide, more than a 13" display's 1470: a frame wider than the screen
    /// would be cut off at its right edge, where a narrower one only wraps and scrolls.
    static func fitted(_ size: CGSize, to visible: CGSize?) -> CGSize {
        guard let visible else { return size }
        return CGSize(width: min(size.width, visible.width - 40),
                      height: min(size.height, visible.height - 40))
    }

    @Environment(\.appFontScale) private var fontScale
    /// The visible size of the screen this window is on, once it is in one — see `WindowScreenReader`.
    @State private var windowScreen: CGSize?

    /// The screen to fit inside: the window's own, else the main screen until it has one. Not
    /// `NSScreen.main` alone, which is the key window's screen: on two displays the reference would
    /// open sized for the other one and keep that size when dragged across.
    static func screenToFit(window: CGSize?, main: CGSize?) -> CGSize? { window ?? main }

    var body: some View {
        let size = Self.fitted(Self.windowSize(scale: fontScale),
                               to: Self.screenToFit(window: windowScreen, main: NSScreen.main?.visibleFrame.size))
        ScrollView {
            ShortcutsReferenceContent()
        }
        .frame(width: size.width, height: size.height)
        .background(WindowScreenReader { windowScreen = $0 })
        .navigationTitle("Keyboard Shortcuts")
    }
}

/// Reports the visible size of the screen its window is on — when it joins a window and again
/// whenever that window moves to another screen (`NSWindow.didChangeScreenNotification`).
struct WindowScreenReader: NSViewRepresentable {
    let onChange: (CGSize?) -> Void

    func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }

    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange }

    /// A zero-sized view whose only job is to have a `window`.
    final class Probe: NSView {
        var onChange: (CGSize?) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (CGSize?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        /// Off the current layout pass: the callback writes SwiftUI state.
        private func report() {
            let size = window?.screen?.visibleFrame.size
            DispatchQueue.main.async { [weak self] in self?.onChange(size) }
        }
    }
}

/// The rows, split from the ScrollView so the fit test can measure their laid-out height — a
/// ScrollView reports the frame it is given, never its content's size. The groups are dealt into
/// columns by `balancedColumns`, which balances rows in reading order, so adding a group can't
/// leave one column far taller than the rest.
struct ShortcutsReferenceContent: View {
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        let columns = ShortcutsReference.balancedColumns(ShortcutsReference.groups,
                                                         count: ShortcutsReference.columnCount)
        HStack(alignment: .top, spacing: 32) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, groups in
                column(groups)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(_ groups: [ShortcutsReference.Group]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .scaledFont(.headline)
                    ForEach(group.items, id: \.action) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.keys)
                                .scaledFont(.system(.callout, design: .monospaced).weight(.medium))
                                .frame(width: ShortcutsReferenceView.keysColumnWidth(scale: fontScale),
                                       alignment: .leading)
                            Text(item.action)
                                .scaledFont(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // Each column takes its own ideal height, whatever the row beside it proposes. Otherwise a
        // short proposal shrinks the column's flexible `Text`s from the top and its first rows
        // truncate with an ellipsis. Horizontal stays flexible so the columns share the width
        // equally.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
