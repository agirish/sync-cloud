import AppKit
import Design
import Events
import FileExplorer
import SwiftUI
import Testing
import Foundation
@testable import SyncCloud

/// The menu-bar chords' window-side plumbing: the destination-pick suspension, and the ⌘/
/// window still showing the whole reference it exists to show.
///
/// `.serialized` because of ⌘W's refusal line: four tests call `CloseTabCommand.run`, one with
/// `.suspended`, which writes to the process-wide `Logger.shared`, so a sibling could write that
/// line into the "an ordinary ⌘W says nothing" window of
/// `aSuspendedCloseSaysSoInTheLogAndTheOtherTwoStatesDoNot`. No other suite calls `run`, and the
/// suite takes under a second.
@MainActor
@Suite(.serialized) struct ShortcutCommandsTests {

    /// A publisher with every value present, so the suspended case cannot pass vacuously.
    /// `closeTab` is injectable because ⌘W's suspended behaviour is a silence rather than a `nil`,
    /// so its tests watch what the published action does.
    private func loadedPublisher(suspended: Bool, writesLocked: Bool = false,
                                 closeTab: @escaping () -> Void = {}) -> ShortcutValuePublisher {
        ShortcutValuePublisher(
            workspace: .constant(.compare),
            goBack: {}, goForward: {},
            openSelectedFolder: {}, enclosingFolder: {},
            rescan: {}, newFolder: {},
            saveDocument: {}, newTextFile: {}, closeDocument: {},
            documentPrint: DocumentPrintActions(print: {}, export: {}),
            hiddenFiles: .constant(false),
            typeFilter: PaneTypeFilterControl(filter: .constant(nil), facts: nil, folderName: "Downloads"),
            inspector: .constant(false),
            differencesList: .constant(true),
            delete: {},
            switchPaneFocus: PaneFocusSwitch(targetName: "Dropbox", run: {}),
            commandPalette: {},
            beginPaneSearch: {},
            selectAll: {},
            clipboard: ClipboardActions(cut: {}, copy: {}, paste: {}),
            newTab: {}, closeTab: closeTab, cycleTab: { _ in }, reopenClosedTab: {},
            openRecent: { _ in },
            tabBar: TabBarSwitch(isOn: false, isForced: false, set: { _ in }),
            folderSidebar: .constant(true),
            editorTextFiles: .constant(true),
            statusBar: .constant(true),
            organizeLens: OrganizeLensSwitch(current: .duplicates, select: { _ in }),
            organizeVerbs: OrganizeVerbs(organizeFolder: {}, findDuplicates: {},
                                         fixName: {}, keepName: {}, undoReorganisation: {},
                                         planShape: {}, setUpLikeSiblings: {}),
            // Every closure non-nil, `openInEditor` included, or the suspension test below would
            // pass without proving the item was live to begin with.
            paneRowVerbs: PaneRowVerbs(openInNewTab: {}, quickLook: {}, openInEditor: {},
                                       download: PaneRowVerbs.SelectionDownload(title: "Download", run: {}),
                                       revealInFinder: {},
                                       rename: {}, chooseDestination: { _ in },
                                       ignore: PaneRowVerbs.IgnoreToggle(title: "Ignore in Comparison",
                                                                         run: {}),
                                       pdfTools: PaneRowVerbs.SelectionPDFTools(
                                           offer: .several(paths: ["/a/One.pdf", "/a/Two.pdf"]),
                                           run: { _, _ in }),
                                       saveAsPDF: PaneRowVerbs.SelectionSaveAsPDF(
                                           offer: .several(paths: ["/a/One.docx", "/a/Two.md"]),
                                           run: { _ in })),
            compareTwoFiles: {},
            editorVerbs: EditorVerbs(mode: .edit, canPreview: true, setMode: { _ in },
                                     autosave: EditorVerbs.AutosaveSwitch(isOn: true, toggle: {}),
                                     canMarkUp: true, canFind: true, goToLine: {}),
            pdfFind: PDFFindVerbs(isSearchable: true, show: {}, step: { _ in }, useSelection: { true }),
            pdfZoom: PDFZoomVerbs(zoom: { _ in }, actualSize: {}),
            pdfTools: EditorPDFTools(),
            pdfPage: PDFPageVerbs(view: EditorPDFViewState(), goToPage: {}),
            pdfFill: PDFFillSignVerbs(fill: EditorPDFFillSign(store: EditorPDFSignatureStore()),
                                      tools: EditorPDFTools()),
            editorExpand: EditorExpandSwitch(isOn: false, toggle: {}),
            writesLocked: writesLocked,
            suspended: suspended
        )
    }

    /// A long run silences exactly the chords whose buttons it greys. Not the suspension: the
    /// window stays live for reading, so navigation, search, tabs, Quick Look, the clipboard and
    /// Edit's own saves stay live, while what writes to the panes' files goes silent with its
    /// button, so mouse and keyboard meet the same lock.
    @Test func aLongRunSilencesTheWritingChordsAndOnlyThose() throws {
        let open = loadedPublisher(suspended: false, writesLocked: false)
        let locked = loadedPublisher(suspended: false, writesLocked: true)
        // Live before, so the silences below are real.
        #expect(open.effectiveNewFolder != nil && open.effectiveDelete != nil && open.effectiveNewTextFile != nil)

        #expect(locked.effectiveNewFolder == nil, "⇧⌘N stayed live during a run")
        #expect(locked.effectiveNewTextFile == nil, "⌘N stayed live during a run")
        #expect(locked.effectiveDelete == nil, "⌘⌫ stayed live during a run")
        let row = try #require(locked.effectivePaneRowVerbs)
        #expect(row.rename == nil && row.chooseDestination == nil, "Rename / Copy to… stayed live")
        #expect(row.pdfTools == nil && row.saveAsPDF == nil, "a pane's PDF Tools / Save as PDF stayed live")
        #expect(row.quickLook != nil && row.openInEditor != nil && row.revealInFinder != nil
                && row.download != nil && row.openInNewTab != nil && row.ignore != nil,
                "a verb that only opens, shows or fetches went silent")
        let organize = try #require(locked.effectiveOrganizeVerbs)
        #expect(organize.fixName == nil && organize.setUpLikeSiblings == nil && organize.undoReorganisation == nil)
        #expect(organize.organizeFolder != nil && organize.findDuplicates != nil
                && organize.keepName != nil && organize.planShape != nil)

        // Reading, and Edit's own document, stay live.
        #expect(locked.effectiveGoBack != nil && locked.effectiveRescan != nil
                && locked.effectiveBeginPaneSearch != nil && locked.effectiveCommandPalette != nil
                && locked.effectiveNewTab != nil && locked.effectiveSelectAll != nil)
        #expect(locked.effectiveSaveDocument != nil && locked.effectiveDocumentPrint?.export != nil
                && locked.effectivePDFTools != nil && locked.effectivePDFFill != nil)
        // Paste is never greyed; a file paste reaches `FileActionHandler`, which says why.
        #expect(locked.effectiveClipboard?.paste != nil)
    }

    /// The lock's expression at the call site — what `aLongRunSilencesTheWritingChordsAndOnlyThose`
    /// injects and cannot see.
    @Test func theRunLockIsFedFromTheWindowsRun() throws {
        let source = sourceCodeOnly(try Self.publisherSource())
        #expect(source.contains("writesLocked: runWriteLockReason != nil"),
                "the chord publisher is no longer told when a run is going")
    }

    /// Every `effective…` value is actually published. The suspension tests hold the rule and
    /// can't see whether anything reads it: a deleted `.focusedSceneValue` line leaves them green
    /// and the menu item permanently disabled. Derived from the source, so a new value is covered
    /// as soon as it is added.
    @Test func everyEffectiveValueIsHandedToAFocusedSceneValue() throws {
        let source = try Self.publisherSource()
        let names = Self.effectiveValueNames(in: source)
        #expect(names.count >= 12,
                "found only \(names.count) effective values — this scan would be near-vacuous")
        let body = sourceCodeOnly(source)
        for name in names {
            #expect(body.contains(".focusedSceneValue(") && body.contains(", \(name))"),
                    "\(name) is computed and never published — its menu item is permanently disabled")
        }
    }

    /// What feeds `suspended:` at the call site, which the tests above can't see:
    /// `loadedPublisher(suspended:)` injects the flag, so deleting `pendingDestination != nil` or
    /// `showCommandPalette` from the expression would pass them all. Both terms are checked by
    /// name, so reordering them or adding a third reason is not a failure.
    @Test func bothReasonsToSuspendTheChordsSurviveInTheExpression() throws {
        let source = sourceCodeOnly(try Self.publisherSource())
        // Every `suspended:` line, not the first, which is the parameter declaration
        // (`suspended: Bool`). Trailing comments are cut and the line must start with `suspended:`,
        // so a decoy like `suspended: false  // pendingDestination != nil` can't satisfy the checks.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.prefix { $0 != "/" }.trimmingCharacters(in: .whitespaces) }
        let mentions = lines.filter { $0.hasPrefix("suspended:") }
        #expect(!mentions.isEmpty, "the chord publisher no longer takes a suspension at all")
        // If the argument is a bare identifier, follow it: extracting the condition into a named
        // property preserves behaviour and must not fail.
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
    nonisolated static func publisherSource() throws -> String { try macAppFile("ShortcutCommands.swift") }

    /// While the destination picker is up its overlay blocks the mouse from every control these
    /// chords mirror; the keyboard must not tunnel under it. One flag silences all twelve.
    @Test func suspensionSilencesEveryPublishedValue() {
        let publisher = loadedPublisher(suspended: true)
        #expect(publisher.effectiveWorkspace == nil)
        #expect(publisher.effectiveGoBack == nil)
        #expect(publisher.effectiveGoForward == nil)
        #expect(publisher.effectiveOpenSelectedFolder == nil)
        #expect(publisher.effectiveEnclosingFolder == nil)
        #expect(publisher.effectiveRescan == nil)
        #expect(publisher.effectiveNewFolder == nil)
        // The editor's. ⌘S under a destination pick would write the buffer to a path the pick is
        // still deciding about; ⌘N would switch workspace out from under it.
        #expect(publisher.effectiveSaveDocument == nil)
        #expect(publisher.effectiveNewTextFile == nil)
        #expect(publisher.effectiveCloseDocument == nil)
        #expect(publisher.effectiveDocumentPrint == nil)
        #expect(publisher.effectiveHiddenFiles == nil)
        #expect(publisher.effectiveTypeFilter == nil)
        #expect(publisher.effectiveInspector == nil)
        #expect(publisher.effectiveDifferencesList == nil)
        #expect(publisher.effectiveDelete == nil)
        #expect(publisher.effectiveSwitchPaneFocus == nil)
        // ⌘K: the palette must not open over an in-flight destination pick and route out of it.
        #expect(publisher.effectiveCommandPalette == nil)
        // ⌘F and the tab chords. Unsuspended, ⌘T would open a tab under the picker, and ⌘W would
        // fall through to `performClose` and close the window out from under the pick.
        // `everySuspendableValueIsCoveredHere` keeps new values landing in these two lists.
        #expect(publisher.effectiveBeginPaneSearch == nil)
        // The clipboard verbs go silent together, not one at a time: a paste answered under the
        // picker would write files into the pane the pick is describing.
        #expect(publisher.effectiveSelectAll == nil)
        #expect(publisher.effectiveClipboard == nil)
        #expect(publisher.effectiveNewTab == nil)
        #expect(publisher.effectiveCloseTab == nil)
        #expect(publisher.effectiveCycleTab == nil)
        #expect(publisher.effectiveReopenClosedTab == nil)
        // File ▸ Open Recent: opening a file in Edit moves the window under the pick.
        #expect(publisher.effectiveOpenRecent == nil)
        #expect(publisher.effectiveTabBar == nil)
        #expect(publisher.effectiveFolderSidebar == nil)
        #expect(publisher.effectiveEditorTextFiles == nil)
        #expect(publisher.effectiveStatusBar == nil)
        #expect(publisher.effectiveOrganizeLens == nil)
        #expect(publisher.effectiveOrganizeVerbs == nil)
        #expect(publisher.effectivePaneRowVerbs == nil)
        #expect(publisher.effectiveCompareTwoFiles == nil)
        // The Text and Markup menus: a mode switch or an autosave toggle under a destination pick
        // changes the document the pick may be about.
        #expect(publisher.effectiveEditorVerbs == nil)
        #expect(publisher.effectivePDFFind == nil)
        // ⌘+ ⌘− ⌘0 on a PDF: under a pick they go back to the text size, as with nothing focused.
        #expect(publisher.effectivePDFZoom == nil)
        #expect(publisher.effectivePDFTools == nil)
        #expect(publisher.effectivePDFPage == nil)
        #expect(publisher.effectivePDFFill == nil)
        // Text ▸ Expand: folding the pane under a pick hides the folder the pick describes.
        #expect(publisher.effectiveEditorExpand == nil)
    }

    /// ...and the control for the test above: unsuspended, the same publisher passes every value
    /// through, so the nils really came from `suspended`.
    @Test func anUnsuspendedPublisherPassesEveryValueThrough() {
        let publisher = loadedPublisher(suspended: false)
        #expect(publisher.effectiveWorkspace != nil)
        #expect(publisher.effectiveGoBack != nil)
        #expect(publisher.effectiveGoForward != nil)
        #expect(publisher.effectiveOpenSelectedFolder != nil)
        #expect(publisher.effectiveEnclosingFolder != nil)
        #expect(publisher.effectiveRescan != nil)
        #expect(publisher.effectiveNewFolder != nil)
        #expect(publisher.effectiveSaveDocument != nil)
        #expect(publisher.effectiveNewTextFile != nil)
        #expect(publisher.effectiveCloseDocument != nil)
        #expect(publisher.effectiveDocumentPrint != nil)
        #expect(publisher.effectiveHiddenFiles != nil)
        #expect(publisher.effectiveTypeFilter != nil)
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
        #expect(publisher.effectiveOpenRecent != nil)
        #expect(publisher.effectiveTabBar != nil)
        #expect(publisher.effectiveFolderSidebar != nil)
        #expect(publisher.effectiveEditorTextFiles != nil)
        #expect(publisher.effectiveStatusBar != nil)
        #expect(publisher.effectiveOrganizeLens != nil)
        #expect(publisher.effectiveOrganizeVerbs != nil)
        #expect(publisher.effectivePaneRowVerbs != nil)
        #expect(publisher.effectiveCompareTwoFiles != nil)
        #expect(publisher.effectiveEditorVerbs != nil)
        #expect(publisher.effectivePDFFind != nil)
        #expect(publisher.effectivePDFZoom != nil)
        #expect(publisher.effectivePDFTools != nil)
        #expect(publisher.effectivePDFPage != nil)
        #expect(publisher.effectivePDFFill != nil)
        #expect(publisher.effectiveEditorExpand != nil)
    }

    /// Every `effective…` the publisher exposes is named in both lists above. Those two tests are
    /// hand-listed, and `everyEffectiveValueIsHandedToAFocusedSceneValue` only proves a value is
    /// published. Derived from both sources, so a new value is covered when it is written.
    @Test func everySuspendableValueIsCoveredHere() throws {
        let names = Self.effectiveValueNames(in: try Self.publisherSource())
        #expect(names.count >= 14,
                "found only \(names.count) effective values — this scan would be near-vacuous")
        // A known member must be in the derived set, or a parser that matched nothing would make
        // the loop below vacuous.
        #expect(names.contains("effectiveNewTab"),
                "the name scan no longer finds a value that is definitely declared")

        // Bound to each of the two test bodies and to `#expect(`, not the whole file: a file-wide
        // search would accept both forms sitting in the unsuspended test, or a comment naming the
        // value.
        let own = try Self.ownSource()
        let silenced = sourceCodeOnly(try Self.ownMember("func suspensionSilencesEveryPublishedValue", in: own))
        let live = sourceCodeOnly(try Self.ownMember("func anUnsuspendedPublisherPassesEveryValueThrough", in: own))
        for name in names {
            #expect(silenced.contains("#expect(publisher.\(name) == nil)"),
                    "\(name) is never asserted to fall silent while the chords are suspended")
            #expect(live.contains("#expect(publisher.\(name) != nil)"),
                    "\(name) has no unsuspended control — its `== nil` could be vacuously true")
        }
    }


    /// One member's body, to its own closing brace: ``declarationBody(of:in:sourceLocation:)``.
    nonisolated static func memberBody(_ declaration: String, in source: String) throws -> String {
        try declarationBody(of: declaration, in: source)
    }

    /// One member of this file, from its first mention to its closing brace at member indentation.
    /// Not ``declarationBody(of:in:sourceLocation:)``: the declarations it reads also appear in the
    /// coverage scan's own string literals, so that reader's uniqueness check refuses them.
    static func ownMember(_ declaration: String, in source: String) throws -> String {
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

    /// The Go menu item names the pane it moves focus to. It is the only surface that says which
    /// pane is focused, since the panes carry no indicator.
    @Test func theFocusSwitchItemNamesItsDestinationPane() {
        #expect(PaneFocusSwitch.menuTitle(for: PaneFocusSwitch(targetName: "Dropbox", run: {}))
                == "Focus Dropbox")
        // Same-provider panes are disambiguated upstream by `PaneProviderNames`, so the title
        // still names one pane.
        #expect(PaneFocusSwitch.menuTitle(for: PaneFocusSwitch(targetName: "iCloud (right)", run: {}))
                == "Focus iCloud (right)")
    }

    /// The disabled form: a single-source workspace, with no second pane to name.
    @Test func theFocusSwitchItemNamesNoPaneWhenThereIsNoOtherOne() {
        #expect(PaneFocusSwitch.menuTitle(for: nil) == "Focus Other Pane")
    }

    /// ⌘F is published through the publisher, and nowhere else. Published from `ContentView.body`
    /// it would never be suspended: under the destination picker it would open a search field that
    /// takes the typing, ↩ and Esc meant for the pick. Both halves are asserted, since a second
    /// publication could sit beside the right one.
    @Test func findInPaneIsPublishedOnlyThroughTheSuspendablePublisher() throws {
        let publisher = sourceCodeOnly(try Self.publisherSource())
        #expect(publisher.contains(".focusedSceneValue(\\.beginPaneSearch, effectiveBeginPaneSearch)"),
                "⌘F is not published through the publisher, so nothing suspends it")

        let content = try macAppFile("ContentView.swift")
        #expect(!sourceCodeOnly(content).contains(".focusedSceneValue(\\.beginPaneSearch"),
                "ContentView still publishes ⌘F on its own, outside the suspension")
    }

    /// And the suspension actually reaches it: the property, not just the publication.
    @Test func findInPaneIsSilencedWhileThePickerIsUp() {
        #expect(loadedPublisher(suspended: true).effectiveBeginPaneSearch == nil,
                "⌘F tunnels under the destination picker")
        #expect(loadedPublisher(suspended: false).effectiveBeginPaneSearch != nil,
                "⌘F is dead even with nothing suspending it")
    }

    // MARK: ⌘W, whose published value has THREE states

    /// A live tab: the ordinary case, and the control that stops the two below passing on nothing
    /// wired up at all.
    @Test func closeTabClosesTheTabWhenAPaneOffersOne() {
        var closedTab = false
        var closedWindow = false
        let action = loadedPublisher(suspended: false, closeTab: { closedTab = true }).closeTabAction
        CloseTabCommand.run(action) { closedWindow = true }
        #expect(closedTab, "⌘W no longer closes the tab a pane published")
        #expect(!closedWindow, "⌘W closed the window as well as the tab")
    }

    /// Suspended, ⌘W does nothing at all, and above all doesn't close the window. A suspended ⌘W
    /// published as `nil` would read as "this window has no tabs" and answer with `performClose`,
    /// taking the window out from under the pick. Closing the tab instead would be the tunnelling
    /// every other value is nil'd to prevent, so both are asserted.
    @Test func closeTabDoesNothingWhileTheChordsAreSuspended() {
        var closedTab = false
        var closedWindow = false
        let action = loadedPublisher(suspended: true, closeTab: { closedTab = true }).closeTabAction
        // Suspended is published, not withheld: were this `nil`, the run below would take the
        // `closeWindow` branch.
        #expect(action != nil,
                "suspension flattened ⌘W back into `nil`, which the item reads as ‘no tabs here’")
        CloseTabCommand.run(action) { closedWindow = true }
        #expect(!closedTab, "⌘W closed a tab under an overlay that owns the keyboard")
        #expect(!closedWindow,
                "⌘W closed the main window out from under an in-flight destination pick")
    }

    /// …and the case that must not become a no-op with it: the auxiliary `Window` scenes publish no
    /// focused value, and this item replaced the standard Close group, so ⌘W is the only thing that
    /// closes them.
    @Test func closeTabStillClosesAWindowThatPublishesNoTabAtAll() {
        var closedWindow = false
        CloseTabCommand.run(nil) { closedWindow = true }
        #expect(closedWindow, "⌘W is dead on a window that publishes no tab — it is also its Close")
    }

    /// The wiring the tests above can't see: `\.closeTab` is published from the three-state value,
    /// not `effectiveCloseTab` directly. Publishing the plain optional would stop `.suspended`
    /// reaching the item while they, calling the rule, still pass.
    ///
    /// `everyEffectiveValueIsHandedToAFocusedSceneValue` can't cover it either: `effectiveCloseTab`
    /// reaches the scene through `closeTabAction`, so the resolver's own line satisfies that scan.
    @Test func theCloseTabValueIsPublishedThroughItsThreeStateForm() throws {
        let code = sourceCodeOnly(try Self.publisherSource())
        #expect(code.contains(".focusedSceneValue(\\.closeTab, closeTabAction)"),
                "⌘W is not published through `closeTabAction`, so the suspended state cannot reach the item")
        #expect(code.contains("CloseTabAction.resolve(suspended: suspended, effectiveCloseTab)"),
                "`closeTabAction` no longer resolves the suspension — ⌘W would fall through to the window again")
    }

    /// The suspended refusal is the one state that greys the item out. The item reads
    /// `isSuspended`, since ``CloseTabAction`` holds a closure and has no `==`. All three values
    /// are asserted: a `nil` is an auxiliary window, where this item is File ▸ Close, and must not
    /// disable.
    @Test func onlyTheSuspendedCloseActionReadsAsSuspended() {
        #expect(CloseTabAction.suspended.isSuspended)
        #expect(!CloseTabAction.closeTab({}).isSuspended)
        // The optional form the item actually holds — `nil` must not read as a refusal.
        let none: CloseTabAction? = nil
        #expect(none?.isSuspended != true, "a window that publishes no tab reads as suspended")
    }

    /// …and the item really is disabled by it, on the state rather than on `nil`. The menu item is
    /// free never to read the rule above, so the modifier is pinned too, both ways: disabled on
    /// `.suspended`, never on `nil`, which would take ⌘W out of the auxiliary windows.
    ///
    /// Source-level because a `Commands` body can't be mounted in a unit test: `CloseTabCommand`
    /// reads a `@FocusedValue`, which needs a scene, a key window and a focus update.
    @Test func theCloseItemIsDisabledWhileSuspendedAndOnlyThen() throws {
        let body = sourceCodeOnly(try Self.typeBody("struct CloseTabCommand: View {",
                                                   in: try Self.publisherSource()))
        #expect(body.contains(".disabled(close?.isSuspended == true)"),
                "⌘W stays black in a File menu whose every other item has greyed — a control that silently does nothing")
        for deadening in [".disabled(close == nil", ".disabled(close != nil)"] {
            #expect(!body.contains(deadening),
                    "\(deadening) makes ⌘W dead on the auxiliary windows whose File ▸ Close this item replaced")
        }
        #expect(body.contains("Self.run(close,"), "the item does not go through the tested rule")
    }

    /// A refused ⌘W leaves a line, because a disabled item is one deleted modifier away. The
    /// disable is what a person reads; the log is what a report is answered from, at `.info` since
    /// `.debug` is dropped at Settings ▸ Advanced ▸ Info, as ⌘K's refusal does.
    ///
    /// The two states that aren't refusals are asserted silent too, or the line would mean
    /// nothing. Both halves read a capture opened just before the call, since `Logger.shared` is
    /// process-wide and rolled; each window requires its own closing line, and `.serialized` keeps
    /// the window exclusive.
    @Test func aSuspendedCloseSaysSoInTheLogAndTheOtherTwoStatesDoNot() async throws {
        let refusal = "⌘W ignored"
        /// Everything logged while `act` runs, read from a capture opened before it.
        func window(_ act: () -> Void) async throws -> [String] {
            let log = LogCapture()
            act()
            let close = "close-tab window close \(UUID().uuidString.prefix(8))"
            Logger.shared.debug(close)
            let messages = await log.entries.map(\.message)
            let closed = messages.contains(close)
            try #require(closed, "the capture never saw this window's own closing line — this reading is vacuous")
            return messages
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

    /// One type's body, to its own closing brace, required to hold a menu item.
    static func typeBody(_ declaration: String, in source: String) throws -> String {
        let body = try declarationBody(of: declaration, in: source)
        try #require(body.contains("keyboardShortcut"),
                     "the slice of \(declaration) holds no menu item — it stopped short")
        return body
    }

    /// The ambient panels cannot latch behind a destination pick. The latches are plain `Bool`s and
    /// the picker renders in front, so setting one mid-pick would show nothing, then the panel the
    /// instant the pick resolved. ⌘, and ⌘? live in the App scene and see none of this window's
    /// state, so the refusal lives at the latch, and the toolbar buttons disable to match.
    ///
    /// Source-level because `ContentView`'s overlays need a live manager and a render pass; pinned
    /// is that each latch has a guard that reads the picker.
    @Test func theAmbientPanelsRefuseToOpenDuringADestinationPick() throws {
        let content = try macAppFile("ContentView.swift")
        let code = sourceCodeOnly(content)

        // The setup form is the third member of the chain; its `showSetup` latch refuses exactly
        // like the other two.
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

        // A refused Settings open must leave nothing behind either. Deep links preset
        // `settingsTab` before flipping the latch, so a refusal that only cleared the latch would
        // leave Settings on a page that never appeared, for the next plain ⌘, to land on. One door
        // writes the latch, and the refusal restores what that door stashed.
        let settingsLatchWrites = code.components(separatedBy: "showSettings = true").count - 1
        #expect(settingsLatchWrites == 1,
                "\(settingsLatchWrites) places in ContentView raise Settings directly — a deep link that presets the tab outside `openSettings(on:)` leaves that tab changed when the open is refused")
        let refusal = try #require(code.range(of: ".onChange(of: showSettings) { _, isOpen in"),
                                   "showSettings has no open-guard — this check is vacuous")
        let refusalEnd = try #require(code[refusal.upperBound...].range(of: "\n        }"))
        #expect(String(code[refusal.upperBound..<refusalEnd.lowerBound]).contains("settingsTabBeforeDeepLink"),
                "the refusal does not restore the tab the deep link displaced, so a panel the user never saw still moves Settings to another page")

        // And the mouse half says so rather than no-opping silently.
        let toolbar = try macAppFile("ContentView+Toolbar.swift")
        #expect(sourceCodeOnly(toolbar).components(separatedBy: ".disabled(pendingDestination != nil)").count - 1 >= 4,
                "a toolbar control that cannot act during a pick still looks like it can")
    }

    /// The three-column deal keeps the reading order and minimises the tallest column: the real
    /// groups come out as three non-empty runs in order, and a synthetic list a greedy deal would
    /// make lopsided comes out balanced. The fits-the-window test below measures the result.
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
        // Fewer groups than columns: one per column, never an empty column or one holding all.
        let few = ShortcutsReference.balancedColumns(Array(groups.prefix(2)), count: 3)
        #expect(few.map(\.count) == [1, 1])
    }

    /// The reference's laid-out height at `percent`, at the width the window gives it there.
    private static func referenceHeight(percent: Int) -> (height: CGFloat, window: CGSize) {
        let size = FontSize(percent: percent)
        let window = ShortcutsReferenceView.windowSize(scale: size.scale)
        let host = NSHostingView(rootView:
            ShortcutsReferenceContent().frame(width: window.width).appFontSize(size))
        return (host.fittingSize.height, window)
    }

    /// The whole reference fits its window at every text size. The user can't resize the window
    /// and a ScrollView would swallow any overflow, so each selectable stop is measured on the
    /// laid-out content and held to the fit and to a ceiling on empty space below.
    @Test(.machinePinned(.layoutMetrics)) func theReferenceFitsItsWindowAtEveryTextSize() {
        #expect(ShortcutsReferenceView.windowSize(scale: 1) == ShortcutsReferenceView.windowSize,
                "the default text size no longer gets the measured default window")
        var measured: [String] = []
        for percent in FontSize.selectablePercents {
            let (height, window) = Self.referenceHeight(percent: percent)
            measured.append("\(percent)%: \(Int(height.rounded()))pt of rows in \(Int(window.height))pt")
            #expect(height > 400, "\(percent)%: the reference measured implausibly small — the fixture is broken")
            #expect(height <= window.height,
                    "\(percent)%: the reference needs \(height)pt but the window shows \(window.height)pt — raise windowSize or trim rows")

            // And not needlessly tall: a window with empty space below looks like it lost its last
            // group. A row is about 36pt, so a 60pt ceiling fails the moment a row leaves without
            // the window following it.
            let slack = window.height - height
            // And at least 12pt under the last row: less is inside one line of text reflow, so a
            // system font metric change could make it overflow.
            #expect(slack >= 12,
                    "\(percent)%: only \(slack)pt under the last row (\(height)pt of rows in \(window.height)pt) — raise the window")
            #expect(slack <= 60,
                    "\(percent)%: the window shows \(slack)pt of empty space below the last row (\(height)pt of rows in \(window.height)pt) — lower windowSize to the rows it actually has")
        }
        print("Keyboard Shortcuts fit — " + measured.joined(separator: "; "))
    }

    /// On a screen smaller than the window, the window shrinks to it rather than running off its
    /// edge; on a large one it is left alone.
    @Test func theWindowIsHeldInsideASmallScreen() {
        let largest = ShortcutsReferenceView.windowSize(scale: FontSize.extraLarge.scale)
        #expect(largest.width > 1470, "premise: Largest is wider than a 13-inch display")
        let small = ShortcutsReferenceView.fitted(largest, to: CGSize(width: 1470, height: 900))
        #expect(small == CGSize(width: 1430, height: min(largest.height, 860)))
        let big = ShortcutsReferenceView.fitted(largest, to: CGSize(width: 3000, height: 2000))
        #expect(big == largest)
        #expect(ShortcutsReferenceView.fitted(largest, to: nil) == largest)
    }

    /// The window fits the screen it is on, not the main screen; the main screen stands in only
    /// until the window has one.
    @Test func theWindowFitsItsOwnScreen() {
        let laptop = CGSize(width: 1470, height: 900)
        let desk = CGSize(width: 2560, height: 1400)
        #expect(ShortcutsReferenceView.screenToFit(window: laptop, main: desk) == laptop)
        #expect(ShortcutsReferenceView.screenToFit(window: nil, main: desk) == desk)
    }

    /// The reader reports when it joins a window and again each time that window changes screen,
    /// and the reference's frame is sized from what it reports.
    @Test func theScreenReaderReportsOnJoiningAndOnEveryScreenChange() async throws {
        var reports: [CGSize?] = []
        let probe = WindowScreenReader.Probe { reports.append($0) }
        // Never ordered in: test windows stay off his screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(probe)
        // Suspending, not spinning the run loop: the reports arrive on the main queue, which a
        // nested run loop inside this main-actor job does not drain. Bounded at two seconds.
        func settle(until count: Int) async throws {
            let deadline = Date().addingTimeInterval(2)
            while reports.count < count && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle(until: 1)
        #expect(reports.count == 1, "joining a window reported \(reports.count) times")
        #expect(reports.last == .some(window.screen?.visibleFrame.size))

        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        try await settle(until: 2)
        #expect(reports.count == 2, "a screen change was not reported")

        // Another window's screen change is not this one's.
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: other)
        try await Task.sleep(for: .milliseconds(100))
        #expect(reports.count == 2)

        let source = try macAppFile("ShortcutsReference.swift")
        #expect(source.contains(".background(WindowScreenReader { windowScreen = $0 })"))
        #expect(source.contains("to: Self.screenToFit(window: windowScreen, main: NSScreen.main?.visibleFrame.size)"))
    }

    /// A key string that fits its column at Default fits it at every size, so the column scales
    /// with its type. Strings that already wrap at Default (the find row) are left out: that wrap is
    /// the layout the window was measured with.
    @Test(.machinePinned(.layoutMetrics)) func aKeyStringThatFitsAtDefaultFitsAtEverySize() {
        func oneLine(_ keys: String, _ size: FontSize) -> CGFloat {
            NSHostingView(rootView: Text(keys)
                .scaledFont(.system(.callout, design: .monospaced).weight(.medium))
                .fixedSize()
                .appFontSize(size)).fittingSize.width
        }
        let keys = ShortcutsReference.groups.flatMap(\.items).map(\.keys)
        let fitting = keys.filter { oneLine($0, .medium) <= ShortcutsReferenceView.keysColumnWidth }
        #expect(fitting.count > 20, "premise: most key strings fit the column at Default")
        for percent in FontSize.selectablePercents {
            let size = FontSize(percent: percent)
            let column = ShortcutsReferenceView.keysColumnWidth(scale: size.scale)
            for key in fitting where oneLine(key, size) > column {
                Issue.record("\(percent)%: “\(key)” needs \(oneLine(key, size))pt in a \(column)pt keys column")
            }
        }
    }
}

/// Whether ⌘Q may write the open document. The quit flush catches the autosave debounce window in
/// the ordinary case, but must not write a file whose autosave the user turned off; it runs before
/// the unsaved-changes warning, so it would answer the question before it is asked.
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

    /// Before `ContentView` has adopted a policy there is nobody to ask, so flush: declining to save
    /// on quit for want of a wire is the worse failure.
    @Test func noPolicyMeansFlush() {
        #expect(SyncCloudAppDelegate.mayFlushOnQuit(path: "/n/a.md", policy: nil))
        #expect(SyncCloudAppDelegate.mayFlushOnQuit(path: nil, policy: nil))
    }
}
