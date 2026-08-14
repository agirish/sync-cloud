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

    /// ⌘1…⌘n by the workspace bar's own enumeration order — the caller passes the 1-based
    /// ordinal, so the badge and the registration count the same list.
    static func workspace(_ ordinal: Int) -> AppChord {
        AppChord(KeyEquivalent(Character("\(ordinal)")), .command)
    }

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
        findInPane, paneBack, paneForward, rescan, newFolder, hiddenFiles, previewColumn,
        deleteSelection, switchPaneFocus,
        newTab, closeTab, nextTab, previousTab, tabBar,
        reviewDifferences, verifyDifferences, differencesList, foldAllDifferences,
    ]
}
