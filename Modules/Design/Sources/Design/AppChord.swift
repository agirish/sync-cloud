import SwiftUI

/// One chord, one truth. Every menu-registered shortcut that also appears on a control — as an
/// ⌥-reveal keycap, in a tooltip, or both — is declared here once, and the two consumers read
/// the same value: the menu item registers `key` + `modifiers`, the keycap shows `display`.
///
/// `display` is DERIVED from the registration, not stored beside it, which is the point: before
/// this type the chord lived in four hand-copied places (the `.keyboardShortcut` call, the
/// `.shortcutKeycap` string, the tooltip, and the ⌘/ reference row), and changing the menu's
/// key left every badge advertising the old one with every test green. Now a badge cannot
/// disagree with the key equivalent that fires; `AppChordTests` pins each rendered display so
/// an accidental key change fails by name.
///
/// Keys that are semantics rather than chords — `esc` on a cancel button, `⏎` on a default
/// button, `␣` for Quick Look — stay literal at their call sites: they are not menu-registered
/// and their keycap names a ROLE, not a registration.
public struct AppChord: Sendable {
    public let key: KeyEquivalent
    public let modifiers: EventModifiers

    public init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// What the keycap (and tooltip) shows — glyphs in the platform's canonical ⌃⌥⇧⌘ order,
    /// then the key, uppercased where it is a letter.
    public var display: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + Self.keyGlyph(key)
    }

    private static func keyGlyph(_ key: KeyEquivalent) -> String {
        // The keys whose `character` is a control code rather than something drawable — ⌫ is
        // U+007F and ⇥ is a literal tab, which a keycap would render as blank space.
        if key == .delete { return "⌫" }
        if key == .tab { return "⇥" }
        // The arrows are function-key code points (`NSLeftArrowFunctionKey` and friends), so
        // `String(key.character)` is an unprintable glyph rather than a missing one — a keycap that
        // renders as a blank box instead of nothing, which is worse.
        if key == .leftArrow { return "←" }
        if key == .rightArrow { return "→" }
        return String(key.character).uppercased()
    }
}

public extension AppChord {
    // General
    static let settings = AppChord(",", .command)
    static let infoInspector = AppChord("i", .command)
    static let activityLog = AppChord("l", .command)
    static let shortcutsReference = AppChord("/", .command)
    /// ⌘K — the command palette (ROADMAP 14).
    ///
    /// **A menu item, and it has to be.** `.onKeyPress` is strictly focus-scoped: with focus in a
    /// file table — where it always is — a sibling's handler never fires, and with no focus at all
    /// nothing fires anywhere. A palette that only opened when you had not clicked anything would
    /// be worse than none. The menu item also documents the chord where someone looks for it.
    ///
    /// ⌘K was free: it is not one of macOS's reserved single-window equivalents, and nothing in
    /// this app had claimed it. No ⌥, per the invariant `AppChordTests` guards.
    static let commandPalette = AppChord("k", .command)

    /// ⌘1…⌘9 by the workspace bar's own enumeration order — the caller passes the 1-based
    /// ordinal, so the badge and the registration count the same list.
    ///
    /// **Nil past nine, rather than trapping.** `Character.init(String)` requires exactly one
    /// grapheme cluster, so a tenth workspace produced a two-character string and crashed — at
    /// MENU-BAR CONSTRUCTION, not at the tenth key press, which is to say the app would not open.
    /// There are four workspaces today and the tests exercise 1…9, so nothing approaches it; a
    /// latent trap on a number the UI is free to grow is worth one optional. A tenth item simply
    /// gets no chord, which is what the platform does too — ⌘0 is not "the tenth".
    static func workspace(_ ordinal: Int) -> AppChord? {
        guard (1...9).contains(ordinal) else { return nil }
        return AppChord(KeyEquivalent(Character("\(ordinal)")), .command)
    }

    // The file clipboard, and the selection it acts on.
    //
    // **Every one of these four is also a text-editing key**, and a menu key equivalent outranks the
    // field editor — so each is routed through ``TextEditingChord`` at its call site, exactly as
    // ⌘⌫ has been since `deleteSelection` was registered. Registering them without that routing
    // takes ⌘C away from the pane search, the rename field and the differences search.
    //
    // ⌘X + ⌘V is move-here, which is why there is no paste-as-move chord: the clipboard carries
    // `isCut`, so Finder's ⌥⌘V has nothing left to do — and could not be registered anyway, per the
    // no-⌥ invariant `AppChordTests` guards.
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
    static let previewColumn = AppChord("p", [.shift, .command])
    static let deleteSelection = AppChord(.delete, .command)
    /// Moves the pane-scoped chords (⌘F, ⌘[, ⌘], ⇧⌘N, ⇧⌘P) to the other comparison pane.
    ///
    /// ⌃⇥ and deliberately **not** a bare ⇥, which is the two-pane convention this borrows from.
    /// A menu key equivalent outranks the field editor — the hazard `DeleteSelectionCommand`
    /// documents for ⌘⌫ — and unlike ⌘⌫ there would be no way to route it back: plain Tab is how
    /// you leave every text field in the app and how SwiftUI walks focus, so registering it would
    /// take that away everywhere, permanently. ⌃⇥ is free here because this is a single-`Window`
    /// scene with no window tabs for macOS to claim it for.
    static let switchPaneFocus = AppChord(.tab, .control)

    // Tabs
    //
    // Finder's own mapping throughout, with one deliberate deviation recorded in the v4.x roadmap:
    // **⌘1…⌘9 do not select tabs**, because the workspaces own every ⌘-digit. Nothing here can be
    // reclaimed for them without taking a workspace's key away.
    static let newTab = AppChord("t", .command)
    /// Closes the tab — and, on the last one, the window, which is what Finder does and what makes
    /// ⌘W keep meaning "get rid of this" rather than acquiring an exception.
    static let closeTab = AppChord("w", .command)
    /// ⇧⌘] / ⇧⌘[, so the unshifted pair stays pane back/forward.
    static let nextTab = AppChord("]", [.shift, .command])
    static let previousTab = AppChord("[", [.shift, .command])
    /// View ▸ Tab Bar. ⇧⌘T is Finder's, and it is free here — Reopen Closed Tab therefore has no
    /// chord at all rather than an ⌥ one, which would be the single kind that can fire through the
    /// ⌥-hold reveal (see `foldAllDifferences`).
    static let tabBar = AppChord("t", [.shift, .command])

    // Differences
    /// ⌘← / ⌘→ copy the differences selection across; ⇧ makes it a move.
    ///
    /// **Menu items since v4.2, and the chord is the same one it always was.** These lived as an
    /// `.onKeyPress` inside the Differences table, scoped there because a window-level equivalent
    /// is consulted before the first responder and would hijack ⌘→ typed into the search field.
    /// The item now carries `chordBelongsToTextEditor`, which hands that keystroke back — the same
    /// routing every colliding chord here uses — so the chord can be registered where it can also
    /// be *read*. Before this it appeared in no menu and no ⌘/ row: four working verbs nobody
    /// could find.
    /// **Four `static let`s and a resolver, not a constructor.** Built inline at first, which
    /// broke the registry's own accounting: `everyDeclaredChordIsInTheRegistry` counts
    /// `static let … = AppChord(` declarations in this file and requires the registry to hold
    /// exactly that many, so four members that were registered without being *declared* left it
    /// reading 27 against 31. The family is small and fixed, so declaring each member is both
    /// possible and better than teaching the scan an exception — every member now gets its
    /// display pinned by `everyChordRendersItsDocumentedDisplay` on the day it is declared,
    /// which is the guarantee that exception would have quietly removed.
    ///
    /// (`workspace(_:)` stays a constructor because its membership is the workspace list's
    /// length, which is not fixed and is documented as a range rather than as members.)
    static let copyToLeft = AppChord(.leftArrow, .command)
    static let copyToRight = AppChord(.rightArrow, .command)
    static let moveToLeft = AppChord(.leftArrow, [.shift, .command])
    static let moveToRight = AppChord(.rightArrow, [.shift, .command])

    /// The member for a direction and a mode — one lookup, so the badge and the menu item cannot
    /// pick different members of the same family.
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
    /// ⇧⌘F, deliberately NOT ⌥⌘F: an ⌥-chord is the one kind that can fire from inside the
    /// ⌥-hold reveal, and the first cut shipped exactly that bug — a user reading the magnifier's
    /// "⌘F" badge who pressed ⌘F while still holding ⌥ sent ⌥⌘F and folded every folder instead
    /// of finding anything. With no ⌥-chords registered, nothing fires through the reveal at
    /// all — the documented look-release-press contract, restored.
    static let foldAllDifferences = AppChord("f", [.shift, .command])

    /// **Every fixed chord declared as an `AppChord`, once.**
    ///
    /// Not every chord the app registers: ⌘? is written straight onto its menu item and has no
    /// member here, which is exactly why `ShortcutsReferenceTests` reads the `.keyboardShortcut`
    /// literals out of `MacApp/` as well as sweeping this list. A registry-driven test cannot see
    /// a chord that is not in the registry.
    ///
    /// The type's whole argument is "one chord, one truth", and three "for every chord" tests were
    /// each re-typing the list to make it — two in `AppChordTests` (the no-⌥ invariant and the
    /// speakable-display one) and one in `ShortcutsReferenceTests`, which is how a registered ⌘?
    /// came to have no row in the ⌘/ reference with everything green. A hand-copied list of the
    /// members of a hand-copied-list-shaped bug is the wrong place to stop.
    ///
    /// A plain array rather than `CaseIterable`, because these are `static let`s on a struct and
    /// there is nothing to enumerate; adding a member without adding it here is the residual gap,
    /// and `everyDeclaredChordIsInTheRegistry` closes it by counting the declarations in the
    /// source. `workspace(_:)` is excluded on purpose — it is a family, not a chord, and the
    /// reference lists it as the range `⌘ 1 – ⌘ N`, which its own test pins.
    static let registry: [AppChord] = [
        settings, infoInspector, activityLog, shortcutsReference, commandPalette,
        selectAll, cut, copy, paste,
        findInPane, paneBack, paneForward, rescan, newFolder, hiddenFiles, previewColumn,
        deleteSelection, switchPaneFocus,
        newTab, closeTab, nextTab, previousTab, tabBar,
        reviewDifferences, verifyDifferences, differencesList, foldAllDifferences,
        copyToLeft, copyToRight, moveToLeft, moveToRight,
    ]
}
