import AppKit
import SwiftUI
import Testing
import Foundation
@testable import SyncCloud

/// The menu-bar chords' window-side plumbing: the destination-pick suspension, and the ⌘/
/// window still showing the whole reference it exists to show.
@MainActor
@Suite struct ShortcutCommandsTests {

    /// A publisher with every value present, so the suspended case cannot pass vacuously.
    private func loadedPublisher(suspended: Bool) -> ShortcutValuePublisher {
        ShortcutValuePublisher(
            workspace: .constant(.compare),
            goBack: {}, goForward: {}, rescan: {}, newFolder: {},
            hiddenFiles: .constant(false),
            previewColumn: .constant(true),
            inspector: .constant(false),
            differencesList: .constant(true),
            delete: {},
            switchPaneFocus: PaneFocusSwitch(targetName: "Dropbox", run: {}),
            commandPalette: {},
            beginPaneSearch: {},
            newTab: {}, closeTab: {}, cycleTab: { _ in }, reopenClosedTab: {},
            tabBar: TabBarSwitch(isOn: false, isForced: false, set: { _ in }),
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
        let names = source.split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "var effective") else { return nil }
                let rest = line[range.upperBound...]
                let name = rest.prefix { $0.isLetter || $0.isNumber }
                return name.isEmpty ? nil : "effective\(name)"
            }
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
        #expect(publisher.effectiveHiddenFiles == nil)
        #expect(publisher.effectivePreviewColumn == nil)
        #expect(publisher.effectiveInspector == nil)
        #expect(publisher.effectiveDifferencesList == nil)
        #expect(publisher.effectiveDelete == nil)
        #expect(publisher.effectiveSwitchPaneFocus == nil)
        // ⌘K was the one chord published outside this type, and so the one this suspension did not
        // reach: the palette opened over an in-flight destination pick and could route out of it.
        #expect(publisher.effectiveCommandPalette == nil)
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
        #expect(publisher.effectiveHiddenFiles != nil)
        #expect(publisher.effectivePreviewColumn != nil)
        #expect(publisher.effectiveInspector != nil)
        #expect(publisher.effectiveDifferencesList != nil)
        #expect(publisher.effectiveDelete != nil)
        #expect(publisher.effectiveSwitchPaneFocus != nil)
        #expect(publisher.effectiveCommandPalette != nil)
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

        // The welcome tour is the third member of the chain and the one with a persisted flag,
        // so it is guarded too — inverted, because its "open" is a *cleared* dismissal.
        #expect(code.contains(".onChange(of: welcomeDismissedThisSession)"),
                "the welcome tour can still latch behind the destination picker")
        #expect(code.contains("hasSeenFirstRunWelcome = true"),
                "a refused tour leaves the persisted seen-flag cleared, so it returns next launch")

        for latch in ["showSettings", "showHelp"] {
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

    @Test func theReferenceFitsItsWindowWithoutScrolling() {
        let host = NSHostingView(rootView:
            ShortcutsReferenceContent().frame(width: ShortcutsReferenceView.windowSize.width))
        let height = host.fittingSize.height
        #expect(height > 400, "the reference measured implausibly small — the fixture is broken")
        #expect(height <= ShortcutsReferenceView.windowSize.height,
                "the reference needs \(height)pt but the window shows \(ShortcutsReferenceView.windowSize.height)pt — raise windowSize or trim rows")
    }
}
