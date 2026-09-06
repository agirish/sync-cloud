import AppKit
import Events
import FileExplorer
import SwiftUI
import Testing
import Foundation
@testable import SyncCloud

/// The menu-bar chords' window-side plumbing: the destination-pick suspension, and the ⌘/
/// window still showing the whole reference it exists to show.
///
/// **`.serialized`, and the reason is ⌘W's refusal line.** Four tests here call
/// `CloseTabCommand.run`, one of them with `.suspended`, which writes to the process-wide
/// `Logger.shared` — so `aSuspendedCloseSaysSoInTheLogAndTheOtherTwoStatesDoNot` measured its
/// "an ordinary ⌘W says nothing" window with a sibling free to write that very line into it.
/// Measured, not theorised: it failed exactly that way under a mutation run. No other suite in this
/// target calls `run`, so keeping these four off each other is enough, and the suite is under a
/// second.
@MainActor
@Suite(.serialized) struct ShortcutCommandsTests {

    /// A publisher with every value present, so the suspended case cannot pass vacuously.
    ///
    /// `closeTab` is injectable because ⌘W is the one chord whose suspended behaviour is a
    /// *silence* rather than a `nil`, so its tests have to watch what the published action DOES.
    private func loadedPublisher(suspended: Bool,
                                 closeTab: @escaping () -> Void = {}) -> ShortcutValuePublisher {
        ShortcutValuePublisher(
            workspace: .constant(.compare),
            goBack: {}, goForward: {}, rescan: {}, newFolder: {},
            saveDocument: {}, newTextFile: {},
            hiddenFiles: .constant(false),
            previewColumn: .constant(true),
            inspector: .constant(false),
            differencesList: .constant(true),
            delete: {},
            switchPaneFocus: PaneFocusSwitch(targetName: "Dropbox", run: {}),
            commandPalette: {},
            beginPaneSearch: {},
            selectAll: {},
            clipboard: ClipboardActions(cut: {}, copy: {}, paste: {}),
            newTab: {}, closeTab: closeTab, cycleTab: { _ in }, reopenClosedTab: {},
            tabBar: TabBarSwitch(isOn: false, isForced: false, set: { _ in }),
            folderSidebar: .constant(true),
            organizeLens: OrganizeLensSwitch(current: .duplicates, select: { _ in }),
            organizeVerbs: OrganizeVerbs(organizeFolder: {}, findDuplicates: {},
                                         fixName: {}, keepName: {}, undoReorganisation: {},
                                         planShape: {}, setUpLikeSiblings: {}),
            paneRowVerbs: PaneRowVerbs(openInNewTab: {}, quickLook: {}, download: {}, revealInFinder: {},
                                       rename: {}, chooseDestination: { _ in },
                                       ignore: PaneRowVerbs.IgnoreToggle(title: "Ignore in Comparison",
                                                                         run: {})),
            compareTwoFiles: {},
            editorVerbs: EditorVerbs(mode: .edit, canPreview: true, setMode: { _ in },
                                     autosave: EditorVerbs.AutosaveSwitch(isOn: true, toggle: {}),
                                     canMarkUp: true, canFind: true),
            suspended: suspended
        )
    }

    /// **Every `effective…` value is actually published.**
    ///
    /// The suspension tests below hold the *rule* and cannot see whether anything reads it: deleting
    /// a `.focusedSceneValue` line leaves them all green and the menu item permanently disabled,
    /// which is how a chord dies silently. Measured — removing ⌘K's publication passed the whole
    /// app suite before this existed.
    ///
    /// Derived from the source rather than listed here, so a thirteenth value is covered the moment
    /// it is added rather than when someone remembers to extend a list.
    @Test func everyEffectiveValueIsHandedToAFocusedSceneValue() throws {
        let source = try Self.publisherSource()
        let names = Self.effectiveValueNames(in: source)
        #expect(names.count >= 12,
                "found only \(names.count) effective values — this scan would be near-vacuous")
        let body = Self.codeOnly(source)
        for name in names {
            #expect(body.contains(".focusedSceneValue(") && body.contains(", \(name))"),
                    "\(name) is computed and never published — its menu item is permanently disabled")
        }
    }

    /// **What FEEDS `suspended:` is not covered by the test above, and it is the whole mechanism.**
    ///
    /// `everyEffectiveValueIsHandedToAFocusedSceneValue` proves each `effective…` is published, and
    /// `loadedPublisher(suspended:)` injects the flag, so nothing asserts the expression at the call
    /// site. Deleting `pendingDestination != nil` from it — the entire subject of `a1c96082` — passes
    /// every test in the repo, and so does deleting `showCommandPalette`. Same shape as the defect
    /// that commit describes ("a value published outside it is a value nobody thinks to suspend"),
    /// one layer down.
    ///
    /// Both terms by name rather than the whole expression, so reordering them or adding a third
    /// reason to suspend is not a failure.
    @Test func bothReasonsToSuspendTheChordsSurviveInTheExpression() throws {
        let source = Self.codeOnly(try Self.publisherSource())
        // EVERY `suspended:` line, not the first one. `range(of:)` found the *parameter declaration*
        // (`suspended: Bool`) and asserted against the word "Bool" — the same first-match hazard
        // these scans keep being fixed for, reintroduced by the fix. Which line carries the
        // expression is not the point; that some line does is.
        //
        // **Trailing comments cut first, and the line must START with `suspended:`.** `codeOnly`
        // strips only whole-line comments, so `suspended: false  // was: pendingDestination != nil
        // || showCommandPalette` satisfied both checks below while every mirrored chord stayed live
        // during a destination pick — measured, and the decoy fits on the real line, no second call
        // site needed.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.prefix { $0 != "/" }.trimmingCharacters(in: .whitespaces) }
        let mentions = lines.filter { $0.hasPrefix("suspended:") }
        #expect(!mentions.isEmpty, "the chord publisher no longer takes a suspension at all")
        // If the argument is a bare identifier, follow it. "Extract the condition into a named
        // property" is the most likely next edit to this line, and it is behaviour-preserving —
        // failing it would train the next person to delete this test rather than trust it.
        let resolved = mentions.flatMap { mention -> [String] in
            let argument = mention.dropFirst("suspended:".count).trimmingCharacters(in: .whitespaces)
            guard !argument.isEmpty,
                  argument.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  let declaration = lines.first(where: { $0.contains("var \(argument)") && $0.contains("{") })
            else { return [mention] }
            let index = lines.firstIndex(of: declaration) ?? 0
            return [mention] + lines[index...].prefix(6)
        }
        let expression = resolved.joined(separator: " ")
        #expect(expression.contains("pendingDestination != nil"),
                "no `suspended:` argument mentions the destination picker — ⌘R would rescan underneath it and ⇧⌘. flip filters behind the field being typed into. Found: \(mentions)")
        #expect(expression.contains("showCommandPalette"),
                "no `suspended:` argument mentions the command palette — every mirrored chord would fire behind it. Found: \(mentions)")
    }

    /// The publisher's own source, named so a rename fails loudly rather than emptying the scan.
    static func publisherSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/ShortcutCommands.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read ShortcutCommands.swift — the scan would be vacuous")
        // `#require`, not `#expect` — the same argument the two scans further down already make in
        // their own bodies: a truncated file makes every `contains` answer false and every
        // `!contains` answer true, so one quiet issue would stand in front of a page of green.
        try #require(text.count > 500, "ShortcutCommands.swift is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// Whole-line `//` comments removed — a scan for what the code does must not read the prose
    /// that describes it. The same helper, and the same reason, as `OrganizeScopeCallSiteTests`.
    /// The shared stripper — see ``sourceCodeOnly(_:)``. Four suites in this target carried a
    /// byte-identical copy of it; consolidating `body(of:in:)` and leaving the thing it depends on
    /// duplicated would have been half a fix.
    static func codeOnly(_ source: String) -> String { sourceCodeOnly(source) }

    /// While the destination picker is up its overlay blocks the mouse from every control these
    /// chords mirror; the keyboard must not tunnel under it. One flag silences all twelve.
    @Test func suspensionSilencesEveryPublishedValue() {
        let publisher = loadedPublisher(suspended: true)
        #expect(publisher.effectiveWorkspace == nil)
        #expect(publisher.effectiveGoBack == nil)
        #expect(publisher.effectiveGoForward == nil)
        #expect(publisher.effectiveRescan == nil)
        #expect(publisher.effectiveNewFolder == nil)
        // The editor's two. ⌘S under a destination pick would write the buffer to a path the
        // pick is still deciding about; ⌘N would switch workspace out from under it.
        #expect(publisher.effectiveSaveDocument == nil)
        #expect(publisher.effectiveNewTextFile == nil)
        #expect(publisher.effectiveHiddenFiles == nil)
        #expect(publisher.effectivePreviewColumn == nil)
        #expect(publisher.effectiveInspector == nil)
        #expect(publisher.effectiveDifferencesList == nil)
        #expect(publisher.effectiveDelete == nil)
        #expect(publisher.effectiveSwitchPaneFocus == nil)
        // ⌘K was the one chord published outside this type, and so the one this suspension did not
        // reach: the palette opened over an in-flight destination pick and could route out of it.
        #expect(publisher.effectiveCommandPalette == nil)
        // ⌘F, and the five tabs added — every one of them published, wired to a chord, and asserted
        // NOWHERE until now. Dropping `suspended ?` from `effectiveNewTab` let ⌘T open a tab under
        // the destination picker; from `effectiveCloseTab`, ⌘W fell through to `performClose` and
        // closed the window out from under the pick. `everySuspendableValueIsCoveredHere` is what
        // stops the next value being added without landing in these two lists.
        #expect(publisher.effectiveBeginPaneSearch == nil)
        // The clipboard verbs go silent together, not one at a time: a paste answered under the
        // picker would write files into the pane the pick is describing.
        #expect(publisher.effectiveSelectAll == nil)
        #expect(publisher.effectiveClipboard == nil)
        #expect(publisher.effectiveNewTab == nil)
        #expect(publisher.effectiveCloseTab == nil)
        #expect(publisher.effectiveCycleTab == nil)
        #expect(publisher.effectiveReopenClosedTab == nil)
        #expect(publisher.effectiveTabBar == nil)
        #expect(publisher.effectiveFolderSidebar == nil)
        #expect(publisher.effectiveOrganizeLens == nil)
        #expect(publisher.effectiveOrganizeVerbs == nil)
        #expect(publisher.effectivePaneRowVerbs == nil)
        #expect(publisher.effectiveCompareTwoFiles == nil)
        // The Text and Markup menus: a mode switch or an autosave toggle under a destination pick
        // changes the document the pick may be about.
        #expect(publisher.effectiveEditorVerbs == nil)
    }

    /// ...and the guard the test above depends on: unsuspended, the same loaded publisher passes
    /// every value through — proving the nils really came from `suspended`, not from a fixture
    /// that never carried values to silence.
    @Test func anUnsuspendedPublisherPassesEveryValueThrough() {
        let publisher = loadedPublisher(suspended: false)
        #expect(publisher.effectiveWorkspace != nil)
        #expect(publisher.effectiveGoBack != nil)
        #expect(publisher.effectiveGoForward != nil)
        #expect(publisher.effectiveRescan != nil)
        #expect(publisher.effectiveNewFolder != nil)
        #expect(publisher.effectiveSaveDocument != nil)
        #expect(publisher.effectiveNewTextFile != nil)
        #expect(publisher.effectiveHiddenFiles != nil)
        #expect(publisher.effectivePreviewColumn != nil)
        #expect(publisher.effectiveInspector != nil)
        #expect(publisher.effectiveDifferencesList != nil)
        #expect(publisher.effectiveDelete != nil)
        #expect(publisher.effectiveSwitchPaneFocus != nil)
        #expect(publisher.effectiveCommandPalette != nil)
        #expect(publisher.effectiveBeginPaneSearch != nil)
        #expect(publisher.effectiveSelectAll != nil)
        #expect(publisher.effectiveClipboard != nil)
        #expect(publisher.effectiveNewTab != nil)
        #expect(publisher.effectiveCloseTab != nil)
        #expect(publisher.effectiveCycleTab != nil)
        #expect(publisher.effectiveReopenClosedTab != nil)
        #expect(publisher.effectiveTabBar != nil)
        #expect(publisher.effectiveFolderSidebar != nil)
        #expect(publisher.effectiveOrganizeLens != nil)
        #expect(publisher.effectiveOrganizeVerbs != nil)
        #expect(publisher.effectivePaneRowVerbs != nil)
        #expect(publisher.effectiveCompareTwoFiles != nil)
        #expect(publisher.effectiveEditorVerbs != nil)
    }

    /// **Every `effective…` the publisher exposes is named in BOTH lists above.**
    ///
    /// The two suspension tests are hand-listed, and the list went stale the moment a feature added
    /// values: ⌘F and the five tab values were published, wired to chords, and silenced by nothing
    /// any test could see. `everyEffectiveValueIsHandedToAFocusedSceneValue` could not catch it —
    /// it proves each value is *published*, which the unsuspended ones are.
    ///
    /// Derived from both sources rather than from a third hand-kept list, so the fifteenth value is
    /// covered when it is written rather than when someone remembers this file.
    @Test func everySuspendableValueIsCoveredHere() throws {
        let names = Self.effectiveValueNames(in: try Self.publisherSource())
        #expect(names.count >= 14,
                "found only \(names.count) effective values — this scan would be near-vacuous")
        // A known member must be IN the derived set, or a parser that silently matched nothing
        // would make the loop below vacuous no matter how many values went uncovered.
        #expect(names.contains("effectiveNewTab"),
                "the name scan no longer finds a value that is definitely declared")

        // **Bound to the two lists, and to `#expect(` — not to the file.** A whole-file substring
        // search accepted a value whose two forms both sat in the UNSUSPENDED test
        // (`#expect(publisher.effectiveFoo != nil)` beside `#expect(!(publisher.effectiveFoo == nil))`),
        // which says nothing about suspension; and `sourceCodeOnly` strips only whole comment lines,
        // so a TRAILING comment naming a value satisfied it too — the decoy this suite's own
        // `bothReasonsToSuspendTheChordsSurviveInTheExpression` was written to defeat.
        let own = try Self.ownSource()
        let silenced = Self.codeOnly(try Self.memberBody("func suspensionSilencesEveryPublishedValue", in: own))
        let live = Self.codeOnly(try Self.memberBody("func anUnsuspendedPublisherPassesEveryValueThrough", in: own))
        for name in names {
            #expect(silenced.contains("#expect(publisher.\(name) == nil)"),
                    "\(name) is never asserted to fall silent while the chords are suspended")
            #expect(live.contains("#expect(publisher.\(name) != nil)"),
                    "\(name) has no unsuspended control — its `== nil` could be vacuously true")
        }
    }


    /// One member's body: its declaration to the first closing brace at member indentation. The
    /// same slicer `PaneTabWiringTests` uses, and for the same reason — a fixed window goes stale
    /// as the file grows and starts answering with a neighbour's text.
    static func memberBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"),
                               "\(declaration) never closes at member indentation")
        return String(rest[..<end.lowerBound])
    }

    /// This file's own text, for the coverage scan above.
    static func ownSource() throws -> String {
        let text = try #require(try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8),
                                "cannot read this test file — the coverage scan would be vacuous")
        try #require(text.count > 500, "this file is implausibly short — the scan would be near-vacuous")
        return text
    }

    /// The `effective…` property names declared in `ShortcutValuePublisher`.
    static func effectiveValueNames(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "var effective") else { return nil }
            let name = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
            return name.isEmpty ? nil : "effective\(name)"
        }
    }

    /// The Go menu item names the pane it moves focus TO — and it is the only surface that says
    /// which pane is focused at all, because the panes carry no indicator. A title reading
    /// "Switch Pane" would leave the state unreadable.
    @Test func theFocusSwitchItemNamesItsDestinationPane() {
        #expect(PaneFocusSwitch.menuTitle(for: PaneFocusSwitch(targetName: "Dropbox", run: {}))
                == "Focus Dropbox")
        // Same-provider panes are disambiguated upstream by `PaneProviderNames`, so the title
        // still names ONE pane rather than repeating a word twice.
        #expect(PaneFocusSwitch.menuTitle(for: PaneFocusSwitch(targetName: "iCloud (right)", run: {}))
                == "Focus iCloud (right)")
    }

    /// The disabled form — a single-source workspace, where there is no second pane to name.
    @Test func theFocusSwitchItemNamesNoPaneWhenThereIsNoOtherOne() {
        #expect(PaneFocusSwitch.menuTitle(for: nil) == "Focus Other Pane")
    }

    /// The ⌘/ window is `.contentSize`-resizable — the user cannot enlarge it — so the whole
    /// reference must fit its fixed frame at the default text size. It stopped fitting when the
    /// twelve menu-bar chords nearly doubled the row count, and nothing failed: the ScrollView
    /// swallowed the overflow. Measured on the laid-out content, at the window's width, against
    /// the window's height; the floor guards against a render that measured nothing.
    /// **⌘F is published through the publisher, and nowhere else.**
    ///
    /// It was hung straight off `ContentView.body` — never nil, never suspended — the exact shape
    /// `a1c96082` moved ⌘K out of, and for the same consequence: with the destination picker up,
    /// ⌘F opened the focused pane's search field under the scrim and `ExpandingSearchField` took
    /// focus on appear, so the typing and the ↩ and the esc meant for the pick went to a field the
    /// mouse cannot reach. Both halves are asserted, because "the new publication exists" stays
    /// true if the old one is left beside it.
    @Test func findInPaneIsPublishedOnlyThroughTheSuspendablePublisher() throws {
        let publisher = Self.codeOnly(try Self.publisherSource())
        #expect(publisher.contains(".focusedSceneValue(\\.beginPaneSearch, effectiveBeginPaneSearch)"),
                "⌘F is not published through the publisher, so nothing suspends it")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let content = try #require(try? String(contentsOf: url, encoding: .utf8),
                                   "cannot read ContentView.swift — this scan would be vacuous")
        try #require(content.count > 500, "ContentView.swift is implausibly short")
        #expect(!Self.codeOnly(content).contains(".focusedSceneValue(\\.beginPaneSearch"),
                "ContentView still publishes ⌘F on its own, outside the suspension")
    }

    /// And the suspension actually reaches it — the property, not just the publication.
    @Test func findInPaneIsSilencedWhileThePickerIsUp() {
        #expect(loadedPublisher(suspended: true).effectiveBeginPaneSearch == nil,
                "⌘F tunnels under the destination picker")
        #expect(loadedPublisher(suspended: false).effectiveBeginPaneSearch != nil,
                "⌘F is dead even with nothing suspending it")
    }

    // MARK: ⌘W, whose published value has THREE states

    /// A live tab — the ordinary case, and the control that stops the two below passing because
    /// nothing was wired up at all.
    @Test func closeTabClosesTheTabWhenAPaneOffersOne() {
        var closedTab = false
        var closedWindow = false
        let action = loadedPublisher(suspended: false, closeTab: { closedTab = true }).closeTabAction
        CloseTabCommand.run(action) { closedWindow = true }
        #expect(closedTab, "⌘W no longer closes the tab a pane published")
        #expect(!closedWindow, "⌘W closed the window as well as the tab")
    }

    /// **Suspended, ⌘W does nothing at all — and above all does not close the window.**
    ///
    /// The destination picker and the ⌘K palette silence every mirrored chord, and ⌘W's silence
    /// used to arrive at the item as the very same `nil` an auxiliary window publishes — which the
    /// item reads as "this window has no tabs" and answers with `performClose`. So the one chord
    /// that was not really suspended took the whole window out from under the pick, mid-answer, on
    /// a keystroke the overlay's own scrim exists to refuse.
    ///
    /// Both halves asserted: a suspension that closed the *tab* instead would be the tunnelling
    /// every other value here is nil'd to prevent.
    @Test func closeTabDoesNothingWhileTheChordsAreSuspended() {
        var closedTab = false
        var closedWindow = false
        let action = loadedPublisher(suspended: true, closeTab: { closedTab = true }).closeTabAction
        // The distinction the fix rests on: suspended is published, not withheld. Were this `nil`
        // the run below would take the `closeWindow` branch and the expectation after it would be
        // reporting the old bug rather than the new rule.
        #expect(action != nil,
                "suspension flattened ⌘W back into `nil`, which the item reads as ‘no tabs here’")
        CloseTabCommand.run(action) { closedWindow = true }
        #expect(!closedTab, "⌘W closed a tab under an overlay that owns the keyboard")
        #expect(!closedWindow,
                "⌘W closed the main window out from under an in-flight destination pick")
    }

    /// …and the case that must NOT become a no-op with it: the three auxiliary `Window` scenes
    /// (Keyboard Shortcuts, Activity Log, Sync History) publish no focused value at all, and this
    /// item replaced the standard Close group, so ⌘W is the only thing that closes them.
    @Test func closeTabStillClosesAWindowThatPublishesNoTabAtAll() {
        var closedWindow = false
        CloseTabCommand.run(nil) { closedWindow = true }
        #expect(closedWindow, "⌘W is dead on a window that publishes no tab — it is also its Close")
    }

    /// The wiring the three tests above cannot see: that `\.closeTab` is published from the
    /// three-state value rather than from `effectiveCloseTab` directly. Republishing the plain
    /// optional would restore the flattening — `.suspended` would never reach the item — and every
    /// assertion above would still pass, because they call the rule rather than the scene.
    ///
    /// **`everyEffectiveValueIsHandedToAFocusedSceneValue` does not cover it either**, and this is
    /// the one value it cannot: `effectiveCloseTab` now reaches the scene *through* `closeTabAction`
    /// rather than by name, so that scan is satisfied by the resolver's own line — measured by
    /// deleting the publication, which left it green and ⌘W unpublished.
    @Test func theCloseTabValueIsPublishedThroughItsThreeStateForm() throws {
        let code = Self.codeOnly(try Self.publisherSource())
        #expect(code.contains(".focusedSceneValue(\\.closeTab, closeTabAction)"),
                "⌘W is not published through `closeTabAction`, so the suspended state cannot reach the item")
        #expect(code.contains("CloseTabAction.resolve(suspended: suspended, effectiveCloseTab)"),
                "`closeTabAction` no longer resolves the suspension — ⌘W would fall through to the window again")
    }

    /// **The suspended refusal is the one state that greys the item out — and only that state.**
    ///
    /// `isSuspended` is what the menu item reads, and it cannot be spelled `close == .suspended`:
    /// ``CloseTabAction`` holds a closure and so has no `==`. Asserted on all three values, because
    /// the property that matters is as much what it answers `false` to: a `nil` value is one of the
    /// three auxiliary windows, where this item stands in for File ▸ Close, and disabling there is
    /// the dead-⌘W regression the three-state value exists to undo.
    @Test func onlyTheSuspendedCloseActionReadsAsSuspended() {
        #expect(CloseTabAction.suspended.isSuspended)
        #expect(!CloseTabAction.closeTab({}).isSuspended)
        // The optional form the item actually holds — `nil` must not read as a refusal.
        let none: CloseTabAction? = nil
        #expect(none?.isSuspended != true, "a window that publishes no tab reads as suspended")
    }

    /// **…and the item really is disabled by it, on the state rather than on `nil`.**
    ///
    /// The rule above is a value the menu item is free never to read — the exact "a rule extracted
    /// for testability is one revert from being unused" shape — so the modifier is pinned too. Both
    /// directions: the item must disable on `.suspended`, and it must NOT disable on `nil`, which
    /// would take ⌘W out of the three auxiliary windows whose Close it replaced.
    ///
    /// Source-level because a `Commands` body cannot be mounted in a unit test: `CloseTabCommand`
    /// reads a `@FocusedValue`, which needs a scene, a key window and a focus update.
    @Test func theCloseItemIsDisabledWhileSuspendedAndOnlyThen() throws {
        let body = Self.codeOnly(try Self.typeBody("struct CloseTabCommand: View {",
                                                   in: try Self.publisherSource()))
        #expect(body.contains(".disabled(close?.isSuspended == true)"),
                "⌘W stays black in a File menu whose every other item has greyed — a control that silently does nothing")
        for deadening in [".disabled(close == nil)", ".disabled(close != nil)"] {
            #expect(!body.contains(deadening),
                    "\(deadening) makes ⌘W dead on the auxiliary windows whose File ▸ Close this item replaced")
        }
        #expect(body.contains("Self.run(close)"), "the item does not go through the tested rule")
    }

    /// **A refused ⌘W leaves a line, because a disabled item is one deleted modifier away.**
    ///
    /// The disable above is the surface a person reads; this is the one a report is answered from.
    /// ⌘K's refusal logs for exactly this reason ("⌘K did nothing and the log is silent"), and at
    /// `.info` rather than `.debug` for the same one — `.debug` is dropped entirely at Settings ▸
    /// Advanced ▸ Info, which is where such reports come from.
    ///
    /// The two states that are NOT refusals are asserted silent in the same test, or the line would
    /// arrive under every ordinary ⌘W and mean nothing.
    ///
    /// **Both halves are read between two of this test's own markers**, never over the whole buffer.
    /// `Logger.shared` is process-wide and `entries` is a rolled 1000-line window: a bare
    /// `contains` would let the sibling suspended test's line satisfy the presence half, and let a
    /// rolled window pass the absence half for free. The opening marker is `#require`d, which is the
    /// eviction guard; the suite's `.serialized` trait is what makes the window exclusive.
    @Test func aSuspendedCloseSaysSoInTheLogAndTheOtherTwoStatesDoNot() async throws {
        let refusal = "⌘W ignored"
        /// Everything logged between two fresh markers, with the call under test run between them.
        func window(_ act: () -> Void) async throws -> ArraySlice<String> {
            let token = UUID().uuidString.prefix(8)
            await Logger.shared.debug("close-tab window open \(token)").value
            act()
            await Logger.shared.debug("close-tab window close \(token)").value
            let messages = Logger.shared.entries.map(\.message)
            let opened = try #require(messages.firstIndex(where: { $0.contains("open \(token)") }),
                                      "the log window rolled past this test's own marker, so this reading is vacuous")
            // Sliced from the opening marker FIRST and searched inside that slice, so the two
            // indices cannot be found out of order — `messages[a...b]` traps rather than failing
            // when they are, which turns a rolled buffer into a crashed test run.
            let tail = messages[opened...]
            let closed = try #require(tail.lastIndex(where: { $0.contains("close \(token)") }),
                                      "the closing marker never landed — this reading is vacuous")
            return tail[...closed]
        }

        // The two live states. Nothing they do is a refusal, so nothing may say one happened.
        let quiet = try await window {
            CloseTabCommand.run(.closeTab({})) {}
            CloseTabCommand.run(nil) {}
        }
        #expect(!quiet.contains(where: { $0.contains(refusal) }),
                "an ordinary ⌘W logs a refusal it did not make")

        let refused = try await window { CloseTabCommand.run(.suspended) {} }
        #expect(refused.contains(where: { $0.contains(refusal) }),
                "⌘W refused under an overlay with nothing in the log — the report has no other trace")
        #expect(refused.last(where: { $0.contains(refusal) })?.contains("overlay owns the keyboard") == true,
                "the line has to say WHY ⌘W did nothing, or it is a refusal with no cause")
    }

    /// One type's body: its declaration to the first closing brace at file scope. ``memberBody``
    /// stops at the first `\n    }` and so would hand back the first METHOD of a type — which is
    /// how a scan meant for `CloseTabCommand.body` would silently be reading `run`.
    static func typeBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"),
                               "\(declaration) never closes at file scope")
        let body = String(rest[..<end.lowerBound])
        try #require(body.contains("keyboardShortcut"),
                     "the slice of \(declaration) holds no menu item — it stopped short")
        return body
    }

    /// **The ambient panels cannot latch behind a destination pick.**
    ///
    /// `showSettings` and `showHelp` are plain `Bool` latches and the overlay chain renders the
    /// picker in front of both, so setting either mid-pick did nothing visible and then produced
    /// the panel the instant the pick resolved. ⌘, and ⌘? are registered in the App scene and see
    /// none of this window's state, so the refusal has to live at the latch — which is also why
    /// the toolbar button can be disabled without creating a keyboard/mouse split.
    ///
    /// Source-level because `ContentView`'s overlays need a live manager and a render pass; what
    /// is pinned is that each latch has a guard and that the guard reads the picker.
    @Test func theAmbientPanelsRefuseToOpenDuringADestinationPick() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let content = try #require(try? String(contentsOf: url, encoding: .utf8),
                                   "cannot read ContentView.swift — this scan would be vacuous")
        try #require(content.count > 500, "ContentView.swift is implausibly short")
        let code = Self.codeOnly(content)

        // The setup form is the third member of the chain, and it replaced the welcome tour this
        // check used to name. The tour's half was inverted — its "open" was a *cleared* dismissal,
        // so the refusal had to write the persisted seen-flag — and the form's is not: an explicit
        // `showSetup` latch refuses exactly like the other two, which is the simplification that
        // came with dropping a screen whose only way back was to un-persist a flag.
        for latch in ["showSettings", "showHelp", "showSetup"] {
            let start = try #require(code.range(of: ".onChange(of: \(latch)) { _, isOpen in"),
                                     "\(latch) has no open-guard at all")
            let rest = code[start.upperBound...]
            let end = try #require(rest.range(of: "\n        }"))
            let body = String(rest[..<end.lowerBound])
            #expect(body.contains("pendingDestination != nil"),
                    "\(latch) can still latch behind the destination picker")
            #expect(body.contains("\(latch) = false"),
                    "\(latch)'s guard notices the pick but does not refuse the open")
        }

        // **A refused Settings open has to leave nothing behind either.**
        //
        // The deep links (the invalid-pane fix-it's Providers jump, the cloud-refine offer) preset
        // `settingsTab` and only then flip the latch — they have to, since the overlay renders the
        // tab as it finds it. A refusal that clears the latch alone therefore still moved Settings
        // to a page that never appeared, and the next plain ⌘, — which presets nothing — landed
        // there. Two halves, and the pair is what makes it hold: one door writes the latch, and the
        // refusal consumes what that door stashed.
        let settingsLatchWrites = code.components(separatedBy: "showSettings = true").count - 1
        #expect(settingsLatchWrites == 1,
                "\(settingsLatchWrites) places in ContentView raise Settings directly — a deep link that presets the tab outside `openSettings(on:)` leaves that tab changed when the open is refused")
        let refusal = try #require(code.range(of: ".onChange(of: showSettings) { _, isOpen in"),
                                   "showSettings has no open-guard — this check is vacuous")
        let refusalEnd = try #require(code[refusal.upperBound...].range(of: "\n        }"))
        #expect(String(code[refusal.upperBound..<refusalEnd.lowerBound]).contains("settingsTabBeforeDeepLink"),
                "the refusal does not restore the tab the deep link displaced, so a panel the user never saw still moves Settings to another page")

        // And the mouse half says so rather than no-opping silently.
        let toolbar = try #require(try? String(contentsOf: url.deletingLastPathComponent()
                                                  .appendingPathComponent("ContentView+Toolbar.swift"),
                                               encoding: .utf8))
        #expect(Self.codeOnly(toolbar).components(separatedBy: ".disabled(pendingDestination != nil)").count - 1 >= 4,
                "a toolbar control that cannot act during a pick still looks like it can")
    }

    /// **The three-column deal keeps the reading order and minimises the tallest column.** The
    /// reference went to three columns for v5.3 because two could not hold the Edit group in a
    /// window a 13" display can show; this pins the dealing rule the fits-the-window test below
    /// then measures. Both halves: the real groups come out as three non-empty runs in order, and a
    /// synthetic list whose greedy deal would be lopsided is balanced instead.
    @Test func theColumnsAreDealtInOrderAndBalanced() {
        let groups = ShortcutsReference.groups
        let columns = ShortcutsReference.balancedColumns(groups, count: ShortcutsReference.columnCount)
        #expect(columns.count == ShortcutsReference.columnCount)
        #expect(columns.allSatisfy { !$0.isEmpty }, "a column came out empty")
        #expect(columns.flatMap { $0 } == groups, "the deal reordered or dropped a group")

        // Weights 10, 10, 2, 2, 2, 2: greedy front-loading would pair the two big groups
        // (20 | 4 | 4); the balanced deal keeps them apart (10 | 10 | 8).
        let synthetic = [10, 10, 2, 2, 2, 2].enumerated().map { index, rows in
            ShortcutsReference.Group(title: "g\(index)", items: (0..<(rows - 1)).map {
                ShortcutsReference.Item(keys: "k\(index).\($0)", action: "a\(index).\($0)")
            })
        }
        let dealt = ShortcutsReference.balancedColumns(synthetic, count: 3)
        #expect(dealt.map { $0.map { $0.items.count + 1 }.reduce(0, +) } == [10, 10, 8],
                "the deal weighed the columns as \(dealt.map { $0.map { $0.items.count + 1 }.reduce(0, +) })")
        // The two-way form still agrees with its own pin, so the generalisation changed nothing
        // for the case the older tests were written against.
        let pair = ShortcutsReference.balancedColumns(groups, count: 2)
        #expect(pair.first?.count == ShortcutsReference.balancedSplit(groups))
        // Fewer groups than columns: one per column, never an empty column and never one column
        // holding everything.
        let few = ShortcutsReference.balancedColumns(Array(groups.prefix(2)), count: 3)
        #expect(few.map(\.count) == [1, 1])
    }

    @Test(.machinePinned(.layoutMetrics)) func theReferenceFitsItsWindowWithoutScrolling() {
        let host = NSHostingView(rootView:
            ShortcutsReferenceContent().frame(width: ShortcutsReferenceView.windowSize.width))
        let height = host.fittingSize.height
        #expect(height > 400, "the reference measured implausibly small — the fixture is broken")
        #expect(height <= ShortcutsReferenceView.windowSize.height,
                "the reference needs \(height)pt but the window shows \(ShortcutsReferenceView.windowSize.height)pt — raise windowSize or trim rows")

        // **And it must not be needlessly tall — the drift this test could not see until 2026-08-20.**
        //
        // Every previous failure here was the content outgrowing the window, so the fix was always
        // "raise `windowSize`" and the number only ever went up. Then Browse's sidebar row was
        // removed (the column is held for v4.3) and 780 was suddenly showing 707pt of rows over
        // 73pt of nothing, with every check above green: a panel that is a third empty is a panel
        // that looks like it lost its last group. One row measures ~36pt here, so a 60pt ceiling
        // fails the moment a row leaves without the window following it, and leaves ~27pt of slack
        // over today's 33pt margin for ordinary text reflow.
        let slack = ShortcutsReferenceView.windowSize.height - height
        #expect(slack <= 60,
                "the window shows \(slack)pt of empty space below the last row (\(height)pt of rows in \(ShortcutsReferenceView.windowSize.height)pt) — lower windowSize to the rows it actually has")
    }
}

/// Whether ⌘Q may write the open document.
///
/// **The bug this pins was a write nobody asked for, at the moment it mattered most.** The quit
/// flush was unconditional — right for the ordinary case, where what ⌘Q catches is the two-second
/// debounce window — but it also wrote a file whose autosave switch the user had turned OFF, and
/// it did so BEFORE the unsaved-changes warning, so the question was asked after the answer.
@MainActor
@Suite struct QuitFlushPolicyTests {

    @Test func anOrdinaryDocumentIsStillFlushed() {
        let policy = EditorAutosavePolicy()
        #expect(SyncCloudAppDelegate.mayFlushOnQuit(path: "/n/a.md", policy: policy))
    }

    @Test func aDocumentWithAutosaveOffIsNotFlushed() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/n/a.md")
        #expect(!SyncCloudAppDelegate.mayFlushOnQuit(path: "/n/a.md", policy: policy),
                "quitting would write a file the user switched autosave off for")
        // …and only that file.
        #expect(SyncCloudAppDelegate.mayFlushOnQuit(path: "/n/b.md", policy: policy))
    }

    /// Before `ContentView` has adopted a policy there is nobody to ask, and the flush is right in
    /// the ordinary case — an app that declined to save on quit because a wire was not yet
    /// connected would be the worse of the two failures.
    @Test func noPolicyMeansFlush() {
        #expect(SyncCloudAppDelegate.mayFlushOnQuit(path: "/n/a.md", policy: nil))
        #expect(SyncCloudAppDelegate.mayFlushOnQuit(path: nil, policy: nil))
    }
}
