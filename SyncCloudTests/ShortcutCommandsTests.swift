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
        let mentions = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("suspended:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!mentions.isEmpty, "the chord publisher no longer takes a suspension at all")
        let expression = mentions.joined(separator: " ")
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
        #expect(text.count > 500, "ShortcutCommands.swift is implausibly short")
        return text
    }

    /// Whole-line `//` comments removed — a scan for what the code does must not read the prose
    /// that describes it. The same helper, and the same reason, as `OrganizeScopeCallSiteTests`.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

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
    @Test func theReferenceFitsItsWindowWithoutScrolling() {
        let host = NSHostingView(rootView:
            ShortcutsReferenceContent().frame(width: ShortcutsReferenceView.windowSize.width))
        let height = host.fittingSize.height
        #expect(height > 400, "the reference measured implausibly small — the fixture is broken")
        #expect(height <= ShortcutsReferenceView.windowSize.height,
                "the reference needs \(height)pt but the window shows \(ShortcutsReferenceView.windowSize.height)pt — raise windowSize or trim rows")
    }
}
