import Design
import SwiftUI

/// The static keyboard/mouse shortcut listing behind Window ▸ Keyboard Shortcuts (⌘/).
/// Pure data, pinned by SyncCloudTests so the reference can't silently drift from reality —
/// when a shortcut is added or changed, update this list and the pin test together.
enum ShortcutsReference {
    struct Item: Equatable {
        let keys: String
        let action: String
    }

    struct Group: Equatable {
        let title: String
        let items: [Item]
    }

    /// Where to break `groups` into two columns so their row counts come out closest.
    ///
    /// Counts a header as a row, because it occupies one. Never returns 0 or `count`, so both
    /// columns hold something even for a degenerate list. Kept as the two-column case of
    /// ``balancedColumns(_:count:)`` — the reference draws three now, but the two-way split is what
    /// its tests pinned and what the general form is checked against.
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

    /// `groups` dealt into `count` columns, in order, so the TALLEST column is as short as it can be.
    ///
    /// **Three columns since the Text and Markup menus arrived** (roadmap RD1). The reference grew
    /// by six chords and a text-size row, and two columns had no room left: the window was 800pt
    /// against a 13" display's usable height, and the rows measured 779. Growing sideways is the
    /// alternative that keeps the whole reference on screen — a reference you scroll is a
    /// reference you stop reading — and the roadmap's own recommendation.
    ///
    /// Minimises the maximum column weight, a header counting as a row, over every way of cutting
    /// the ordered list into `count` runs; the group order is the reading order and is never
    /// reshuffled. Exhaustive rather than greedy, because greedy dealing put General and Panes —
    /// the two biggest — together in one column and left the third nearly empty. Six groups into
    /// three columns is ten cuts to compare, so exhaustive costs nothing.
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
            // First, because it is the one entry that teaches all the others: hold it and the
            // shortcuts below appear on the controls themselves. A reference nobody opens can't
            // do that, which is the whole reason the reveal exists.
            Item(keys: "Hold ⌥", action: "Show every on-screen shortcut as a key badge"),
            // Derived from the bar rather than typed, because the bar has changed length three
            // times and this row is the kind of thing that stays behind: it read "⌘ 1 – ⌘ 5" for a
            // whole commit after the bar dropped to three segments, promising two chords that do
            // nothing. `ShortcutsReferenceTests` pins the derived string against the enum.
            Item(keys: "⌘ 1 – ⌘ \(Workspace.allCases.count)",
                 action: "Switch workspace, in the bar's order"),
            // Second: it is the one shortcut that can reach a place not currently on screen — a
            // workspace, one of Organize's lenses, a folder, a person, or an action — so it is
            // the entry that makes the rest of this list optional. (Unnumbered on purpose: the
            // count above is derived for exactly this reason, and Names folding into Renames took
            // the rail from six to five.)
            Item(keys: "⌘ K", action: "Go to — any place, folder, person, or a typed path"),
            // Routed by where the caret is, like ⌘F: the row has to name both meanings, because
            // this is the one place a reader is told the chord has two.
            Item(keys: "⌘ I", action: "Show or hide the Info inspector — in Edit's text, Italic"),
            Item(keys: "⌘ L", action: "Open the Activity Log"),
            // The slider's own stops, from the keyboard — never a size Settings cannot reach.
            Item(keys: "⌘ + / ⌘ − / ⌘ 0", action: "Bigger / smaller / default text size, on Settings' steps"),
            Item(keys: "⌘ ,", action: "Open Settings"),
            Item(keys: "⌘ /", action: "Show this shortcuts reference"),
            Item(keys: "⌘ ?", action: "Open SyncCloud Help"),
            // **One row for two stacks, and the wording has moved once already.** The editor's text
            // view keeps its own undo stack, so the chord means two different things depending on
            // where focus is. This read "(not typing)" — written when the parenthesis was the whole
            // truth, because there was no editor — and it survived the Edit workspace arriving with
            // an undo stack for precisely the typing it excludes. It now names both, in the order
            // the reader meets them. Amended in place rather than split into a second row, because
            // a new row re-breaks `balancedSplit`'s two columns and moves the window.
            Item(keys: "⌘ Z / ⇧⌘ Z", action: "Undo / redo — the last file operation, or your typing in Edit"),
            // The file clipboard, not the text one — though each of these four hands the keystroke
            // back to the caret when a text field has it (`TextEditingChord`).
            Item(keys: "⌘ A", action: "Select everything in the focused pane's current folder"),
            // No ⌘ on this one, and that is the point: it is a pane key, not a menu chord.
            Item(keys: "↩", action: "Rename the selected file or folder"),
            Item(keys: "⌘ C / ⌘ X / ⌘ V", action: "Copy or cut files, then paste — also to and from Finder"),
            Item(keys: "Esc", action: "Close the Settings overlay"),
        ]),
        Group(title: "Panes", items: [
            // Undocumented until the ⌥-reveal work went looking for every real shortcut in the
            // app and found this one had a control, a tooltip and no entry here.
            // First in this group, because it decides which pane every other row here acts on.
            // "In Compare" is load-bearing, not padding: this chord is the pane switch only where
            // there are two panes, and in Browse it steps tabs instead. The Tabs group below states
            // the split from the other side; leaving this row unqualified made one of the two wrong
            // wherever the reader happened to be.
            Item(keys: "⌃ ⇥", action: "In Compare, focus the other pane — aims ⌘F, ⌘[ / ⌘], ⇧⌘N and ⇧⌘P"),
            // Routed by where the caret is (`FindInPaneCommand`), so the row has to say so — this
            // is the only place a reader is told the chord has two destinations.
            Item(keys: "⌘ F", action: "Find a file or folder in this pane — in Edit, in the document"),
            Item(keys: "⌘ [ / ⌘ ]", action: "Back / forward in the focused pane"),
            Item(keys: "⌘ R", action: "Scan both panes for changes"),
            Item(keys: "⇧⌘ N", action: "New folder in the focused pane's current folder"),
            Item(keys: "⌃⌘ S", action: "Show or hide the sidebar"),
            Item(keys: "⇧⌘ .", action: "Show or hide hidden files"),
            Item(keys: "⇧⌘ P", action: "Show or hide the Columns preview"),
            Item(keys: "⌘ ⌫", action: "Delete the selected items, after confirming"),
            Item(keys: "Space", action: "Quick Look the selected item"),
            Item(keys: "⌘-click / ⇧-click", action: "Select multiple items"),
            // Directly under the gesture that creates its precondition: two files ⌘-clicked in one
            // pane is the whole enabling condition, and the row above is where a reader learns it.
            Item(keys: "⇧⌘ C", action: "Compare the two selected files side by side"),
            Item(keys: "⌥-click a breadcrumb", action: "Navigate both panes to that folder"),
        ]),
        // **Its own group rather than two rows in Panes**, which was the cheaper option and the
        // misleading one: both of these act on a document in one workspace, and a "Save" row under
        // a heading about panes reads as an app-wide key that saves something in Browse.
        Group(title: "Edit", items: [
            Item(keys: "⌘ N", action: "New text file in Edit's folder"),
            Item(keys: "⌘ S", action: "Save the open document"),
            // One row for the three modes: they are one control, and rows are the budget here.
            Item(keys: "⌃⌘ 1 / ⌃⌘ 2 / ⌃⌘ 3", action: "Source / Preview / Split, for a Markdown file"),
            // **The Markup chords, now that the Markup menu registers them.** This group carried a
            // note refusing them while nothing answered the keys — a reference listing ⌘B for a
            // chord nothing registers would be the one place in the app that lies about the
            // keyboard. ⌘I is routed: the General row above names both meanings, and this one
            // states the half that applies here.
            Item(keys: "⌘ B / ⌘ I", action: "Bold / italic, with the caret in the text"),
            Item(keys: "⇧⌘ X / ⇧⌘ K / ⇧⌘ L", action: "Strikethrough / inline code / link"),
            // The find bar's own verbs. **No ⌘F row here, and it was tried.** The chord's two
            // destinations are named on its one row in Panes; a second row for the editor's half
            // pushed the reference past its window, which `theReferenceFitsItsWindowWithoutScrolling`
            // caught. A fact that fits on an existing row belongs on it.
            Item(keys: "⌘ G / ⌘ E", action: "Find next / use the selection for find"),
            Item(keys: "Right-click", action: "Headings, lists and the rest of Markup — also Wrap Lines and spelling"),
        ]),
        Group(title: "Tabs", items: [
            Item(keys: "⌘ T", action: "New tab, at the folder this pane is showing"),
            Item(keys: "⌘ W", action: "Close the tab — or the window, on the last one"),
            Item(keys: "⇧⌘ ] / ⇧⌘ [", action: "Next / previous tab"),
            // The split is stated, because one chord doing two things is exactly what a reference
            // is for: ⌃⇥ has always been the pane switch, and Browse has one pane for it to switch
            // between. The Go menu's item names whichever it will do.
            Item(keys: "⌃ ⇥", action: "Next tab in Browse — the other pane in Compare"),
            Item(keys: "⇧⌘ T", action: "Show or hide the tab bar"),
            Item(keys: "Right-click a folder", action: "Open that folder in a new tab"),
            Item(keys: "⌘-double-click a folder", action: "Open it in a new tab, in Columns"),
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
            Item(keys: "Return", action: "Copy the current item"),
            Item(keys: "Delete", action: "Skip the current item"),
            Item(keys: "Space", action: "Quick Look the current item"),
            Item(keys: "Esc", action: "End the review"),
        ]),
    ]
}

/// The **Window**-menu item that opens the shortcuts window, and the one thing in the app that
/// registers ⌘/.
///
/// A separate View (not inline in the `.commands` builder) because `openWindow` is an Environment
/// value, which the App struct itself doesn't carry.
///
/// **It was in Help until `cd87b08e`, and for two commits it was nowhere.** That commit moved the
/// auxiliary windows out of Help — each was listed twice — and this was the only registration of
/// ⌘/, so removing its call site removed the chord while the reference below went on listing it.
/// `everyDeclaredChordIsOnAMenuItem` is what says so now.
struct ShortcutsWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: "keyboard-shortcuts") }
            .keyboardShortcut(AppChord.shortcutsReference.key, modifiers: AppChord.shortcutsReference.modifiers)
    }
}

/// The Help-menu shortcuts window: titled groups of key/action rows. Static content,
/// sized to fit — no state beyond what `ShortcutsReference` provides.
struct ShortcutsReferenceView: View {
    /// The window is `.contentSize`-resizable — the user cannot enlarge it — so this frame has
    /// to show the whole reference. The single 480pt column fit the sixteen rows it opened
    /// with; the twelve menu-bar chords took it to twenty-nine, which is 865pt of column —
    /// taller than a MacBook Air's screen — so the content went to two columns instead.
    /// `theReferenceFitsItsWindowWithoutScrolling` measures the laid-out content against this
    /// number, so a future row can move it but never silently overflow it; the ScrollView stays
    /// for the larger Settings ▸ Text sizes, which is all it is for.
    ///
    /// **560 → 600 when ⌘K was added.** The palette's row went into General, which is in the taller
    /// left column, and the content measured 593pt — the test caught it, which is exactly what it
    /// is for. Raising the window is the right half of its "raise windowSize or trim rows": every
    /// row here documents a chord that exists, so trimming would mean hiding one. 600pt still fits
    /// a 13" display's usable height with room to spare.
    ///
    /// **600 → 640 when ⌘? was listed.** Same column, same story, and the test caught it the same
    /// way: the content went to 614pt the moment the Help chord got the row it should always have
    /// had. 640 keeps a comparable margin and still clears a 13" display's usable height.
    ///
    /// **640 → 720 when the file clipboard arrived** (⌘A / ⌘X / ⌘C / ⌘V, §10). Four chords, and the
    /// test caught it the same way for the third time — three rows measured 707pt, so they were
    /// tightened to two and the content settled at **686pt measured**. 720 keeps a 34pt margin,
    /// comparable to the 26pt the last raise left, and still clears a 13" display. The pattern is
    /// worth naming now that it has repeated three times: **this window grows by chords, and the
    /// test is the only thing that notices** — nothing about the reference looks wrong until it is
    /// scrolled, and it is not scrollable.
    ///
    /// **720 → 780 when Browse's sidebar arrived** (⌃⌘S, §3). One row, in Panes beside the two
    /// other show/hide rungs it belongs with, and the content went to **743pt** — the fourth time
    /// the test has caught this and the first time a *single* row did it, which is the margin
    /// telling the truth about how little was left. 780 left 37pt, comparable to the 34 the raise
    /// before it left, and still cleared a 13" display's usable height.
    ///
    /// **780 → 740 when that row left again** (2026-08-20): the sidebar was held for v4.3
    /// (`FolderSidebarModel.isEnabled`), and a row describing a column that cannot appear is the
    /// same failure `testNoRowAdvertisesDragAndDrop` exists to catch. Content **measured 707pt**
    /// with the row gone, so 740 left 33pt. **The first time this window came back down**, and it
    /// came down for the reason it went up: the number is what the rows measure, not a high-water
    /// mark.
    ///
    /// **740 → 760 when the row returned for v4.4** (item #13, the sidebar switched on). The fifth
    /// time this has moved, and the first where the prediction in the paragraph above was wrong in
    /// an interesting way: one row usually costs ~36pt and 780 was expected back, but the content
    /// **measured 728pt** — a 21pt rise, because the row landed in *Panes* and `balancedSplit`
    /// re-broke the two columns around it. So 740 still fit, with 12pt to spare.
    ///
    /// **Raised anyway, and 12pt is the reason.** Every other raise here left 33–37pt, and this
    /// window neither scrolls nor resizes — 12pt is inside one line of ordinary text reflow, so
    /// "it fits today" and "it fits after a system font metric moves" are different claims. 760
    /// leaves **32pt**, squarely in the band the last four raises settled into, and stays under the
    /// 60pt ceiling `theReferenceFitsItsWindowWithoutScrolling` puts on empty space. Measured, not
    /// guessed: the number came from rendering `ShortcutsReferenceContent` at this width.
    ///
    /// **The Edit group cost nothing, and that is worth recording rather than assuming.** ⌘N and
    /// ⌘S arrived as a group of their own (a header plus two rows — three rows by `balancedSplit`'s
    /// counting, ~100pt of the ~36pt-a-row arithmetic every raise above used). The content still
    /// **measures 728pt**: the new group landed in the shorter column and the split re-broke around
    /// it, so the tall column did not grow. The sixth time this file has been measured, the second
    /// time rows were added without the window moving, and the same lesson both times — the number
    /// comes from rendering it, never from adding up rows.
    ///
    /// **760 → 800 when ⇧⌘C arrived** (CC15.3 — compare two selected files). The seventh move, and
    /// the first where a single row cost the full ~36pt rather than being absorbed by a re-break:
    /// it landed in *Panes*, under the ⌘-click row that creates its precondition, and Panes is
    /// already the taller column, so `balancedSplit` had nothing to give. Content **measured
    /// 779pt** against a 760pt window — caught by the test for the seventh time, and again by
    /// nothing else. 800 leaves **21pt**, below the 33–37pt band the middle raises settled into
    /// and above the 12pt that was judged too tight in the v4.4 note. Two things make 21 the right
    /// number rather than 815: this row cannot be trimmed (it documents a chord that exists, the
    /// standing rule here), and the group it joined is the one a re-break would move next, so
    /// buying margin now would likely be spending it twice. Measured, not guessed.
    ///
    /// **Two columns → three, 880×800 → 1240×700, when the Text and Markup menus arrived** (v5.3,
    /// roadmap RD1). Seven rows joined at once — the three view modes, the five markup chords on two
    /// rows, the find bar's pair, and a text-size row in General — and two columns could not hold
    /// them: at 800pt the window was already at a 13" display's usable height, so the reference had
    /// nowhere to grow but sideways. The eighth move, and the first that changed the SHAPE rather
    /// than the number: `ShortcutsReference.balancedColumns` deals the groups into three columns of
    /// the closest weight, in reading order, and the width grew by one column's worth. The height
    /// came down for the same reason it had gone up — it is what the rows measure, and three
    /// columns of the same rows are shorter: the content **measured 668pt** at this width (the
    /// first guess of 640 was caught by the test, as every number above was), so 700 leaves 32pt,
    /// in the band the earlier raises settled into and under the test's 60pt ceiling on empty space.
    static let windowSize = CGSize(width: 1240, height: 700)

    var body: some View {
        ScrollView {
            ShortcutsReferenceContent()
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .navigationTitle("Keyboard Shortcuts")
    }
}

/// The rows themselves, split from the ScrollView so the fits-the-window test can measure their
/// laid-out height — a ScrollView reports whatever frame it is given, never its content's size.
///
/// Two columns of groups, because one column of the full reference is taller than a small display.
///
/// **Split where the ROWS balance, not at the middle of the list.** It was the midpoint, and a
/// fifth group broke it: three groups landed left and two right, giving a 29-row column against a
/// 15-row one and a content height of 918pt against a 640pt window — the exact failure
/// `theReferenceFitsItsWindowWithoutScrolling` exists to catch, on a window the user cannot
/// enlarge. Balancing by row count keeps the reading order (General, Panes, Tabs, …) and puts the
/// break wherever the two columns come out closest, so a sixth group cannot reintroduce it.
///
/// **Three columns since v5.3**, dealt by `balancedColumns` — the same balancing, generalised,
/// after the Edit group grew past what two columns could hold in a window a 13" display can show.
struct ShortcutsReferenceContent: View {
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
                                .frame(width: 165, alignment: .leading)
                            Text(item.action)
                                .scaledFont(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // **Each column takes its own ideal height, whatever the row beside it proposes.** Without
        // this, the three-column layout compressed the third column: its top rows rendered on one
        // line with an ellipsis and the whole column sat 13pt low, while the two-column version
        // had never shown it. Rendered and read back rather than reasoned about — a standalone
        // probe reproduced it with the reference's own strings, and the effect scaled with how many
        // rows sat below (a column holding only Tabs was fine; Tabs over Differences truncated its
        // first row; all three groups truncated two). The column's `Text`s are flexible in height,
        // so a proposal short of the ideal shrinks them from the top; pinning the vertical size to
        // the ideal is what makes a `Text` in this list wrap rather than truncate. Horizontal stays
        // flexible so the columns still share the width equally.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
