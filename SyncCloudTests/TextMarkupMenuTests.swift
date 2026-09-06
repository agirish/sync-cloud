@testable import SyncCloud
import AppKit
import Design
import FileExplorer
import Testing

/// **The Text and Markup menus, read off the running app** (roadmap RD1, v5.3) — and the two rules
/// under them that no menu can show: which way ⌘I goes, and which modes a file may be switched to.
///
/// The test host IS the app, so `NSApp.mainMenu` is what AppKit built from the `.commands`
/// declarations. That is the only place three facts about this batch can be read: whether the two
/// `CommandMenu`s landed as top-level menus in the intended order, whether the Info Inspector item
/// really precedes Markup ▸ Italic in the bar (the order ⌘I's routing depends on), and what each
/// item's key equivalent came out as.
@MainActor
@Suite struct TextMarkupMenuTests {

    static func menu(_ title: String) throws -> NSMenu {
        try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu,
                     "the app has no \(title) menu — this check would be vacuous")
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    static func item(_ title: String, in menu: String) throws -> NSMenuItem {
        try #require(try Self.menu(menu).items.first { $0.title == title }, "\(menu) has no \(title)")
    }

    // MARK: The two menus, where they landed

    /// Decision A: two menus, after Organize and before Window. `CommandMenu` order in the source
    /// is a declaration; this is what AppKit made of it.
    @Test func textAndMarkupFollowOrganizeInTheBar() throws {
        let bar = try #require(NSApp.mainMenu).items.map(\.title)
        let organize = try #require(bar.firstIndex(of: "Organize"))
        #expect(bar[organize...].prefix(4) == ["Organize", "Text", "Markup", "Window"],
                "the bar reads \(bar)")
    }

    /// The Text menu, in the roadmap's order: the modes, the find bar's pair, the two drawing
    /// switches, the autosave switch. **Neither Find… nor Save**, which stay in Edit and File — one
    /// action, one item, so no chord is registered twice.
    @Test func theTextMenuIsInTheRoadmapsOrder() throws {
        let text = Self.titles(try Self.menu("Text"))
        #expect(text == ["Source", "Preview", "Split",
                         "Find Next", "Use Selection for Find",
                         "Wrap Lines", "Check Spelling While Typing",
                         "Autosave This File"],
                "the Text menu reads \(text)")
        #expect(!text.contains("Find…"), "Find… is duplicated into Text — ⌘F is registered twice")
        #expect(!text.contains("Save"), "Save is duplicated into Text — ⌘S is registered twice")
    }

    /// The Markup menu is the context menu's list, in the context menu's order — derived from the
    /// same `menuOrder`, and asserted against it rather than against a copy.
    @Test func theMarkupMenuIsTheContextMenusListInItsOrder() throws {
        let markup = Self.titles(try Self.menu("Markup"))
        #expect(markup == MarkupVerb.menuOrder.compactMap { $0?.title },
                "the Markup menu reads \(markup)")
        // …and it is divided where the context menu is.
        #expect(try Self.menu("Markup").items.filter(\.isSeparatorItem).count
                == MarkupVerb.menuOrder.filter { $0 == nil }.count)
    }

    // MARK: The chords, as registered

    @Test func theViewModesCarryControlCommandDigits() throws {
        for (title, key) in [("Source", "1"), ("Preview", "2"), ("Split", "3")] {
            let item = try Self.item(title, in: "Text")
            #expect(item.keyEquivalent == key, "\(title) registers \(item.keyEquivalent)")
            #expect(item.keyEquivalentModifierMask == [.control, .command],
                    "\(title) registers the wrong modifiers")
        }
    }

    @Test func theFindBarsPairCarryTheirPlatformChords() throws {
        let next = try Self.item("Find Next", in: "Text")
        #expect(next.keyEquivalent == "g" && next.keyEquivalentModifierMask == .command)
        let use = try Self.item("Use Selection for Find", in: "Text")
        #expect(use.keyEquivalent == "e" && use.keyEquivalentModifierMask == .command)
    }

    /// The five inline verbs carry a chord and the menu-only verbs carry none — read off the built
    /// items, against `MarkupVerb.chord`, so the menu and the registry cannot drift.
    @Test func eachMarkupItemCarriesItsVerbsChordAndNoOther() throws {
        let markup = try Self.menu("Markup")
        var chorded = 0
        for verb in MarkupVerb.menuOrder.compactMap({ $0 }) {
            let item = try #require(markup.items.first { $0.title == verb.title }, "Markup has no \(verb.title)")
            if let chord = verb.chord {
                chorded += 1
                #expect(item.keyEquivalent == chord.appKitKeyEquivalent,
                        "\(verb.title) registers \(item.keyEquivalent), the verb says \(chord.display)")
                #expect(item.keyEquivalentModifierMask == chord.appKitModifierMask)
            } else {
                #expect(item.keyEquivalent.isEmpty, "\(verb.title) has acquired a chord")
            }
        }
        #expect(chorded == 5, "the walk found \(chorded) chorded verbs — it is not reading the menu")
    }

    /// **⌘I is registered twice, on purpose, and View's item comes first.** AppKit fires the first
    /// enabled item in menu-bar order for a shared key equivalent, so View's is the one that
    /// ordinarily answers the key — both handlers route through `InspectorOrItalic` regardless, so
    /// nothing rests on the order, but a swap would still be a change worth noticing by name.
    @Test func theInspectorItemPrecedesItalicInTheBar() throws {
        let bar = try #require(NSApp.mainMenu).items.map(\.title)
        let view = try #require(bar.firstIndex(of: "View"))
        let markup = try #require(bar.firstIndex(of: "Markup"))
        #expect(view < markup, "Markup precedes View — AppKit would fire Italic for ⌘I everywhere")

        let inspector = try Self.item("Info Inspector", in: "View")
        let italic = try Self.item("Italic", in: "Markup")
        #expect(inspector.keyEquivalent == "i" && inspector.keyEquivalentModifierMask == .command)
        #expect(italic.keyEquivalent == "i" && italic.keyEquivalentModifierMask == .command)
        // …and nothing else in the bar claims it.
        var claimants: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalent == "i", item.keyEquivalentModifierMask == .command {
                    claimants.append(item.title)
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(try #require(NSApp.mainMenu))
        #expect(claimants == ["Info Inspector", "Italic"], "⌘I is claimed by \(claimants)")
    }

    /// Every Text and Markup item greys with nothing published — the test host has no window, which
    /// is the state "Edit is not showing a document" reduces to. The positive control is the Edit
    /// menu beside them, whose four file verbs are pinned NEVER disabled in the same host.
    @Test func everyTextAndMarkupItemIsDisabledOutsideEdit() throws {
        for name in ["Text", "Markup"] {
            for item in try Self.menu(name).items where !item.isSeparatorItem {
                #expect(!item.isEnabled, "\(name) ▸ \(item.title) is live with no document open")
            }
        }
        #expect(try Self.item("Copy", in: "Edit").isEnabled,
                "Edit ▸ Copy is disabled too — the host's items are all grey, so the check above proves nothing")
    }

    // MARK: View ▸ Text Size (roadmap RD2)

    @Test func viewCarriesATextSizeSubmenuOnThePlatformsChords() throws {
        let host = try Self.item("Text Size", in: "View")
        let submenu = try #require(host.submenu, "View ▸ Text Size is not a submenu")
        #expect(Self.titles(submenu) == ["Bigger", "Smaller", "Default Size"])
        for (title, key) in [("Bigger", "+"), ("Smaller", "-"), ("Default Size", "0")] {
            let item = try #require(submenu.items.first { $0.title == title })
            #expect(item.keyEquivalent == key, "\(title) registers \(item.keyEquivalent)")
            #expect(item.keyEquivalentModifierMask == .command)
        }
    }

    /// **A menu item's action runs inside the dispatch of the event that fired it** — the premise
    /// `InspectorOrItalic.firedByKey` rests on, since it reads `NSApp.currentEvent` from inside the
    /// action. Proved on a real item rather than assumed: View ▸ Text Size ▸ Bigger's action is
    /// sent through AppKit's own `sendAction`, and the stored size has moved by the time the call
    /// returns. Were SwiftUI to defer its actions by a turn, this would read the old value — and
    /// `currentEvent` inside the action would be whatever came next.
    ///
    /// The live preference is written and put back exactly: the test host inherits the user's
    /// defaults, so a leaked step would resize the app under them.
    @Test func aMenuItemsActionRunsSynchronously() throws {
        let submenu = try #require(try Self.item("Text Size", in: "View").submenu)
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: FontSize.defaultsKey)
        defer { defaults.set(stored, forKey: FontSize.defaultsKey) }

        // **Read, never seeded.** The item's `@AppStorage` holds whatever it observed at its last
        // render, and a `defaults.set` made here is not observed until SwiftUI's next turn — the
        // first draft seeded 100, the item still saw the live 110, and the assertion read 115
        // against an expected 105 while the action had in fact run synchronously. So the expected
        // value is derived from the live one, and the direction is chosen so the item is not at
        // the end of its range, where it does nothing.
        let before = FontSize(percent: defaults.object(forKey: FontSize.defaultsKey) as? Int
                                  ?? FontSize.medium.percent)
        let title: String
        let expected: FontSize
        if let up = before.bigger {
            title = "Bigger"; expected = up
        } else {
            title = "Smaller"; expected = try #require(before.smaller, "a size with neither neighbour — the range is one stop wide")
        }
        let item = try #require(submenu.items.first { $0.title == title })

        // Straight through the item's target/action, which is what a key equivalent or a click
        // ends in; enabled-ness is not consulted on this path, which is why it can run in a host
        // whose menu has no key window behind it.
        let sent = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(sent, "AppKit found no responder for the item's action — the premise cannot be measured")
        #expect(defaults.integer(forKey: FontSize.defaultsKey) == expected.percent,
                "the action had not run when sendAction returned — it is deferred, and currentEvent inside it is unreliable")
    }

    // MARK: File ▸ Download (roadmap RD2)

    /// Present, chordless, and grey in a host with no selection — an enabled Download with nothing
    /// to fetch is the shape the availability rule exists to prevent.
    @Test func fileCarriesDownloadAndWithholdsItWithNoSelection() throws {
        let download = try Self.item("Download", in: "File")
        #expect(download.keyEquivalent.isEmpty)
        #expect(!download.isEnabled)
    }
}

/// ⌘I's two meanings, decided by where the caret is (decision B).
///
/// On a real window with a real first responder, because the rule is about AppKit's responder and
/// nothing else can stand in for it. Both directions, and the two shapes of "not in the document"
/// that matter: a field editor (the ⌘K field, the rename row), and no window at all.
@MainActor
@Suite struct InspectorOrItalicTests {

    private func hosted() -> (view: NSTextView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.string = "one two three"
        return (view, window)
    }

    @Test func theCaretInTheDocumentMeansItalic() {
        let (view, window) = hosted()
        window.makeFirstResponder(view)
        #expect(InspectorOrItalic.choose(in: window) == .italic)
    }

    /// The ⌘K field, the rename row, a pane's search — every field editor is an `NSTextView`, and
    /// every one of them means the inspector.
    @Test func theCaretInAFieldEditorMeansTheInspector() {
        let (_, window) = hosted()
        let field = NSTextField(string: "go to")
        field.frame = NSRect(x: 0, y: 360, width: 200, height: 22)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSTextView,
                "the field did not take the caret, so this case proves nothing")
        #expect(InspectorOrItalic.choose(in: window) == .inspector)
    }

    /// A cold window — no first responder — and no window at all both mean the inspector, which is
    /// what ⌘I has always done there.
    @Test func noCaretMeansTheInspector() {
        let (_, window) = hosted()
        #expect(InspectorOrItalic.choose(in: window) == .inspector)
        #expect(InspectorOrItalic.choose(in: nil) == .inspector)
    }

    /// **All four cells of the rule both items read.** Fired by the key, an item does what the
    /// caret says — whichever item AppKit chose for the shared chord. Clicked, it does what its
    /// title says, because a menu item under the pointer that did something else would be lying.
    @Test func theKeyFollowsTheCaretAndAClickFollowsTheTitle() {
        for caret in [InspectorOrItalic.Choice.italic, .inspector] {
            #expect(InspectorOrItalic.resolve(item: .inspector, firedByKey: true, caret: caret) == caret)
            #expect(InspectorOrItalic.resolve(item: .italic, firedByKey: true, caret: caret) == caret)
            #expect(InspectorOrItalic.resolve(item: .inspector, firedByKey: false, caret: caret) == .inspector)
            #expect(InspectorOrItalic.resolve(item: .italic, firedByKey: false, caret: caret) == .italic)
        }
    }

    /// A key equivalent arrives as a `keyDown`; a menu click ends in a mouse-up. Decided on the
    /// mouse side, so a menu committed with Return still counts as the keyboard, and so does the
    /// `nil` no user gesture produces.
    @Test func aKeyDownIsTheKeyAndAMouseUpIsAClick() {
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: 0, windowNumber: 0, context: nil, characters: "i",
                                   charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)
        #expect(InspectorOrItalic.firedByKey(key))
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                       clickCount: 1, pressure: 0)
        #expect(!InspectorOrItalic.firedByKey(click))
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                      clickCount: 1, pressure: 0)
        #expect(!InspectorOrItalic.firedByKey(down))
        #expect(InspectorOrItalic.firedByKey(nil))
    }
}

/// When the Text and Markup menus are offered at all, and what Preview withholds.
@Suite struct EditorVerbsAvailabilityTests {

    /// The ordinary case, and the positive control for the three refusals.
    @Test func editWithADocumentOffersTheMenus() {
        #expect(EditorVerbs.isOffered(workspace: .editor, hasDocument: true, isRefused: false))
    }

    /// **The document outlives a workspace switch**, so the workspace has to be asked: from Browse
    /// the same open document must not leave Markup ▸ Bold live, aimed at text not on screen.
    @Test(arguments: [Workspace.browse, .compare, .filing])
    func anotherWorkspaceWithholdsThemEvenWithADocumentOpen(workspace: Workspace) {
        #expect(!EditorVerbs.isOffered(workspace: workspace, hasDocument: true, isRefused: false),
                "\(workspace) offered the editor's menus")
    }

    @Test func noDocumentOrARefusedOneWithholdsThem() {
        #expect(!EditorVerbs.isOffered(workspace: .editor, hasDocument: false, isRefused: false))
        #expect(!EditorVerbs.isOffered(workspace: .editor, hasDocument: true, isRefused: true))
    }

    /// **Preview has no text view**, so the verbs that need one are withheld there rather than
    /// left as enabled items that log a refusal on every press.
    @Test func onlyPreviewLacksATextView() {
        #expect(EditorVerbs.hasTextView(in: .edit))
        #expect(EditorVerbs.hasTextView(in: .split))
        #expect(!EditorVerbs.hasTextView(in: .preview))
    }

    /// The call-site half: `shortcutEditorVerbs` resolves through the rule rather than spelling a
    /// workspace test of its own, and feeds the drawn mode to the text-view gate.
    @Test func theEditorVerbsAreResolvedThroughTheRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+Editor.swift")
        let source = sourceCodeOnly(try String(contentsOf: url, encoding: .utf8))
        let start = try #require(source.range(of: "var shortcutEditorVerbs: EditorVerbs? {"),
                                 "shortcutEditorVerbs is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("EditorVerbs.isOffered(workspace: selectedWorkspace"),
                "the editor's menus are gated by hand rather than through the rule")
        #expect(body.contains("EditorVerbs.hasTextView(in: drawn)"),
                "Preview no longer withholds the text-view verbs")
        #expect(!body.contains("selectedWorkspace == .editor"),
                "a second spelling of the workspace test sits beside the rule")
    }
}

/// Which modes Text ▸ Source / Preview / Split may set for a file.
@Suite struct EditorModeSwitchTests {

    @Test func aMarkdownFileAcceptsEveryMode() {
        for mode in EditorMode.allCases {
            #expect(EditorModeSwitch.accepts(mode, isMarkdown: true), "\(mode) refused on Markdown")
        }
    }

    /// **A `.txt` refuses Preview and Split rather than narrowing them to Source.** The item is
    /// disabled for it too; this is the rule under the item, so a click that got through would
    /// still do nothing rather than "succeed" by showing something else.
    @Test func aPlainTextFileRefusesThePreviewModes() {
        #expect(EditorModeSwitch.accepts(.edit, isMarkdown: false))
        #expect(!EditorModeSwitch.accepts(.preview, isMarkdown: false))
        #expect(!EditorModeSwitch.accepts(.split, isMarkdown: false))
    }
}
