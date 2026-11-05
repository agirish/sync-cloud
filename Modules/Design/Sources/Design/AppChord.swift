import SwiftUI

/// One chord, one truth. Every menu-registered shortcut that also appears on a control (an
/// ⌥-reveal keycap, a tooltip) is declared here once: the menu item registers `key` + `modifiers`,
/// the keycap shows `display`. `display` is derived from the registration, so a badge can't
/// advertise a key that no longer fires; `AppChordTests` pins each display so a key change fails
/// by name.
///
/// Role keys (`esc` on a cancel button, `⏎` on a default button, `␣` for Quick Look) stay literal
/// at their call sites: they aren't menu-registered, and their keycap names a role.
public struct AppChord: Sendable {
    public let key: KeyEquivalent
    public let modifiers: EventModifiers

    public init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// What the keycap and tooltip show: glyphs in the platform's ⌃⌥⇧⌘ order, then the key,
    /// uppercased where it is a letter.
    public var display: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + Self.keyGlyph(key)
    }

    private static func keyGlyph(_ key: KeyEquivalent) -> String {
        // Keys whose `character` is a control code (⌫ is U+007F, ⇥ a tab), which a keycap would
        // draw as blank space.
        if key == .delete { return "⌫" }
        if key == .tab { return "⇥" }
        // The arrows are function-key code points (`NSLeftArrowFunctionKey` and friends), which a
        // keycap would draw as a blank box.
        if key == .leftArrow { return "←" }
        if key == .rightArrow { return "→" }
        if key == .upArrow { return "↑" }
        if key == .downArrow { return "↓" }
        // The hyphen-minus is the key that registers, but on a keycap "⌘-" reads as stray
        // punctuation. The minus sign is what the platform's Zoom Out and the ⌘/ reference draw.
        if key.character == "-" { return "−" }
        return String(key.character).uppercased()
    }

    // MARK: AppKit's spelling

    /// The chord as an `NSMenuItem` takes it, for a hand-built menu (the editor's Markup context
    /// menu), so it shows the menu bar's chord without a second copy of the key. The raw character,
    /// never `display`: AppKit wants the key and draws the glyphs itself.
    public var appKitKeyEquivalent: String { String(key.character) }

    public var appKitModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.command) { mask.insert(.command) }
        return mask
    }
}

public extension AppChord {
    // General
    static let settings = AppChord(",", .command)
    static let infoInspector = AppChord("i", .command)
    /// ⌘J, Ask Claude's panel. Free here and not one of macOS's reserved equivalents. A menu item,
    /// like ⌘K, because focus-scoped key handlers never fire with focus in a file table.
    static let askClaude = AppChord("j", .command)
    static let activityLog = AppChord("l", .command)
    static let shortcutsReference = AppChord("/", .command)
    /// ⌘K, the command palette. It must be a menu item: `.onKeyPress` is focus-scoped, so with
    /// focus in a file table (where it usually is) or nowhere, the handler never fires. The menu
    /// also shows the chord where people look. Free, not reserved by macOS, and no ⌥, per the
    /// invariant `AppChordTests` guards.
    static let commandPalette = AppChord("k", .command)

    // View ▸ Text Size: the whole app's type, stepped from the keyboard.
    //
    // These step `FontSize.selectablePercents`, the Settings slider's own stops
    // (`FontSize.stepped`), so the keyboard never reaches a size the slider can't. The Settings
    // rail's version line has a width budget measured against exactly that range (see RELEASE.md).
    //
    // ⌘+ is the platform's Bigger; AppKit matches "+" against ⇧=. The unshifted ⌘= would need a
    // hidden menu item, which SwiftUI's `.commands` can't make (its only alternate is an ⌥ one,
    // barred here). So ⌘+ alone.
    static let textBigger = AppChord("+", .command)
    static let textSmaller = AppChord("-", .command)
    /// ⌘0, back to the default size. Not a workspace digit: `workspace(_:)` is 1…9, the set
    /// `noChordCollidesWithAWorkspaceDigit` checks.
    static let textDefaultSize = AppChord("0", .command)

    // The Text and Markup menus: chords for a document's contents, all routed on
    // `EditorDocumentSurface` at key-press, never on `TextEditingChord`, which is true of every
    // field editor and would italicise the ⌘K field.

    /// Text ▸ Source / Preview / Split, ⌃⌘1/2/3. Control, because the ⌘ digits are the workspaces
    /// and ⌥ is barred; the other ⌃⌘ chords are letters.
    static let editorSourceMode = AppChord("1", [.control, .command])
    static let editorPreviewMode = AppChord("2", [.control, .command])
    static let editorSplitMode = AppChord("3", [.control, .command])
    /// Text ▸ Expand: the document alone in the window, with the file pane, rail and sidebar put
    /// away. ⌃⌘ beside the three modes, as the fourth way to choose how much window the document
    /// gets. AppKit's `StandardKeyBinding.dict` binds no ⌃⌘ letter (its ⌃⌘ entries are space and
    /// arrows), so the field editor never claims it and it stays out of `TextEditingChord`'s
    /// colliding set. Not ⌃⌘F, which is Enter Full Screen; this widens inside the window.
    static let editorExpand = AppChord("e", [.control, .command])

    /// Text ▸ Go to Line…, the status line's "Line, Col" as a menu item. ⌘L is the activity log and
    /// ⇧⌘L Markup's Link; AppKit binds no ⌃⌘ letter (see ``editorExpand``), so the field editor
    /// never claims it.
    static let goToLine = AppChord("l", [.control, .command])

    /// View ▸ Text Files: folds Edit's Text Files / Outline list into the pane's strip or back.
    /// ⌘T is New Tab and ⇧⌘T the tab bar; AppKit binds no ⌃⌘ letter (``editorExpand``). Pairs with
    /// the sidebar's ⌃⌘S as the two side columns' switches.
    static let editorTextFiles = AppChord("t", [.control, .command])

    /// Text ▸ Find Next / Find Previous / Use Selection for Find: the find bar's verbs, which
    /// AppKit binds to nothing until a menu item names them. ⌘G, ⇧⌘G and ⌘E, the platform's own.
    /// AppKit's `StandardKeyBinding.dict` binds no ⌘ letter, so the field editor never claims them.
    static let findNext = AppChord("g", .command)
    static let findPrevious = AppChord("g", [.shift, .command])
    static let useSelectionForFind = AppChord("e", .command)

    /// Markup ▸ the five inline verbs that take a chord. Headings and lists stay menu-only.
    static let bold = AppChord("b", .command)
    /// ⌘I, which is `infoInspector`'s chord, not a second declaration: Italic while the caret is in
    /// the editor's document, the Info inspector everywhere else, picked at key-press by
    /// `InspectorOrItalic` in the app target. A computed alias, because a second `static let` would
    /// fail `noTwoChordsCollide` and count twice in the registry.
    static var italic: AppChord { infoInspector }
    static let strikethrough = AppChord("x", [.shift, .command])
    static let inlineCode = AppChord("k", [.shift, .command])
    static let link = AppChord("l", [.shift, .command])

    /// ⌘1…⌘9 in the workspace bar's order; the caller passes the 1-based ordinal, so the badge and
    /// the registration count the same list.
    ///
    /// Nil past nine, rather than trapping: `Character.init(String)` needs one grapheme, and "10"
    /// would crash at menu-bar construction, so the app would not open. A tenth item gets no chord,
    /// as on the platform (⌘0 is not "the tenth").
    static func workspace(_ ordinal: Int) -> AppChord? {
        guard (1...9).contains(ordinal) else { return nil }
        return AppChord(KeyEquivalent(Character("\(ordinal)")), .command)
    }

    // The file clipboard, and the selection it acts on.
    //
    // All four are also text-editing keys, and a menu key equivalent outranks the field editor, so
    // each is routed through ``TextEditingChord`` at its call site, as ⌘⌫ is. Without that routing
    // ⌘C stops working in the pane search, the rename field and the differences search.
    //
    // ⌘X then ⌘V is move-here (the clipboard carries `isCut`), so there is no paste-as-move chord;
    // Finder's ⌥⌘V is barred anyway by the no-⌥ invariant `AppChordTests` guards.
    static let selectAll = AppChord("a", .command)
    static let cut = AppChord("x", .command)
    static let copy = AppChord("c", .command)
    static let paste = AppChord("v", .command)

    // Panes
    static let findInPane = AppChord("f", .command)
    static let paneBack = AppChord("[", .command)
    static let paneForward = AppChord("]", .command)
    static let rescan = AppChord("r", .command)
    static let newFolder = AppChord("n", [.shift, .command])
    static let hiddenFiles = AppChord(".", [.shift, .command])
    static let deleteSelection = AppChord(.delete, .command)
    /// ⌘↓ opens the selected folder into a new column; ⌘↑ closes the rightmost one.
    ///
    /// They move the column stack, never the comparison scope (see `PaneBrowsePath`): the scope
    /// reloads the tree and rescans, the column stack costs nothing and keeps every difference
    /// badge valid. That makes them safe on a keypress, and dead in Tree view, which has no
    /// columns.
    static let openSelectedFolder = AppChord(.downArrow, .command)
    /// ⌘↑. Not a second spelling of ⌘[: `paneBack` pops the column stack and then falls through to
    /// the pane's focus history, stepping the comparison scope back; this one stops at the root
    /// column and disables. Finder draws the same line between Back and Enclosing Folder. Don't
    /// fold this into `paneBack`.
    static let enclosingFolder = AppChord(.upArrow, .command)
    /// Moves the pane-scoped chords (⌘F, ⌘[, ⌘], ⇧⌘N) to the other comparison pane.
    ///
    /// ⌃⇥, **not** a bare ⇥: a menu key equivalent outranks the field editor (the hazard
    /// `DeleteSelectionCommand` documents for ⌘⌫), and plain Tab is how you leave every text field
    /// and how SwiftUI walks focus, so registering it would break both everywhere. ⌃⇥ is free
    /// because this single-`Window` scene has no window tabs for macOS to claim it.
    static let switchPaneFocus = AppChord(.tab, .control)

    // Tabs
    //
    // Finder's own mapping, with one deliberate deviation: ⌘1…⌘9 do not select tabs, because the
    // workspaces own every ⌘-digit.
    static let newTab = AppChord("t", .command)
    /// Closes the tab, or the window on the last one, as Finder does, so ⌘W always means "get rid
    /// of this".
    static let closeTab = AppChord("w", .command)
    /// ⇧⌘] / ⇧⌘[, so the unshifted pair stays pane back/forward.
    static let nextTab = AppChord("]", [.shift, .command])
    static let previousTab = AppChord("[", [.shift, .command])
    /// Previous Tab's second chord, ⌃⇧⇥, the reverse of ⌃⇥. It does what ⇧⌘[ does; its Go menu
    /// item is hidden behind Previous Tab with its key left live (`GoMenuDuplicates`). Free for
    /// ⌃⇥'s reason: no window tabs to claim it.
    static let previousTabControl = AppChord(.tab, [.control, .shift])
    /// View ▸ Tab Bar, ⇧⌘T as in Finder. Reopen Closed Tab therefore has no chord rather than an ⌥
    /// one, the one kind that can fire through the ⌥-hold reveal (see `foldAllDifferences`).
    static let tabBar = AppChord("t", [.shift, .command])

    /// View ▸ Sidebar: the Favorites / Sources / Recents column every workspace carries. ⌃⌘S is
    /// Finder's own Show/Hide Sidebar; ⌘S means Save on the platform and belongs to the editor's
    /// document (``saveDocument``).
    ///
    /// The registry drives the ⌘/ reference, so a chord declared here is published: declare one
    /// only while the thing it opens can appear.
    static let folderSidebar = AppChord("s", [.control, .command])

    // The Editor workspace: chords that act on a file's contents rather than on files.

    /// File ▸ Save: write the open document now.
    ///
    /// The editor autosaves once typing settles; ⌘S means "don't wait", and it is how a document
    /// whose autosave stopped (it changed underneath the buffer) gets settled. Live whenever a
    /// document is open, even a clean one: a greyed-out Save would answer "did my work make it?"
    /// wrongly. Not a field-editor binding, so it stays out of `TextEditingChord`'s colliding set.
    static let saveDocument = AppChord("s", .command)

    /// File ▸ Print…: the open document, rendered, on paper. Not one of `NSTextView`'s key
    /// bindings, so a menu equivalent takes it outright.
    ///
    /// File ▸ Export as PDF… has no chord: the print panel's own PDF button already reaches it, ⇧⌘P
    /// would read as a second Print, ⌥ chords are barred (see ``foldAllDifferences``), and ⌘E is
    /// Use Selection for Find.
    static let printDocument = AppChord("p", .command)

    /// File ▸ Open in Edit: hand the pane's selected text file to the Edit workspace. ⌘O is the key
    /// every Mac user tries, and not an `NSTextView` binding (as with ``saveDocument``).
    ///
    /// The one chord in File ▸'s row-verb group: a window-level menu item can carry a key a per-row
    /// context menu can't, and this act had no keyboard route otherwise.
    static let openInEditor = AppChord("o", .command)

    /// File ▸ New Text File…: opens the naming row in the editor's rail. The ellipsis is the
    /// promise: nothing is on disk until Return. ⌘N, beside ⇧⌘N's New Folder.
    static let newTextFile = AppChord("n", .command)

    // Differences
    /// ⌘← / ⌘→ copy the differences selection across; ⇧ makes it a move.
    ///
    /// Menu items, so they can be found. A window-level equivalent is consulted before the first
    /// responder and would hijack ⌘→ typed in the search field, so the items carry
    /// `chordBelongsToTextEditor`, which hands that keystroke back.
    ///
    /// Four `static let`s and a resolver, not a constructor: `everyDeclaredChordIsInTheRegistry`
    /// counts the declarations in this file, and each declared member gets its display pinned by
    /// `everyChordRendersItsDocumentedDisplay`. (`workspace(_:)` stays a constructor because its
    /// size follows the workspace list.)
    static let copyToLeft = AppChord(.leftArrow, .command)
    static let copyToRight = AppChord(.rightArrow, .command)
    static let moveToLeft = AppChord(.leftArrow, [.shift, .command])
    static let moveToRight = AppChord(.rightArrow, [.shift, .command])

    /// The member for a direction and a mode: one lookup, so the badge and the menu item can't
    /// pick different members.
    static func transfer(toRight: Bool, isMove: Bool) -> AppChord {
        switch (toRight, isMove) {
        case (false, false): return copyToLeft
        case (true, false): return copyToRight
        case (false, true): return moveToLeft
        case (true, true): return moveToRight
        }
    }

    static let reviewDifferences = AppChord("r", [.shift, .command])
    static let verifyDifferences = AppChord("v", [.shift, .command])
    static let differencesList = AppChord("d", .command)
    /// ⇧⌘F, **not** ⌥⌘F: an ⌥ chord can fire from inside the ⌥-hold reveal, so a user reading the
    /// "⌘F" badge who pressed ⌘F while still holding ⌥ would fold every folder. With no ⌥ chords,
    /// nothing fires through the reveal: look, release, press.
    static let foldAllDifferences = AppChord("f", [.shift, .command])
    /// ⇧⌘C, compare two files: the shifted partner of `copy`, in the menu with the other Compare
    /// verbs. The app has no text formatting, so it doesn't collide with the system's Show Colors.
    static let compareTwoFiles = AppChord("c", [.shift, .command])

    // The progress capsule
    /// ⌘., the Mac's cancel-operation chord, on the toolbar progress capsule's stop button, so a
    /// long copy, move, delete, sync or verify can be stopped from the keyboard.
    ///
    /// The one member that is not a menu item. Declared anyway: a menu that later claimed ⌘. would
    /// silently outrank the button, and only `noTwoChordsCollide` can catch that. It also belongs
    /// in the ⌘/ reference, which this registry drives.
    ///
    /// Not esc: the window stays live around the capsule, where esc clears a pane's selection out
    /// of habit, and that must not abort a long copy. ⇧⌘. is `hiddenFiles`, a different chord.
    static let cancelOperation = AppChord(".", .command)

    /// Every fixed chord declared as an `AppChord`, once, so the "for every chord" tests share one
    /// list instead of each re-typing it.
    ///
    /// Not every chord the app registers: ⌘? is written straight onto its menu item, so
    /// `ShortcutsReferenceTests` also reads the `.keyboardShortcut` literals in `MacApp/`.
    ///
    /// A plain array, since `static let`s on a struct can't be enumerated;
    /// `everyDeclaredChordIsInTheRegistry` counts the declarations in this file to catch a member
    /// left out. `workspace(_:)` is excluded: a family, which the reference lists as the range
    /// `⌘ 1 – ⌘ N`, pinned by its own test.
    static let registry: [AppChord] = [
        settings, infoInspector, askClaude, activityLog, shortcutsReference, commandPalette,
        selectAll, cut, copy, paste,
        findInPane, paneBack, paneForward, rescan, newFolder,
        saveDocument, newTextFile, printDocument, openInEditor,
        folderSidebar, hiddenFiles,
        deleteSelection, switchPaneFocus,
        openSelectedFolder, enclosingFolder,
        newTab, closeTab, nextTab, previousTab, previousTabControl, tabBar,
        reviewDifferences, verifyDifferences, differencesList, foldAllDifferences, compareTwoFiles,
        copyToLeft, copyToRight, moveToLeft, moveToRight,
        textBigger, textSmaller, textDefaultSize,
        editorSourceMode, editorPreviewMode, editorSplitMode, editorExpand,
        findNext, findPrevious, useSelectionForFind, goToLine, editorTextFiles,
        // `italic` is `infoInspector`, already listed above — see its note.
        bold, strikethrough, inlineCode, link,
        cancelOperation,
    ]

    /// Registry members that belong to a control rather than a menu item: the one exception to
    /// `WindowMenuTests.everyDeclaredChordIsOnAMenuItem`. ⌘. is the progress capsule's stop button,
    /// which exists only during a long run; `ProgressCapsuleCancelKeyTests` drives its key through
    /// a real window instead.
    static let controlOnly: [AppChord] = [cancelOperation]
}
