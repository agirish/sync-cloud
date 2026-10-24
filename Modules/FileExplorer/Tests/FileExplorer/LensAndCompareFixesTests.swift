import AppKit
import Foundation
import Testing
import Design
import Sync
import SwiftUI
@testable import FileExplorer

/// Organize's lenses and Compare, ahead of 6.1 (LN4, LN5, LN7, LN13, LN20, LN22, LN23, DS2, DS3).
///
/// Each fix is pinned twice where it can be: the rule it rests on, called directly, and a scan of
/// the one call site that uses it — because a rule extracted for a test is one revert away from
/// being unused, and SwiftUI gives a unit test no way to press the button that reaches it. LN6's
/// totals are pinned in Sync (`StorageLensTests`) and through the Overview model
/// (`OrganizeOverviewWiringTests`).
@Suite struct LensAndCompareFixesTests {

    // MARK: Source scans

    private static func modulesURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/FileExplorer
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // …/FileExplorer
            .deletingLastPathComponent()      // …/Modules
    }

    private static func source(_ file: String, module: String = "FileExplorer") throws -> String {
        let url = modulesURL().appendingPathComponent("\(module)/Sources/\(module)/\(file)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(file) — every scan here would be vacuous")
        try #require(text.count > 500, "\(file) read as \(text.count) characters — truncated?")
        return text
    }

    /// The source with whole-line `//` comments dropped, so a comment quoting the old code cannot
    /// satisfy, or trip, a scan.
    private static func code(_ file: String, module: String = "FileExplorer") throws -> String {
        try source(file, module: module)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The `length` characters of `text` after the first `anchor`, or nil when it is absent.
    private static func after(_ anchor: String, in text: String, length: Int = 400) -> String? {
        guard let range = text.range(of: anchor) else { return nil }
        return String(text[range.upperBound...].prefix(length))
    }

    // MARK: LN4 — Cancel asks only over real edits

    private static let opened = AutomationRule(
        name: "Invoices", matchMode: .all,
        conditions: [.kindIs(.pdf), .mentionsAll(["invoice"])],
        destinationTemplate: "Documents/Invoices/{year}")

    private static func edited(_ change: (inout AutomationRule) -> Void) -> AutomationRule {
        var rule = opened
        change(&rule)
        return rule
    }

    @Test func aRuleOpenedAndClosedUntouchedHasNoEdits() {
        #expect(!AutomationRuleEditor.hasUnsavedEdits(original: Self.opened, edited: Self.opened))
        // What Save would write the same is not an edit: the destination's stray spaces are
        // trimmed, and free-typed words canonicalize to the tokens the rule already holds.
        let sameOnSave = Self.edited {
            $0.destinationTemplate = "  Documents/Invoices/{year} "
            $0.conditions = [.kindIs(.pdf), .mentionsAll(["Invoice,"])]
        }
        #expect(!AutomationRuleEditor.hasUnsavedEdits(original: Self.opened, edited: sameOnSave))
    }

    @Test func everyEditableFieldCountsAsAnEdit() {
        let edits: [(String, AutomationRule)] = [
            ("name", Self.edited { $0.name = "Receipts" }),
            ("match mode", Self.edited { $0.matchMode = .any }),
            ("a condition added", Self.edited { $0.conditions.append(.largerThanMB(5)) }),
            ("a condition removed", Self.edited { $0.conditions.removeLast() }),
            ("a condition's value", Self.edited { $0.conditions[0] = .kindIs(.image) }),
            ("destination", Self.edited { $0.destinationTemplate = "Documents/Bills" }),
        ]
        for (what, rule) in edits {
            #expect(AutomationRuleEditor.hasUnsavedEdits(original: Self.opened, edited: rule),
                    "changing the \(what) is not seen as an edit — Esc would discard it silently")
        }
    }

    @Test func cancelClosesAtOnceWhenNothingChanged() {
        var asked = 0, closed = 0
        let didClose = AutomationRuleEditor.cancel(original: Self.opened, edited: Self.opened,
                                                   confirmDiscard: { asked += 1; return false },
                                                   close: { closed += 1 })
        #expect(didClose && closed == 1)
        #expect(asked == 0, "Cancel asked about discarding a rule nobody edited")
    }

    @Test func cancelAsksOverEditsAndStaysWhenTheAnswerIsNo() {
        let changed = Self.edited { $0.conditions.append(.largerThanMB(5)) }
        var asked = 0, closed = 0
        let declined = AutomationRuleEditor.cancel(original: Self.opened, edited: changed,
                                                   confirmDiscard: { asked += 1; return false },
                                                   close: { closed += 1 })
        #expect(asked == 1 && !declined && closed == 0,
                "the edits were discarded without asking, or despite the answer")

        let accepted = AutomationRuleEditor.cancel(original: Self.opened, edited: changed,
                                                   confirmDiscard: { true },
                                                   close: { closed += 1 })
        #expect(accepted && closed == 1)
    }

    /// The question's buttons follow the app's leave questions: Discard first, destructive and off
    /// Return; Cancel holds Esc, so a second Esc goes back to the rule instead of losing it.
    @Test @MainActor func theDiscardQuestionKeepsEscForGoingBack() {
        for (alert, title) in [
            (AutomationRuleEditor.discardAlert(ruleName: "Invoices", isNew: false),
             "Discard your changes to “Invoices”?"),
            (AutomationRuleEditor.discardAlert(ruleName: "", isNew: true), "Discard this new rule?"),
        ] {
            #expect(alert.messageText == title)
            #expect(alert.buttons.map(\.title) == ["Discard", "Cancel"])
            #expect(alert.buttons[0].hasDestructiveAction)
            #expect(alert.buttons[0].keyEquivalent.isEmpty, "Return discards the rule")
            #expect(alert.buttons[1].keyEquivalent == "\u{1b}", "Esc no longer goes back to the rule")
        }
    }

    @Test func theEditorsCancelButtonGoesThroughTheQuestion() throws {
        let editor = try Self.code("AutomationRuleEditor.swift")
        #expect(!editor.contains("Button(\"Cancel\", action: onCancel)"),
                "Cancel calls onCancel directly — Esc discards edits without asking")
        let button = try #require(Self.after("Button(\"Cancel\")", in: editor, length: 700),
                                  "the editor has no Cancel button")
        #expect(button.contains("Self.cancel(original: original, edited: assembled"),
                "Cancel does not compare the rule against the one it opened with")
        #expect(button.contains("close: onCancel"))
        #expect(button.contains(".keyboardShortcut(.cancelAction)"), "Esc no longer reaches Cancel")
    }

    // MARK: LN5 — rule cards name the person

    @Test func aPersonChipNamesThePersonOnTheRuleCard() throws {
        let people = [Person(id: "daughter", displayName: "Daughter")]
        #expect(automationConditionChipText(.personIs("daughter"), people: people) == "Daughter")

        let lens = try Self.code("AutomationsLens.swift")
        #expect(lens.contains("text: automationConditionChipText(condition, people: people))"),
                "the rule card's chips do not resolve person ids — a chip reads “daughter”")
        let card = try #require(Self.after("AutomationRuleCard(", in: lens, length: 200))
        #expect(card.contains("people: syncManager.filingPeopleStore?.people ?? []"),
                "the lens does not hand its rule cards the household")
    }

    // MARK: LN7 — "untouched" says what it checks

    @Test func untouchedSaysChangedNotOpened() {
        #expect(StorageSection.stale.subtitle == "Not changed in a long while — oldest first",
                "the list filters on the modification date only, so it cannot say “opened”")
    }

    // MARK: LN13 — no ellipsis on a button that acts at once

    @Test func buttonsThatActAtOnceCarryNoEllipsis() throws {
        let cases: [(file: String, now: String, was: String)] = [
            ("DifferencesView.swift", "Remaining \\(pendingCount)\",", "Remaining \\(pendingCount)…"),
            ("RestructurePlanSheet.swift", "\"Export plan\" : \"Export \\(group.count) plans\"",
             "Export plan…"),
            ("RestructurePairMergeSheet.swift", "Button(\"Save for later\")", "Save for later…"),
            ("FileTreeView.swift", "Label(\"Fix name\", systemImage: RiskyNameGlyph.lens)", "Fix name…"),
        ]
        for (file, now, was) in cases {
            let code = try Self.code(file)
            #expect(code.contains(now), "\(file) no longer carries \(now)")
            #expect(!code.contains(was), "\(file) still promises a question with “\(was)”")
        }
    }

    // MARK: LN20 — File N asks, but not as a Trash

    @Test func fileAllConfirmsWithoutTheDestructiveAlert() throws {
        let lens = try Self.code("LensWorkspaceView.swift")
        let body = try #require(Self.after("private func applyRecommendedFiling(", in: lens, length: 900),
                                "applyRecommendedFiling is gone")
        #expect(body.contains("NativeAlerts.confirmChange("),
                "File N no longer asks through the non-destructive confirm")
        #expect(!body.contains("confirmDestructive"),
                "File N asks with the red Trash-style alert for a move ⌘Z undoes")
        #expect(body.contains("guard ok else { return }"),
                "File N no longer waits for the answer — it creates folders, so it must ask")
    }

    // MARK: LN22 — each page state has its own shape

    @Test func everyPageStateHasItsOwnShapeAndASemanticColour() throws {
        let dots = PageDiffState.Dot.allCases
        #expect(dots.count == 4)
        #expect(Set(dots.map(\.symbol)).count == dots.count,
                "two page states share a shape, so only colour tells them apart")
        #expect(PageDiffState.Dot.same.tint == SemanticColor.success)
        #expect(PageDiffState.Dot.changed.tint == SemanticColor.warning)
        #expect(PageDiffState.Dot.oneSided.tint == SemanticColor.info)
        #expect(PageDiffState.Dot.unrenderable.tint == SemanticColor.error)

        let strip = try Self.code("VisualPairModes.swift")
        let chip = try #require(Self.after("if let dot = state.dot {", in: strip, length: 300))
        #expect(chip.contains("Image(systemName: dot.symbol)"), "the strip draws no shape per state")
        #expect(chip.contains(".foregroundStyle(dot.tint)"))
        #expect(!chip.contains("Circle()"), "the strip still draws one circle for every state")
    }

    // MARK: LN23 — no disabled "Keep this instead"

    /// **The side with nothing to offer drew an empty row**, so its preview sat ~22pt higher than
    /// the kept side's, under its "Keeping this" chip. It now holds the chip's height, invisibly,
    /// and draws nothing in it.
    @MainActor
    @Test func anOverlapGroupsOtherSideKeepsTheChipsHeight() throws {
        func row(_ control: CompareKeeperControl) -> NSHostingView<AnyView> {
            let host = NSHostingView(rootView: AnyView(
                CompareKeeperHeaderRow(control: control, accessibilityLabel: nil, accent: .blue,
                                       onKeepInstead: {})
                    .frame(width: 300)))
            host.layoutSubtreeIfNeeded()
            return host
        }
        let keeping = row(.keeping).fittingSize.height
        let nothing = row(.nothing).fittingSize.height
        #expect(keeping > 12, "premise: the chip has a height (\(keeping))")
        #expect(abs(nothing - keeping) < 0.5,
                "the two previews start at different heights: \(nothing) vs \(keeping)")
        // And the placeholder draws nothing — no "Keeping this" on the side that is not kept.
        let blank = try #require(RestructureRender.raster(
            CompareKeeperHeaderRow(control: .nothing, accessibilityLabel: nil, accent: .blue,
                                   onKeepInstead: {}), width: 300, height: 40))
        #expect(RestructureRender.inkedPixels(blank) == 0, "the hidden chip painted")
    }

    @Test func anOverlapGroupOffersNoKeeperChoiceOnTheOtherSide() throws {
        // An overlap group: it has a keeper, but no choice.
        let inert = DuplicateKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false)
        #expect(CompareKeeperControl.control(isKeeper: false, marker: inert) == .nothing)
        #expect(CompareKeeperControl.control(isKeeper: true, marker: inert) == .keeping,
                "an overlap group does have a keeper, and the kept side still says so")
        // A group with a choice keeps its button.
        let selectable = DuplicateKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false)
        #expect(CompareKeeperControl.control(isKeeper: false, marker: selectable) == .keepInstead)
        #expect(CompareKeeperControl.control(isKeeper: true, marker: .keeper) == .keeping)

        let sheet = try Self.code("CompareCopiesSheet.swift")
        #expect(sheet.contains("control: CompareKeeperControl.control(isKeeper: isKeeper, marker: marker),"),
                "the pane header no longer asks CompareKeeperControl what to draw")
        #expect(!sheet.contains(".disabled(marker == .inert)"),
                "the header draws a disabled “Keep this instead” where there is no choice")
    }

    // MARK: DS2 — warning and success sentences take the readable ink

    @Test func warningAndSuccessSentencesTakeTheReadableInk() throws {
        let sites: [(file: String, module: String, sentence: String, ink: String)] = [
            ("AutomationsLens.swift", "FileExplorer",
             "A file with this name is already there", "SemanticColor.warning"),
            ("AutomationRuleEditor.swift", "FileExplorer",
             "These words are too generic to match on", "SemanticColor.warning"),
            ("FilingSuggestionCard.swift", "FileExplorer", "Text(\"already filed in\")", "SemanticColor.warning"),
            ("SettingsView.swift", "Settings", "Text(preventedLine)", "SemanticColor.success"),
        ]
        for site in sites {
            let code = try Self.code(site.file, module: site.module)
            let styling = try #require(Self.after(site.sentence, in: code, length: 250),
                                       "\(site.file) no longer carries “\(site.sentence)”")
            #expect(styling.contains("ChromeInk.bodyText(colorScheme, \(site.ink))"),
                    "\(site.file): “\(site.sentence)” is painted raw, not with the readable ink")
        }
    }

    // MARK: DS3 — the billing disclosure is readable

    @Test func theBillingDisclosureIsSecondaryAtElevenPoints() throws {
        let sheet = try Self.code("RestructurePlanSheet.swift")
        let styling = try #require(Self.after("Text(Self.payloadDisclosure(", in: sheet, length: 500))
        #expect(styling.contains(".scaledFont(.system(size: 11))"), "the disclosure is not 11pt")
        #expect(styling.contains(".foregroundStyle(.secondary)"), "the disclosure is not secondary ink")
        #expect(!styling.contains(".tertiary"), "the disclosure is still tertiary — the faintest text on screen")
    }
}
