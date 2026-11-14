import AppKit
import SwiftUI
import Testing
import Foundation
import Events
import Sync
@testable import SyncCloud

/// The app-side half of Browse tabs: where the strip is mounted, what the ⌃⇥ item says, and the
/// three-state Tab Bar switch. `ContentView` can't be instantiated here, so each rule is extracted
/// as a value (`TabBarSwitch.resolve`, `PaneFocusSwitch.menuTitle`) and pinned twice: the rule
/// directly, and its call site by a source scan, since a rule nothing calls is decoration.
@MainActor
@Suite struct PaneTabWiringTests {

    /// Every capture of `group` for `pattern` in `source`, so a scan can derive its subject from
    /// the code rather than keep a list beside it.
    nonisolated private static func matches(_ pattern: String, in source: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
    }

    /// Every argument written against `label:` in `source`, as the whole token it names. A
    /// `contains` check can't tell `isLeft: isLeft` from `isLeft: isLeftTarget`, so a
    /// wrongly-polarised local would satisfy it; capturing the identifier (with any leading `!`)
    /// compares tokens. Pinned by ``theArgumentScanReadsATokenAndNotAPrefix``. `nonisolated`, like
    /// the `ShortcutCommandsTests` readers: text in, text out.
    nonisolated static func argumentTokens(labelled label: String, in source: String) -> [String] {
        matches(#"\#(label):[ \t]*(!?[ \t]*[A-Za-z_][A-Za-z0-9_]*)"#, in: source, group: 1)
            .map { $0.replacingOccurrences(of: " ", with: "")
                     .replacingOccurrences(of: "\t", with: "") }
    }

    /// Every occurrence of `pattern` in `source`, as ranges, for scans that ask where a match sits
    /// (inside a narrowing call, inside an exempt member) rather than only whether it exists.
    static func occurrences(_ pattern: String, in source: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var search = source.startIndex
        while search < source.endIndex,
              let hit = source.range(of: pattern, options: .regularExpression,
                                     range: search..<source.endIndex) {
            found.append(hit)
            // A zero-width match would spin here forever; step past it instead.
            search = hit.upperBound > hit.lowerBound ? hit.upperBound : source.index(after: hit.lowerBound)
        }
        return found
    }

    /// Every call of `opener` in `source`, as the span from the opener to its balanced closing
    /// parenthesis. Balanced, because a regex can't read a call whose argument holds a comma or a
    /// nested `(`, or one wrapped over two lines, and a call the scan can't see may have its sides
    /// swapped with nothing to say so.
    static func callSpans(of opener: String, in source: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var search = source.startIndex
        while let start = source.range(of: opener, range: search..<source.endIndex) {
            var depth = 1
            var index = start.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1 }
                if depth > 0 { index = source.index(after: index) }
            }
            found.append(start.lowerBound..<index)
            search = index < source.endIndex ? source.index(after: index) : source.endIndex
        }
        return found
    }

    /// The argument text of every call of `opener` — what sits between its balanced parentheses.
    static func callArguments(of opener: String, in source: String) -> [String] {
        callSpans(of: opener, in: source).map { span in
            guard let open = source[span].firstIndex(of: "(") else { return "" }
            let inner = source.index(after: open)
            return inner <= span.upperBound ? String(source[inner..<span.upperBound]) : ""
        }
    }

    /// One argument list split on its top-level commas; a comma inside a nested call or a
    /// collection literal belongs to that argument.
    static func topLevelArguments(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            if character == ",", depth == 0 { parts.append(current); current = ""; continue }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// One `PaneSideChoice.own` call, read as the three things it is: which side, and the pair.
    struct SideNarrowing: Equatable {
        var choice: String
        var left: String
        var right: String
    }

    /// Every `PaneSideChoice.own(…)` call in `source`, whatever its shape. A call this can't parse
    /// comes back `nil` and the caller fails on the count, so "unreadable" never reads as "absent".
    static func sideNarrowings(in source: String) -> [SideNarrowing?] {
        callArguments(of: "PaneSideChoice.own(", in: source).map { text in
            let parts = topLevelArguments(text)
            guard parts.count == 3,
                  parts[1].hasPrefix("left:"), parts[2].hasPrefix("right:") else { return nil }
            return SideNarrowing(
                choice: parts[0],
                left: parts[1].dropFirst("left:".count).trimmingCharacters(in: .whitespacesAndNewlines),
                right: parts[2].dropFirst("right:".count).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// One side of a pair with its side-word blanked, so the halves of a matched pair compare equal
    /// and a mismatched one doesn't. A per-argument check alone passes
    /// `own(isLeft, left: syncManager.leftRelativePath, right: syncManager.rightBrowsePath)`, which
    /// narrows two different pairs and is not a pane's value at all.
    static func sideStemmed(_ argument: String) -> String {
        argument
            .replacingOccurrences(of: "left", with: "«side»",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "right", with: "«side»",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// The locals a member binds through the one flip,
    /// `let other = PaneSideChoice.sibling(isLeft)`. Reaching for the sibling pane is fine; writing
    /// the `!` by hand isn't, because it sits in a `ContentView` extension no test can instantiate,
    /// and a dropped `!` opens a mirrored tab on the wrong pane with every other test green.
    static func siblingLocals(in body: String) -> Set<String> {
        Set(matches(#"let (\w+) = PaneSideChoice\.sibling\(isLeft\)"#, in: body, group: 1))
    }

    /// Every label a side is passed under in the tabs file. `refreshForTabSwitch(movedPane:)` and
    /// `mirrorOpenInNewTab(_:from:)` spell it differently, so `isLeft:` alone would miss them.
    static let sideLabels = ["isLeft", "movedPane", "from"]

    /// Every side argument in `body` naming neither the member's own `isLeft` nor a local it bound
    /// through the one flip.
    static func handWrittenSideTokens(in body: String) -> [String] {
        let allowed = siblingLocals(in: body).union(["isLeft"])
        return sideLabels.flatMap { argumentTokens(labelled: $0, in: body) }
            .filter { !allowed.contains($0) }
    }

    /// Where a call sits relative to the member's own control flow.
    enum TopLevelCall: Equatable {
        /// At the member's top level, so every path that does not bail out early runs it.
        case found
        /// At the top level, but an unconditional `return` at that level comes first.
        case afterAnEarlyReturn
        /// Present, but only inside a branch or a closure.
        case onlyInsideABranch
        /// Not in this member at all.
        case absent
    }

    /// Every Swift file under `root`, recursively, so a subfolder like `MacApp/Tabs/` isn't missed.
    /// Callers keep their own floor on the count: `enumerator(at:)` answers non-nil and yields
    /// nothing for a directory it can't list, so only the floor tells that from an empty tree.
    nonisolated static func swiftFiles(under root: URL) -> [URL] {
        var found: [URL] = []
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found
    }

    /// Every `Logger.shared.<level>(…)` call in `body`, as the text of its arguments. Per call, not
    /// per member: `closeTab` logs twice (closing the window on the last tab, and the ordinary
    /// close), so a member-wide `contains` is satisfied by the first and misses a side stripped
    /// from the second.
    static func logCalls(in body: String) -> [String] {
        ["info", "debug", "warning", "error"].flatMap { argumentLists(of: "Logger.shared.\($0)(", in: body) }
    }

    /// A member body with its opening brace removed, so brace depth inside it starts at zero.
    /// ``declarationBody(of:in:sourceLocation:)`` leaves the ` {` on the front, and with it ``topLevelCall`` could never answer
    /// `.found`.
    static func memberInterior(_ body: String) -> String {
        guard let brace = body.firstIndex(of: "{") else { return body }
        return String(body[body.index(after: brace)...])
    }

    /// Whether `call` is reached unconditionally in `body`. A mention check is satisfied by
    /// `if pinned { noteWorkingIn(…) }` or by a call after an early `return`; brace depth catches
    /// both. A call in any branch or closure sits at depth ≥ 1, and a `guard … else { return }`
    /// puts its `return` at depth 1, which correctly doesn't count (`copyTabPath` bails on a chip
    /// its strip doesn't hold, on purpose). Depth is counted over `codeOnly` text; braces inside a
    /// string literal would fool it, and none of the members read here has one.
    /// ``theTopLevelCallScanTellsABranchFromAStatement`` proves all four answers are reachable.
    static func topLevelCall(_ call: String, in body: String) -> TopLevelCall {
        var depth = 0
        var sawTopLevelReturn = false
        var foundSomewhere = false
        var index = body.startIndex
        while index < body.endIndex {
            let rest = body[index...]
            if rest.hasPrefix(call) {
                foundSomewhere = true
                if depth == 0 { return sawTopLevelReturn ? .afterAnEarlyReturn : .found }
            }
            if depth == 0, rest.hasPrefix("return") {
                let before = index == body.startIndex ? " " : String(body[body.index(before: index)])
                if before.rangeOfCharacter(from: CharacterSet.alphanumerics.union(.init(charactersIn: "_"))) == nil {
                    sawTopLevelReturn = true
                }
            }
            if body[index] == "{" { depth += 1 }
            if body[index] == "}" { depth -= 1 }
            index = body.index(after: index)
        }
        return foundSomewhere ? .onlyInsideABranch : .absent
    }

    /// Source with a plain assignment `=` normalised to one space each side, and nothing else
    /// touched. A looser `\s*=\s*` would also rewrite a comparison (`leftProviderId == id` becomes
    /// `leftProviderId =  = id`) and count it as a write, and the tempting repair would be to
    /// loosen the count that gives the assertion its value. The lookbehind refuses an `=` ending a
    /// compound operator (`+=`, `-=`, `!=`, `<=`, `>=`, `==`); the lookahead refuses one starting
    /// `==`. Horizontal whitespace only: `\s` would join two statements across a newline. Pinned by
    /// ``theWriteScanTellsAnAssignmentFromAComparison``.
    nonisolated static func normalizingAssignments(_ source: String) -> String {
        source.replacingOccurrences(of: #"(?<![-+*/%<>!=])[ \t]*=[ \t]*(?!=)"#,
                                    with: " = ", options: .regularExpression)
    }

    /// How many times `source` writes a pane provider id, by any spelling the compiler accepts.
    /// Extracted from the assertion so a fixture can hand it known text.
    static func paneProviderIdWrites(in source: String) -> Int {
        let code = normalizingAssignments(source)
        var writes = 0
        for direct in ["leftProviderId = ", "rightProviderId = "] {
            writes += code.components(separatedBy: direct).count - 1
        }
        // The projected and underscored forms are counted on the raw text: they aren't assignments
        // to normalise, but the refactor someone reaches for to delete the ternary, and a write
        // through `$leftProviderId.wrappedValue` names the property nowhere the pattern above
        // looks for it.
        for indirect in ["$leftProviderId", "$rightProviderId", "_leftProviderId", "_rightProviderId"] {
            writes += source.components(separatedBy: indirect).count - 1
        }
        return writes
    }

    /// The fixture for ``argumentTokens(labelled:in:)``. `"isLeft: isLeftTarget"` contains
    /// `"isLeft: isLeft"`, so a substring check is fooled by a lookalike local; handed known text,
    /// this reads tokens, and a `!`, an unrelated identifier and a lookalike come back as
    /// themselves.
    @Test func theArgumentScanReadsATokenAndNotAPrefix() {
        let text = """
            a(isLeft: isLeft)
            b(isLeft: !isLeft)
            c(isLeft: isLeftTarget)
            d(isLeft: other)
            e(movedPane: isLeft)
            """
        #expect(Self.argumentTokens(labelled: "isLeft", in: text)
                == ["isLeft", "!isLeft", "isLeftTarget", "other"],
                "the argument scan is reading prefixes rather than whole tokens, so a lookalike local passes as the pane it was given")
        #expect(Self.argumentTokens(labelled: "movedPane", in: text) == ["isLeft"],
                "the scan cannot read a differently-labelled side argument")
    }

    /// The fixture for ``topLevelCall(_:in:)``. All four answers come from known text, including
    /// the pair a `contains` can't tell apart: a call the member always makes, and the same call
    /// inside a branch. A `guard … else { return }` keeps its `return` inside braces, so it isn't
    /// an early return, which lets `copyTabPath` bail on a chip its strip doesn't hold.
    @Test func theTopLevelCallScanTellsABranchFromAStatement() {
        #expect(Self.topLevelCall("noteWorkingIn(", in: """
                    noteWorkingIn(isLeft: isLeft, "x")
                    save()
                """) == .found)
        #expect(Self.topLevelCall("noteWorkingIn(", in: """
                    if pinned { noteWorkingIn(isLeft: isLeft, "x") }
                    save()
                """) == .onlyInsideABranch,
                "a focus move wrapped in a condition reads as unconditional — the mutation this scan exists for")
        #expect(Self.topLevelCall("noteWorkingIn(", in: """
                    guard let item = items.first else { return }
                    noteWorkingIn(isLeft: isLeft, "x")
                """) == .found,
                "a `guard … else { return }` above the call is read as an early return — it is the correct shape and must pass")
        #expect(Self.topLevelCall("noteWorkingIn(", in: """
                    return
                    noteWorkingIn(isLeft: isLeft, "x")
                """) == .afterAnEarlyReturn)
        #expect(Self.topLevelCall("noteWorkingIn(", in: """
                    save()
                """) == .absent)
    }

    /// The polarity of what `isLeft` decides, driven rather than scanned. Each choice is a ternary
    /// inside a `ContentView` extension no test can instantiate, where a swap (a cross-source chip
    /// click asking about the sibling pane's source, or a log line naming the wrong pane) leaves
    /// the app suite green. On a type that needs nothing to exist, it's a real assertion.
    @Test func theSideChoiceReadsItsArgument() {
        #expect(PaneSideChoice.own(true, left: "the left one", right: "the right one") == "the left one",
                "a verb aimed at the LEFT pane reads the right pane's value")
        #expect(PaneSideChoice.own(false, left: "the left one", right: "the right one") == "the right one",
                "a verb aimed at the RIGHT pane reads the left pane's value")
        #expect(PaneSideChoice.name(true) == "left",
                "a line about the left pane says it happened in the right one")
        #expect(PaneSideChoice.name(false) == "right",
                "a line about the right pane says it happened in the left one")
        // The third thing `isLeft` decides: a dropped `!` in `mirrorOpenInNewTab`'s sibling would
        // open both tabs of an ⌥/linked Open in New Tab on the pane the user aimed at, with the
        // app suite green. Here it is one call a test can make.
        #expect(PaneSideChoice.sibling(true) == false,
                "the sibling of the LEFT pane is the left pane — a mirrored open lands twice on the pane the user aimed at")
        #expect(PaneSideChoice.sibling(false) == true,
                "the sibling of the RIGHT pane is the right pane — a mirrored open lands twice on the pane the user aimed at")
    }

    // MARK: Where the strip is mounted

    /// A sibling above the header, never a wrapper around it. `PaneQuickLookScopeTests` also
    /// fails if the column's `VStack` is re-nested, but with a message about Quick Look's scope;
    /// this says it directly. One insertion point serves Browse, both Compare panes and the rail.
    @Test func theStripIsMountedAboveTheHeaderInTheSamePaneColumn() throws {
        let content = try macAppFile("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"),
                                  "the pane column is gone — this scan would be vacuous")
        let body = String(content[column.upperBound...].prefix(20_000))
        let strip = try #require(body.range(of: "PaneTabStrip("),
                                 "the pane column does not build a tab strip")
        let header = try #require(body.range(of: "PaneHeader("),
                                  "the pane column does not build its header")
        let list = try #require(body.range(of: "            treeView(pane)\n"),
                                "the pane column no longer builds the list at the expected nesting")
        #expect(strip.lowerBound < header.lowerBound, "the strip is not above the pane header")
        #expect(header.lowerBound < list.lowerBound, "the header is no longer above the list")
        // Mounted at the same nesting as the header — a wrapper would indent the header deeper.
        #expect(body.contains("                PaneTabStrip("),
                "the strip is not a sibling inside the column's VStack")
    }

    /// Drawn only when there is something to draw. At one tab the strip must take no space at all,
    /// or every pane gets an empty 34pt row; "unchanged unless you use it" rests on this `if`.
    @Test func theStripIsGatedOnHavingTabsOrTheSwitch() throws {
        let content = try macAppFile("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        let body = String(content[column.upperBound...].prefix(20_000))
        let gate = try #require(body.range(of: "if paneShowsTabStrip(isLeft: isLeft) {"),
                                "the strip is built unconditionally — one tab now costs a 34pt row")
        let strip = try #require(body.range(of: "PaneTabStrip("))
        #expect(gate.lowerBound < strip.lowerBound, "the gate does not guard the strip")
    }

    /// One call site, so Compare's two panes and the Organize/Storage rail get the strip for free.
    /// A second would be the plumbing this design exists to avoid.
    @Test func thereIsExactlyOnePlaceThatBuildsAStrip() throws {
        let content = try macAppFile("ContentView.swift")
        #expect(content.components(separatedBy: "PaneTabStrip(").count - 1 == 1,
                "more than one place builds a tab strip — they will drift")
    }

    // MARK: The Tab Bar switch

    /// A second tab forces the switch on and freezes it: off, it would read OFF over a strip on
    /// screen, and live, it could hide tabs that would then be unreachable. At one tab it is the
    /// preference, and live.
    @Test(arguments: [(true, false, true, true), (false, false, false, false), (false, true, true, false)])
    func theTabBarSwitchIsForcedOnlyByASecondTab(hasSecondTab: Bool, preference: Bool, isOn: Bool, isForced: Bool) {
        let resolved = TabBarSwitch.resolve(hasSecondTab: hasSecondTab, preference: preference) { _ in }
        #expect(resolved.isOn == isOn)
        #expect(resolved.isForced == isForced)
    }

    /// The switch must ask the question the visibility rule answers, which covers both panes.
    /// `TabBarSwitch.resolve` is pure and the tests above pin it, but they pass just as well if the
    /// caller feeds it the wrong pane: asking only the focused pane, in Compare with a second tab
    /// in the unfocused one, leaves a strip on screen while the menu item reads unticked and live,
    /// offering to hide it and strand its tabs. The forcing is exactly "the strip shows even with
    /// the switch off", proved here for every combination against `shows` rather than by scanning
    /// for a spelling, so any behaviour-preserving refactor still passes.
    @Test func theForcingIsExactlyTheStripShowingWithoutTheSwitch() {
        for own in [true, false] {
            for sibling in [true, false] {
                for isCompare in [true, false] {
                    let forced = PaneTabStripVisibility.forcesTabBarSwitch(
                        own: own, sibling: sibling, isCompare: isCompare)
                    let showsWithSwitchOff = PaneTabStripVisibility.shows(
                        own: own, sibling: sibling, isCompare: isCompare, switchIsOn: false)
                    #expect(forced == showsWithSwitchOff,
                            "own=\(own) sibling=\(sibling) isCompare=\(isCompare): the switch is \(forced ? "frozen" : "live") while a strip \(showsWithSwitchOff ? "is" : "is not") on screen without it — either it can hide a strip and strand its tabs, or it freezes for a strip nobody can see")
                }
            }
        }
        // Compare with the second tab in the sibling only, spelled out because the sweep above
        // would still pass if both rules lost the sibling term together.
        #expect(PaneTabStripVisibility.forcesTabBarSwitch(own: false, sibling: true, isCompare: true),
                "a second tab in the unfocused pane draws a strip on both panes, and the switch must not be able to hide it")
        #expect(!PaneTabStripVisibility.forcesTabBarSwitch(own: false, sibling: true, isCompare: false),
                "outside Compare there is no sibling strip on screen, so the switch must stay live")
    }

    /// The rule above is pure, so every assertion in it passes with the call site still asking one
    /// pane. This pins that the switch goes through it.
    @Test func theTabBarSwitchGoesThroughThatRule() throws {
        let body = try declarationBody(of: "var shortcutTabBar: TabBarSwitch {",
                                       in: try macAppFile("ShortcutCommands.swift"))
        #expect(body.contains("PaneTabStripVisibility.forcesTabBarSwitch("),
                "the Tab Bar switch computes its own forcing condition again — the rule is extracted and unused, and the two came apart exactly this way before")
        #expect(body.contains("TabBarSwitch.resolve("),
                "the switch no longer goes through the extracted resolve, so the two value tests above pin nothing that ships")
    }

    @Test func theSwitchWritesThroughToThePreference() {
        var written: Bool?
        TabBarSwitch.resolve(hasSecondTab: false, preference: false) { written = $0 }.set(true)
        #expect(written == true)
    }

    /// …and the item disables on it, which a value alone can't state.
    @Test func theTabBarItemDisablesWhileTheSwitchIsForced() throws {
        let commands = try macAppFile("ShortcutCommands.swift")
        let body = try declarationBody(of: "struct ToggleTabBarCommand: View {", in: commands)
        #expect(body.contains("isForced == true"),
                "the Tab Bar item stays clickable while a second tab is open")
    }

    // MARK: ⌃⇥ says which of its two jobs it will do

    /// In Browse the same chord cycles tabs, and the menu is the only place that says so at rest.
    @Test func theFocusItemReadsNextTabInBrowse() {
        #expect(PaneFocusSwitch.menuTitle(for: .nextTab(run: {})) == "Next Tab")
    }

    /// The Browse branch is real, not just expressible: ⌃⇥ resolves to a tab cycle there, and only
    /// when the pane has a second tab to cycle to.
    @Test func browseResolvesTheChordToATabCycle() throws {
        let search = try macAppFile("ContentView+PaneSearch.swift")
        let body = try declarationBody(of: "var switchPaneFocusAction: PaneFocusSwitch? {", in: search)
        #expect(body.contains(".nextTab"), "⌃⇥ never cycles tabs — the Browse branch is missing")
        #expect(body.contains("paneTabs(isLeft: true).count > 1"),
                "⌃⇥ offers a tab cycle with only one tab to cycle")
    }

    // MARK: What the chips say

    private func list(_ paths: [String], selected: Int, providers: [String] = []) -> PaneTabList {
        let tabs = paths.enumerated().map { index, path in
            PaneTab(providerId: index < providers.count ? providers[index] : "iCloud", relativePath: path)
        }
        return PaneTabList(tabs: tabs, selectedIndex: selected)
    }

    private let iCloud = PaneTabChips.Source(displayName: "iCloud Drive",
                                             markImageName: "icloud", root: "~/Documents")

    /// The active chip reads the live pane; every other chip reads its own parked snapshot. The
    /// active entry in the list is stale by construction, so a strip drawn only from the list is
    /// right when you arrive and wrong one click later.
    @Test func theActiveChipFollowsThePaneAndTheParkedOnesDoNot() {
        let items = PaneTabChips.items(list(["Finance", "Photos"], selected: 0),
                                       liveProviderId: "Dropbox",
                                       livePath: "Finance/US/2024",
                                       drawsColumns: true,
                                       source: { _ in self.iCloud })
        #expect(items[0].title == "2024", "the active chip is naming its parked snapshot, not the pane")
        #expect(items[0].isActive)
        #expect(items[1].title == "Photos", "a parked chip moved with the pane")
        #expect(!items[1].isActive)
    }

    /// A parked chip promises what selecting it will show, and in Tree that is the tab's scope.
    /// The presentation belongs to the pane, so a parked chip titled from its column stack would
    /// rename itself on click (`2024` to `Finance`) and its tooltip would point at a folder the
    /// pane never shows. The stored location keeps both halves; only the readout resolves.
    @Test func aParkedChipDropsTheColumnStackAPaneInTreeCannotDraw() {
        let parked = PaneTab(providerId: "iCloud", relativePath: "Finance",
                             browsePath: PaneBrowsePath(components: ["US", "2024"]))
        let live = PaneTab(providerId: "iCloud", relativePath: "Photos")
        let list = PaneTabList(tabs: [live, parked], selectedIndex: 0)

        let columns = PaneTabChips.items(list, liveProviderId: "iCloud", livePath: "Photos",
                                         drawsColumns: true, source: { _ in self.iCloud })
        #expect(columns[1].title == "2024", "in Columns the parked chip names the open column")

        let tree = PaneTabChips.items(list, liveProviderId: "iCloud", livePath: "Photos",
                                      drawsColumns: false, source: { _ in self.iCloud })
        #expect(tree[1].title == "Finance",
                "in Tree the parked chip still advertises a column stack the pane will not draw")
        #expect(tree[1].fullPath.hasSuffix("/Finance"),
                "and its tooltip still points into that stack")

        // The active chip's path is what Copy Path copies and what the tooltip shows, so the three
        // agree by construction (see `copyTabPath`). In Tree that means the clipboard carries the
        // scope, which is where selecting the tab lands you.
        #expect(tree[0].fullPath.hasSuffix("/Photos"),
                "Copy Path and the tooltip no longer agree with the chip's own label")
    }

    /// Every chip carries its source's name, which VoiceOver reads in place of the hidden mark
    /// (`PaneTabStrip.spokenName`). Without it, two "Documents" chips from different clouds sound
    /// identical.
    @Test func everyChipCarriesItsSourcesNameForVoiceOver() {
        let items = PaneTabChips.items(list(["Finance", "Photos"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "Finance",
                                       drawsColumns: true,
                                       source: { _ in self.iCloud })
        #expect(items.map(\.sourceName) == ["iCloud Drive", "iCloud Drive"])
        let gone = PaneTabChips.items(list(["Finance"], selected: 0),
                                      liveProviderId: "iCloud", livePath: "Finance",
                                      drawsColumns: true, source: { _ in nil })
        #expect(gone[0].sourceName == nil)
    }

    /// A tab at a source root has no folder to name.
    @Test func aChipAtTheRootWearsItsSourcesName() {
        let items = PaneTabChips.items(list(["", "Photos"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "",
                                       drawsColumns: true,
                                       source: { _ in self.iCloud })
        #expect(items[0].title == "iCloud Drive")
    }

    /// A source removed mid-session: the chip still says which source it meant rather than going
    /// blank, and wears the folder mark `ProviderLogo` draws for a source with no brand.
    @Test func aChipWhoseSourceIsGoneStillNamesIt() {
        let items = PaneTabChips.items(list(["", "Photos"], selected: 0, providers: ["iCloud", "Dropbox"]),
                                       liveProviderId: "iCloud", livePath: "",
                                       drawsColumns: true,
                                       source: { _ in nil })
        #expect(items[0].title == "iCloud")
        #expect(items[0].markImageName == "folder.fill")
    }

    /// The tooltip's path is expanded. A stored root may carry a tilde, and the help tag answers
    /// "which Documents is this?" better with the real path than with `~/Documents/Finance`.
    @Test func theChipsPathIsExpanded() {
        let items = PaneTabChips.items(list(["Finance"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "Finance",
                                       drawsColumns: true,
                                       source: { _ in self.iCloud })
        #expect(!items[0].fullPath.hasPrefix("~"), "the chip's path still carries a tilde")
        #expect(items[0].fullPath.hasSuffix("/Documents/Finance"))
    }

    // MARK: Whether a switch changes the source

    /// The same source writes no provider id; another available one is adopted. The invisible
    /// one: a tab whose source has been removed must not have its folder rendered under whatever
    /// source the pane happens to be showing.
    @Test(arguments: [("iCloud", true, PaneTabProviderSwitch.keep), ("Dropbox", true, .adopt("Dropbox")),
                      ("Dropbox", false, .unavailable("Dropbox"))])
    func aTabsSourceIsKeptAdoptedOrRefused(arrived: String, isAvailable: Bool, expected: PaneTabProviderSwitch) {
        #expect(PaneTabProviderSwitch.decide(arrived: arrived, current: "iCloud",
                                             isAvailable: { _ in isAvailable }) == expected)
    }

    /// …and the call site acts on it. The verb has already applied the tab, so only logging would
    /// leave the pane on the removed source's folder path under the live source's root, which
    /// usually exists nowhere and shows as an empty pane. `discardTab` drops the tab and lands the
    /// pane on one that works; see `PaneTabSwitchingTests` for both cases.
    @Test func aTabOnASourceThatIsGoneIsDiscardedAndNotJustLogged() throws {
        let body = try declarationBody(of: "private func tabAction(isLeft: Bool",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        let branch = try #require(body.range(of: "case .unavailable"),
                                  "the removed-source case is no longer handled")
        let rest = String(body[branch.upperBound...])
        // `discardDeadTabs`, not `discardTab`: the fallback is a neighbour and neighbours die
        // together, so a single discard would land the pane straight on the next dead tab.
        #expect(rest.contains("syncManager.discardDeadTabs("),
                "a tab on a removed source is only warned about — the pane is left on a path under the wrong root")
        // And the pane's search field follows the tab it lands on, like every other arrival.
        #expect(rest.contains("paneSearchState(isLeft: isLeft).wrappedValue"),
                "the discarded tab's search query is left in the field of the tab that replaced it")
        // A discard can land the pane on a third, live source (`PaneTabSwitchingTests
        // .aDiscardCanLandOnATabFromAThirdLiveSource`), which it adopts, or the pane would show the
        // landed path under the old root.
        #expect(rest.contains("adoptProviderForTab("),
                "the pane keeps the dead tab's source after landing on a live one")
        #expect(rest.contains("paneCanShowSource(landed.providerId)"),
                "the landing is adopted without checking the pane may be pointed there")
    }

    /// Every question about whether a pane may be pointed at a source asks `enabledProviders`,
    /// through one predicate. `availableProviders` is the discovered list and keeps a source the
    /// user switched off in Settings, while `refreshAction` and `refreshForTabSwitch` load nothing
    /// for a pair missing from `enabledProviders`. At launch that means a tab restored onto a
    /// disabled source leaves both panes empty with no scan and nothing said, and nothing
    /// re-resolves because `enabledProviders` never changes. Scanned as an absence across the whole
    /// file, since a per-site check passes the moment a new site appears; the one legitimate read
    /// is asserted by name so this can't pass on a file that names no source at all.
    @Test func everyPaneProviderQuestionAsksTheEnabledList() throws {
        let code = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        #expect(code.contains("settings.enabledProviders.contains { $0.id == id }"),
                "paneCanShowSource no longer reads the enabled list")
        for site in ["isAvailable: paneCanShowSource", "isKnownProvider: paneCanShowSource",
                     "canShowSource: paneCanShowSource"] {
            // The third site is the launch restore's adoption gate, handed to
            // `BrowseTabRestorePlan` as a value; the plan's own use of it is executed by
            // `BrowseTabRestorePlanTests.adoptionIsWithheldWhenThePaneCannotShowTheSource`.
            #expect(code.contains(site), "\(site) no longer routes through the one predicate")
        }
        // The chip's name and mark are the one thing the discovered list is right for: a source
        // switched off still has a display name, and a chip reading "Dropbox" for the moment before
        // the tab is discarded beats one reading its raw id.
        let uses = code.components(separatedBy: "availableProviders").count - 1
        #expect(uses == 1,
                "\(uses) uses of availableProviders — a pane may be pointed at a source no refresh will walk")
        let items = try declarationBody(of: "func paneTabItems(isLeft: Bool",
                                        in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(items.contains("settings.availableProviders"),
                "the one legitimate use has moved — this scan is now counting something else")
    }

    /// …and the restore says what it threw away. `PaneTabsStore.restore` drops an entry whose
    /// source this pane can't show, most often because the user switched it off in Settings.
    /// Dropping is right (there's no root to fall back to), but the first save rewrites the strip,
    /// so a silent drop loses those tabs for good with nothing to say where they went.
    @Test func theLaunchRestoreSaysWhatItDropped() throws {
        // The counting and the warning line live in `BrowseTabRestorePlan` and are executed by
        // `BrowseTabRestorePlanTests`. Only this scan sees the threading: the plan can notice a
        // drop only if the host hands it the stored count.
        let body = sourceCodeOnly(try declarationBody(of: "func restoreBrowseTabs(isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        #expect(body.contains("storedCount: stored.entries.count"),
                "nothing hands the plan what was stored, so no drop can be noticed")
    }

    /// Every verb that opens a tab cuts its location through `PaneTabOpening`. A pane's location is
    /// two values and only the stack draws columns past the first, so an opener that hands the
    /// joined path over as the scope flattens the tab on creation, and persistence round-trips the
    /// flattening as "the columns collapse after a restart". Scanned as the absence of the
    /// flattening form as well as the presence of the rule, since a presence check alone passes
    /// with a new opener added beside them doing it the old way.
    @Test func everyTabOpenerCutsItsLocationThroughTheRule() throws {
        let code = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        // Three: ⌘T, Open in New Tab and the mirror. `tabAtRoute` is rooted at its folder on
        // purpose: a followed folder can lie beyond what the scope's walk reached, and a stacked
        // tab there would be pruned a folder short (its doc explains). Pinned below so it drifts
        // into neither the cut nor a flattening.
        let uses = code.components(separatedBy: "PaneTabOpening.location(").count - 1
        #expect(uses == 3, "\(uses) openers cut through the rule — expected ⌘T, Open in New Tab and the mirror")
        #expect(code.components(separatedBy: "browsePath: cut.stack").count - 1 == 3,
                "an opener resolves the cut and then does not use its stack half")
        let rooted = try CodeText(declarationBody(of: "static func tabAtRoute(_ route: ExternalOpen.SourceRoute,", in: code))
        #expect(rooted.contains("PaneTab(providerId: route.providerId, relativePath: route.relativePath, browsePath: PaneBrowsePath(),"),
                "the followed tab is no longer rooted at its folder")
        for flattened in ["relativePath: here)", "relativePath: relative)", "relativePath: landing)"] {
            #expect(!code.contains(flattened),
                    "an opener still hands the joined path over as the scope — the tab opens with its columns collapsed")
        }
    }

    /// Open in New Tab expands the pane's root before comparing anything against it. A stored root
    /// may carry a tilde while a row's id is always absolute, and `PathBoundary.relativize`
    /// compares strings, so an unexpanded root matches nothing and the entry point becomes a silent
    /// no-op whose warning names the wrong reason. The mirror's expansion is scanned by
    /// `bothWaysOfOpeningATabMirrorOntoTheLinkedPane`.
    @Test func openInNewTabExpandsTheSourceRootBeforeRelativizing() throws {
        let body = sourceCodeOnly(try declarationBody(of: "func openInNewTab(absolutePath: String, isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        let root = try #require(body.range(of: "expandingTildeInPath"),
                                "the pane's root is compared unexpanded — Open in New Tab is a no-op for a tilde-stored source")
        let relativize = try #require(body.range(of: "PathBoundary.relativize(absolutePath, under: root)"),
                                      "the row's path is no longer relativized against the pane's root")
        #expect(root.lowerBound < relativize.lowerBound,
                "the root is expanded only after it has been compared against")
    }

    /// The call site: adopting is what arms the suppression counter, and without that the provider
    /// `onChange` runs `retargetPane()` over the navigation the switch just restored.
    @Test func adoptingASourceArmsTheSuppressionCounter() throws {
        let body = try declarationBody(of: "func adoptProviderForTab(",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(body.contains("pendingTabProviderChanges += 1"),
                "adopting a source does not suppress the navigation reset")
        let tab = try declarationBody(of: "private func tabAction(isLeft: Bool",
                                      in: macAppFile("ContentView+PaneTabs.swift"))
        let adopt = try #require(tab.range(of: "case .adopt(let id):"),
                                 "the provider decision is no longer handled by case")
        #expect(String(tab[adopt.upperBound...]).contains("adoptProviderForTab("),
                "the adopt case writes the id some other way than through the one door")
    }

    /// Every write of a pane provider id in the tabs file goes through `adoptProviderForTab`.
    /// Scanned as a count, since a per-site check passes the moment a new writer appears, and
    /// separate writers each tend to forget a different part of the work (the ignore-store re-key,
    /// the lens clear, the suppression). The two assignments allowed are the ones inside the
    /// helper.
    @Test func theOnlyWriterOfAPaneProviderIdInTheTabsFileIsTheAdoptHelper() throws {
        // Counted through `paneProviderIdWrites`, which normalises assignment: Swift accepts
        // `leftProviderId=id` and any run of spaces around the `=`, and a plain substring count
        // sees neither. It doesn't normalise `==`, `!=` or `+=`; the fixture below holds that.
        let raw = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        let writes = Self.paneProviderIdWrites(in: raw)
        #expect(writes == 2,
                "\(writes) writes of a pane provider id — the helper's own two are the only ones allowed")
        let helper = try declarationBody(of: "func adoptProviderForTab(",
                                         in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(helper.contains("if isLeft { leftProviderId = id } else { rightProviderId = id }"),
                "the two writes are not the helper's — this scan is counting someone else's")
    }

    /// The counter above tells a write from a read. A normaliser that rewrites `==` counts
    /// `if leftProviderId == id` as a write, and one that splits `+=` into `+ =` mangles compound
    /// assignments. No such comparison is in the file today, so only a fixture can show it; the
    /// first `==` anyone added would fail the count on a read, and the tempting repair would be to
    /// raise the number the assertion is made of.
    @Test func theWriteScanTellsAnAssignmentFromAComparison() {
        // A comparison is not a write: the latent case this fixture exists for.
        #expect(Self.paneProviderIdWrites(in: "if leftProviderId == id { return }") == 0,
                "a `==` comparison counts as a write — the count breaks on the first read anyone adds")
        #expect(Self.paneProviderIdWrites(in: "guard rightProviderId != id else { return }") == 0,
                "a `!=` comparison counts as a write")
        // Nor is a compound assignment to something else.
        #expect(!Self.normalizingAssignments("pendingTabProviderChanges += 1").contains("+ ="),
                "a compound assignment is still split into `+ =`, so the inert guard is still inert")
        #expect(Self.paneProviderIdWrites(in: "pendingTabProviderChanges += 1") == 0)

        // …and a real write still counts, at every spacing Swift accepts. Without these, "normalise
        // nothing" would pass every assertion above and see no writes.
        #expect(Self.paneProviderIdWrites(in: "leftProviderId=id") == 1, "a tight `=` is not seen")
        #expect(Self.paneProviderIdWrites(in: "rightProviderId   =   id") == 1, "a padded `=` is not seen")
        #expect(Self.paneProviderIdWrites(in: "$leftProviderId.wrappedValue = id") == 1,
                "a write through the projected binding is not seen")

        // Two real writes beside one read and one compound assignment. A normaliser that rewrites
        // `==` or splits `+=` answers 3.
        let mixed = """
            if leftProviderId == id { return }
            pendingTabProviderChanges += 1
            if isLeft { leftProviderId = id } else { rightProviderId = id }
            guard rightProviderId != id else { return }
            """
        let counted = Self.paneProviderIdWrites(in: mixed)
        #expect(counted == 2, "\(counted) writes counted where 2 are real")
    }

    /// The helper does everything the suppressed `onChange` would have done, except the reset the
    /// suppression exists to skip. The re-key matters most: `IgnoredItemsStore` is keyed on the
    /// pair of sources, so leaving it on the old pair hides items ignored for a comparison no
    /// longer on screen and saves new ones under the wrong key.
    @Test func adoptingDoesEverythingTheSuppressedHandlerWouldExceptTheReset() throws {
        let body = try declarationBody(of: "func adoptProviderForTab(",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        // Positives go through `codeOnly` too: a doc comment naming any of these would satisfy the
        // check with the call deleted.
        let code = sourceCodeOnly(body)
        #expect(code.contains("ignoredItemsStore?.activate("),
                "a tab-driven source change leaves the ignored-items store on the old pair")
        #expect(code.contains("clearLensResultsForProviderSwitch()"),
                "stale Tidy results outlive their provider when a tab changes it")
        // Through the coordinator's tab-shaped door, with the side: `.tabChangedSource` carries no
        // side of its own, and the stranded-pin warning it triggers is about the pane the tab did
        // not move (see `StrandedProviderPin`).
        #expect(code.contains("noteTabChangedSource(isLeft: isLeft)"),
                "a guided review framed on the old pair survives a tab-driven source change, or the event no longer says which pane the tab moved")
        // Not `.providerSwitched`: that event can answer with `.undoProviderPin`, which repoints
        // the sibling pane and expects the caller's `retargetPane()` to re-home it, and this method
        // exists not to reset. The reducer half is
        // `CompareReviewReducerTests.aTabDrivenSourceChangeNeverRepointsTheSiblingPane`; this is
        // the call site that chooses the event.
        #expect(!sourceCodeOnly(body).contains("providerSwitched"),
                "the tab path is back on the event that can repoint the other pane")
        // Bare names, not a spelling of the call: call sites pass the landings as arguments, so a
        // check for `resetNavigation()` would match nothing and miss a pasted provider-switch
        // handler. Both names, since `resetNavigation(leftLanding:rightLanding:)` became
        // `retargetPane(isLeft:landing:)`, and a scan naming only one goes vacuous at a rename.
        // The `codeOnly` strip keeps the comments above from satisfying it.
        for verb in ["resetNavigation", "retargetPane"] {
            #expect(!sourceCodeOnly(body).contains(verb),
                    "the whole point of the suppression is that the TAB carries the navigation, but this calls \(verb)")
        }
    }

    /// The rule behind the two provider handlers, and the order that is its whole content.
    @Test func aSuppressionCounterIsConsumedWhereverItsWriteLands() {
        // Bootstrap or not, an armed counter is consumed, so it can't be stranded.
        #expect(PaneProviderChange.decide(swapPending: 0, tabPending: 1, isBootstrapping: true)
                == .consumeTab)
        #expect(PaneProviderChange.decide(swapPending: 1, tabPending: 0, isBootstrapping: true)
                == .consumeSwap)
        // …and the guard-down case, which is where the launch restore's write arrives.
        #expect(PaneProviderChange.decide(swapPending: 0, tabPending: 1, isBootstrapping: false)
                == .consumeTab)
        // Swap wins when both are armed.
        #expect(PaneProviderChange.decide(swapPending: 1, tabPending: 1, isBootstrapping: false)
                == .consumeSwap)
        // Nothing armed: the guard still decides, and a real switch still resets.
        #expect(PaneProviderChange.decide(swapPending: 0, tabPending: 0, isBootstrapping: true)
                == .ignore)
        #expect(PaneProviderChange.decide(swapPending: 0, tabPending: 0, isBootstrapping: false)
                == .userSwitch)
    }

    /// …and both handlers ask it, rather than keeping their own copy of the order.
    @Test func bothProviderHandlersAreResolvedThroughTheRule() throws {
        let code = sourceCodeOnly(try macAppFile("ContentView.swift"))
        #expect(code.components(separatedBy: "PaneProviderChange.decide(").count - 1 == 2,
                "one of the two provider handlers no longer goes through the rule")
        #expect(!code.contains("if pendingTabProviderChanges > 0 {"),
                "a handler is back to testing the counters inline, where the order is unpinned")
    }

    /// A tab verb the user aimed at a pane moves the keyboard focus there, and the mirrored half
    /// of a linked open doesn't. Without the first, opening a tab on the right pane of a Compare
    /// while the ring sits on a one-tab left pane leaves ⌘W aimed left, where `closeTab`'s last-tab
    /// branch closes the window. Without the second, ⌘T in a linked Compare hands every
    /// pane-scoped chord to the sibling.
    @Test func aTabVerbMovesTheFocusToThePaneItWasAimedAt() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        let body = try declarationBody(of: "private func tabAction(isLeft: Bool", in: source)
        #expect(body.contains("if movesFocus { noteWorkingIn(isLeft: isLeft"),
                "a tab verb no longer says which pane the user is working in")
        // The call site of the tested rule. The polarity lives in
        // `FileSyncManager.noteFocusedPane(isLeft:because:)`, which
        // `theFocusedSideFollowsThePaneAVerbWasAimedAt` really calls, because a ternary in a
        // `ContentView` extension could be flipped with every test green. Here, pin that the host
        // still goes through that door.
        let focus = try declarationBody(of: "private func noteWorkingIn(isLeft: Bool", in: source)
        #expect(focus.contains("syncManager.noteFocusedPane(isLeft: isLeft, because: reason)"),
                "noteWorkingIn no longer routes through the manager's one door, so the polarity is back somewhere untested")
        // The opt-out defaults to not opting out, which lets the reachability walk below read an
        // argument-free `tabAction(` as the door.
        let code = sourceCodeOnly(source)
        #expect(code.components(separatedBy: "movesFocus: Bool = true").count - 1 == 1,
                "the one door's focus move is no longer on by default, so every verb that does not mention `movesFocus` has quietly stopped moving the focus")

        // Every `movesFocus` in the file is one this suite reads out of a `tabAction(` call; which
        // verbs may spell it is `everyTabVerbAimsAllItsSideTakingCallsAtOnePane`'s structural
        // question. A fixed count would report `(4) == 3` without naming the verb, and the next
        // legitimate opt-out would make a wrong one indistinguishable from a right one.
        let declared = Self.callArguments(of: "func tabAction(", in: code)
        #expect(declared.count == 1, "\(declared.count) declarations of the one door")
        let optOuts = Self.callArguments(of: "tabAction(", in: code)
            .filter { !declared.contains($0) && $0.contains("movesFocus:") }
        #expect(code.components(separatedBy: "movesFocus: ").count - 1 == optOuts.count + 1,
                "a `movesFocus` is spelled somewhere this scan cannot read it — an opt-out outside a `tabAction(` call is covered by nothing (the +1 is the declaration)")
        #expect(optOuts.count >= 1, "no opt-out found at all — the accounting above is vacuous")
        // The two mirrored halves, by the shape of their opt-out: `!mirrored` is ⌘T's, which opts
        // out only for the mirrored pass, and a bare `false` is the mirror's own, which always
        // lands on the pane the user didn't aim at.
        #expect(optOuts.contains { $0.contains("movesFocus: !mirrored") },
                "the mirrored ⌘T is not the opted-out one")
        #expect(optOuts.contains { $0.contains("movesFocus: false") },
                "the mirrored Open in New Tab is not the opted-out one")
    }

    /// The focus polarity, on a type a test can call. A side resolved by a ternary in a
    /// `ContentView` extension could be flipped with the app suite green, aiming every tab verb at
    /// the opposite pane: open a second tab on the right pane while the ring sits on a one-tab left
    /// pane, press ⌘W, and `closeTab`'s last-tab branch closes the window. On `FileSyncManager` the
    /// flip fails here; the call site is pinned above.
    @Test func theFocusedSideFollowsThePaneAVerbWasAimedAt() {
        let manager = FileSyncManager.scratch(fileManager: FileManager.default)
        manager.noteFocusedPane(isLeft: true, because: "a test aimed at the left pane")
        #expect(manager.focusedPaneSide == .left,
                "a verb aimed at the LEFT pane pointed the pane-scoped chords at the right one")
        manager.noteFocusedPane(isLeft: false, because: "a test aimed at the right pane")
        #expect(manager.focusedPaneSide == .right,
                "a verb aimed at the RIGHT pane pointed the pane-scoped chords at the left one")
        // Both directions, from both starting points: the pair above catches a swapped ternary, but
        // only going back catches a door that simply toggles.
        manager.noteFocusedPane(isLeft: true, because: "back to the left pane")
        #expect(manager.focusedPaneSide == .left, "the door toggles rather than reading its argument")
        // The explicit-`nil` spelling is the one the swap uses, and it must be reachable.
        manager.noteFocusedPane(nil, because: "focus is implicit again")
        #expect(manager.focusedPaneSide == nil, "the door cannot put the focus back to implicit")
    }

    /// Every side-taking call in the one door is aimed at the pane the door was given.
    /// `adoptProviderForTab(id, isLeft: isLeft, …)` appears twice in `tabAction`, and an
    /// `isLeft: !isLeft` at either would write the sibling pane's provider id on a cross-source tab
    /// click, leaving it claiming one source while showing another's tree, and `saveBrowseTabs`
    /// would persist it. Asked as an invariant over the whole member, since `tabAction` is the door
    /// for a verb aimed at one pane and reaching for the sibling anywhere in it is the bug. No
    /// side-taking ternary may be spelled in there either: a swapped
    /// `isLeft ? rightProviderId : leftProviderId` contains neither `"isLeft: "` nor `"!isLeft"`.
    /// The pair is narrowed by `paneProviderId(isLeft:)` and `PaneSideChoice`, whose polarity
    /// `theSideChoiceReadsItsArgument` drives.
    @Test func theOneDoorAimsEverySideTakingCallAtThePaneItWasGiven() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        let body = sourceCodeOnly(try declarationBody(of: "private func tabAction(isLeft: Bool", in: source))
        // The positive control: the calls this is about are in here at all, or a member that lost
        // them all would satisfy every invariant below.
        #expect(body.components(separatedBy: "adoptProviderForTab(").count - 1 == 2,
                "the two adopt sites this is about are no longer both in the one door")
        #expect(body.contains("noteWorkingIn(isLeft: "),
                "the one door no longer says which pane the user is working in")
        let reads = body.components(separatedBy: "paneProviderId(isLeft: ").count - 1
        #expect(reads >= 4,
                "\(reads) reads of this pane's provider id in the one door — it has stopped asking through the one wrapper, and the pair-to-side arguments are loose in here again")

        // Every `isLeft:` argument in here names `isLeft` itself, compared as a token, so a local
        // whose name merely starts with `isLeft` doesn't pass.
        let tokens = Self.argumentTokens(labelled: "isLeft", in: body)
        // The current count (12), not a number low enough to be safe: a floor well under it passes
        // with half the calls gone.
        #expect(tokens.count >= 12,
                "\(tokens.count) `isLeft:` arguments in the one door where 12 are expected — it has lost calls this is meant to cover")
        let strays = tokens.filter { $0 != "isLeft" }
        #expect(strays.isEmpty,
                "\(strays) named instead of the pane the one door was given — a verb aimed at one pane is acting on the other")
        // …and nothing in here reaches for the sibling under any other label either
        // (`refreshForTabSwitch(movedPane:)` spells it differently, and would be missed above).
        #expect(!body.contains("!isLeft"),
                "the one door reaches for the SIBLING pane — every verb through it is aimed at exactly one pane, and the mirrored openers opt out before they get here")

        // The ternary and the bare pair are both banned. A swapped ternary is invisible to every
        // check above; so is `if isLeft { … leftProviderId … } else { … rightProviderId … }`,
        // which is the shape someone reaches for once the ternary is refused.
        #expect(!body.contains("isLeft ?"),
                "a side-taking ternary is back in the one door — swapping it re-creates the headline defect and is invisible to every argument check here; narrow the pair through `paneProviderId(isLeft:)` or `PaneSideChoice.own`")
        for bare in ["leftProviderId", "rightProviderId"] {
            #expect(!body.contains(bare),
                    "the one door reads `\(bare)` directly — the pane's own value must come through `paneProviderId(isLeft:)`, which is the one place the view's PAIR is narrowed to a SIDE")
        }

        // The arguments `PaneSideChoice` itself can't see are checked by
        // `everyPaneSideChoiceCallNarrowsAMatchedPair` across the whole app target, since
        // `PaneSideChoice` is app-wide.
    }

    /// The verbs that reach the focus door themselves aim it at the pane they were given. The
    /// invariant above covers only `tabAction`'s body, so a verb outside it could pass
    /// `noteWorkingIn(isLeft: !isLeft)`: right-click a chip in the right strip ▸ Copy Path with a
    /// one-tab left pane focused, press ⌘W, and the last-tab branch closes the window.
    /// `setTabPinned` and `moveTab` go through `tabAction` with a `nil` answer, which puts them
    /// under every invariant above. Copy Path can't: it must bail on a chip this strip doesn't hold
    /// before it moves anything, and it saves no strip, so it keeps its own focus door and is
    /// checked here by name.
    @Test func theVerbsOutsideTheOneDoorAimItAtThePaneTheyWereGiven() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        let file = sourceCodeOnly(source)

        // Exactly two members hold a focus door: the one door, and Copy Path. A third would be a
        // verb with its own polarity again, unseen by every check here.
        let doors = file.components(separatedBy: "noteWorkingIn(").count - 1
        #expect(doors == 3,
                "\(doors - 1) call sites of the focus door in this file where 2 are expected (the third match is its declaration) — a verb outside the one door aims the pane-scoped chords itself, and nothing below covers it")

        let copy = Self.memberInterior(
            sourceCodeOnly(try declarationBody(of: "func copyTabPath(id: UUID, isLeft: Bool)", in: source)))
        #expect(Self.topLevelCall("noteWorkingIn(", in: copy) == .found,
                "Copy Path's focus move is conditional or unreachable — right-click a chip in the other strip, press ⌘W, and the last-tab branch closes the WINDOW")
        let copyStrays = Self.argumentTokens(labelled: "isLeft", in: copy).filter { $0 != "isLeft" }
        #expect(copyStrays.isEmpty,
                "\(copyStrays) in Copy Path name something other than the pane it was given")
        #expect(!copy.contains("!isLeft"), "Copy Path reaches for the SIBLING pane")
        #expect(!copy.contains("isLeft ?"),
                "a side-taking ternary is back in Copy Path — swapping it aims the chords at the pane the user is not looking at, and no argument check here can see it")
        // …and it refuses during bootstrap, like every other strip verb, rather than moving the
        // chords against a pane whose source the bootstrap hasn't chosen yet.
        #expect(Self.topLevelCall("guard !isBootstrappingProviders", in: copy) == .found,
                "Copy Path acts during the provider bootstrap, where every other tab verb refuses")

        // The two fixed by construction: through the one door, unconditionally.
        for verb in ["func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                     "func moveTab(id: UUID, to index: Int, isLeft: Bool)"] {
            let body = Self.memberInterior(sourceCodeOnly(try declarationBody(of: verb, in: source)))
            #expect(Self.topLevelCall("tabAction(isLeft: isLeft)", in: body) == .found,
                    "“\(verb)” is back outside the one door, or its call is inside a branch — `if pinned { … }` around it is a measured survivor, and unpinning then leaves ⌘W aimed at the other pane")
            #expect(!body.contains("noteWorkingIn("),
                    "“\(verb)” keeps a focus door of its own alongside the one door's — two moves, one of which no invariant reads")
            let strays = Self.argumentTokens(labelled: "isLeft", in: body).filter { $0 != "isLeft" }
            #expect(strays.isEmpty, "\(strays) in “\(verb)” name something other than the pane it was given")
        }
    }

    /// Every tab verb the host wires reaches the focus door unconditionally. The set of verbs is
    /// derived, not listed: every member of the tabs file that any host file calls. Both ends of
    /// the derivation are closed:
    ///
    /// - Which files may wire one is asserted: every `MacApp/**` Swift file is walked, and any that
    ///   calls into the tabs file must be in `wiringFiles`, so a new one fails by name.
    /// - Which calls are verbs is the one judgement left, spelled out: the readers and the
    ///   persistence pair must not move a focus, because nothing a user aimed at a pane happened.
    ///   Each exclusion must be in the derived set, so a rename can't hide a real verb.
    ///
    /// `topLevelCall` answers on brace depth, so each verb calls the door on every path that
    /// doesn't bail early, not merely mentions it. A `tabAction(` passing `movesFocus: false` isn't
    /// a door, so a verb that opts out fails here by name. `movesFocus: !mirrored` counts, since
    /// its unmirrored pass is the verb's own pane; `aTabVerbMovesTheFocusToThePaneItWasAimedAt`
    /// pins the door's shape and default, and `everyTabVerbAimsAllItsSideTakingCallsAtOnePane`
    /// makes every opt-out justify itself. It can't see a door reached only through a third member,
    /// wrong arguments to the door (`theOneDoorAims…`'s half), or wiring outside `MacApp/`.
    @Test func everyTabVerbTheHostWiresReachesTheFocusDoorUnconditionally() throws {
        let tabs = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        // The extension's own members, not the file's: the helper types below it declare `items`,
        // `shows`, `inset` and `decide`, and names that common would match half the host.
        let extensionBody = try declarationBody(of: "extension ContentView {", in: tabs)
        let declared = Set(Self.matches(#"\n    (?:private )?func ([a-zA-Z]\w*)\("#,
                                        in: extensionBody, group: 1))
        #expect(declared.count >= 20,
                "\(declared.count) members found in the tabs extension — the member scan is reading the wrong thing")
        #expect(declared.isSuperset(of: ["copyTabPath", "tabAction", "noteWorkingIn", "tabLogDescription"]),
                "the member scan lost members that are plainly there — every check below would be vacuous")
        #expect(!declared.contains("decide") && !declared.contains("items"),
                "the member scan has spilled out of the extension into the helper types below it")

        // Which host files wire into the tabs file at all. Walked recursively, so a `MacApp/Tabs/`
        // folder would be seen.
        let macApp = macAppDirectory()
        let hostFiles = Self.swiftFiles(under: macApp)
        #expect(hostFiles.count > 20,
                "the host walk found \(hostFiles.count) Swift files — it is reading the wrong folder, or the enumerator yielded nothing")

        // Why each file beyond the first three is here:
        // - `ContentView+FolderSidebar.swift`: the sidebar's ⌘-click opens a folder in a new tab
        //   (`openInNewTab`).
        // - `CommandPaletteHost.swift`: a ⌘K source switch calls `adoptProviderForTab` and
        //   `refreshForTabSwitch`, the tail a tab switch shares; both are excluded below.
        // - `ContentView+Editor.swift`: when Edit opens a file the pane follows it by tab
        //   (`selectTab`, `openTabAtRoute`), and a batch from Finder builds tabs with `tabAtRoute`.
        // - `ContentView+AskClaude.swift`: `go_to` switches to a tab by name (`selectTab`), opens a
        //   folder in a new tab (`openInNewTab`), and names the tabs on screen (`paneTabItems`).
        let wiringFiles = ["ContentView.swift", "ShortcutCommands.swift", "ContentView+PaneSearch.swift",
                           "ContentView+FolderSidebar.swift", "CommandPaletteHost.swift",
                           "ContentView+Editor.swift", "ContentView+AskClaude.swift"]
        var derived: Set<String> = []
        for file in hostFiles where file.lastPathComponent != "ContentView+PaneTabs.swift" {
            let code = sourceCodeOnly(try String(contentsOf: file, encoding: .utf8))
            let calls = Set(Self.matches(#"\b([a-z][A-Za-z0-9]*)\("#, in: code, group: 1))
                .intersection(declared)
            guard !calls.isEmpty else { continue }
            #expect(wiringFiles.contains(file.lastPathComponent),
                    "\(file.lastPathComponent) calls \(calls.sorted()) in the tabs file and is not one of the wiring files this derivation reads — a verb wired there is covered by nothing")
            derived.formUnion(calls)
        }

        // The readers and the persistence pair: called by the host, and deliberately not verbs.
        //
        // `adoptProviderForTab` and `refreshForTabSwitch` are the shared tail of a source change,
        // which the ⌘K route also uses. Neither should say which pane the user is working in: the
        // caller has already decided the side, and the palette is aimed at the focused pane by
        // construction (`lensTargetIsRight`). Requiring the door would have the tail of an
        // operation re-announce a pane it never chose.
        //
        // `paneProviderId`, `paneScope` and `paneStack` are `PaneSideChoice.own` getters that
        // return a value and do nothing else (`ContentView.adoptSourceWalkedInto` uses them).
        // They replace the hand-written ternary this suite keeps out of the host, and
        // `theSideChoiceReadsItsArgument` drives their polarity; requiring a getter to move the
        // focus would push callers back to the ternary.
        //
        // `tabAtRoute` is a `static` value-maker that reads no pane, so it isn't derived at all;
        // `openTabAtRoute`, which opens one live, is held to the rule.
        let notVerbs = ["paneTabItems", "paneShowsTabStrip", "seamInset",
                        "saveBrowseTabs", "restoreBrowseTabs",
                        "adoptProviderForTab", "refreshForTabSwitch",
                        "paneProviderId", "paneScope", "paneStack"]
        for excluded in notVerbs {
            #expect(derived.contains(excluded),
                    "“\(excluded)” is excluded from this rule as a reader, and the derivation no longer finds it being called at all — the exclusion is now a name that could be hiding a real verb")
        }
        let verbs = derived.subtracting(notVerbs)
        #expect(verbs.count >= 11,
                "the host's wiring resolved to \(verbs.count) verbs (\(verbs.sorted())) — the derivation has stopped finding them, and every check below is vacuous")
        // Named, so the derivation can't lose any of these silently.
        for named in ["copyTabPath", "selectTab", "moveTab", "setTabPinned", "openNewTabHere",
                      "cycleTab", "reopenClosedTab"] {
            #expect(verbs.contains(named),
                    "“\(named)” is wired to a pane's tab strip and the derivation did not find it")
        }

        /// Whether `name` reaches the focus door on every path that doesn't bail out early,
        /// directly or through one more member of the tabs file. Two hops is what ⌘T needs:
        /// `openNewTabHere` mirrors through `openTabHere` to `tabAction`.
        func reachesTheFocusDoor(_ name: String, hops: Int) throws -> Bool {
            let body = Self.memberInterior(try declarationBody(of: "func \(name)(", in: tabs))
            if Self.topLevelCall("noteWorkingIn(", in: body) == .found { return true }
            // `tabAction(` is the door only when the call hasn't opted out: `movesFocus: false`
            // puts `noteWorkingIn` behind a branch known to be false, so a verb whose only route to
            // the door is such a call reaches none.
            if Self.topLevelCall("tabAction(", in: body) == .found,
               !Self.callArguments(of: "tabAction(", in: body)
                   .contains(where: { $0.contains("movesFocus: false") }) { return true }
            guard hops > 0 else { return false }
            for called in Self.matches(#"\b([a-z][A-Za-z0-9]*)\("#, in: body, group: 1)
            where declared.contains(called) && called != name {
                guard Self.topLevelCall("\(called)(", in: body) == .found else { continue }
                if try reachesTheFocusDoor(called, hops: hops - 1) { return true }
            }
            return false
        }

        // The negative control, first: a member of the same file that describes a tab for the log
        // and moves no focus. If this answers yes the walk can't fail, and every verb passes free.
        #expect(try !reachesTheFocusDoor("tabLogDescription", hops: 2),
                "the reachability walk says a member that touches no focus door reaches one — it cannot fail, so nothing below it means anything")
        // The second negative control: `mirrorOpenInNewTab` goes through `tabAction` on every path
        // and opts out of the focus door, so a walk that reads `tabAction(` as a door regardless of
        // its arguments answers yes here.
        #expect(try !reachesTheFocusDoor("mirrorOpenInNewTab", hops: 2),
                "the walk counts a `tabAction(…, movesFocus: false)` as reaching the focus door — under that reading `tabAction(isLeft: isLeft, movesFocus: false)` in any verb below passes here, and nothing names the verb that stopped moving the focus")

        for verb in verbs.sorted() {
            #expect(try reachesTheFocusDoor(verb, hops: 2),
                    "“\(verb)” is wired to a pane's tab strip and does not say which pane the user is working in on every path — in Compare that leaves ⌘W aimed at the other pane, where its last-tab branch closes the WINDOW")
            // …and it acts on the pane it was given: a verb that hands the door its sibling aims
            // every pane-scoped chord at the wrong strip. A verb may reach for the sibling on
            // purpose (⌘T's mirrored half opens a tab on the other pane), but only through
            // `PaneSideChoice.sibling`, whose polarity `theSideChoiceReadsItsArgument` drives. The
            // exception is derived from the member's own bindings, so a hand-written `!` is refused
            // wherever it appears.
            let hand = Self.handWrittenSideTokens(
                in: Self.memberInterior(try declarationBody(of: "func \(verb)(", in: tabs)))
            #expect(hand.isEmpty,
                    "“\(verb)” passes \(hand) where the pane it was given, or a sibling taken through `PaneSideChoice.sibling`, is expected — the verb acts on the pane the user did not aim at")
        }
    }

    /// Every reach for the sibling pane in the tabs file goes through the one flip. A `!` in a
    /// `ContentView` extension is a spelling nothing can drive: a dropped `!` in
    /// `mirrorOpenInNewTab` would open both tabs of an ⌥/linked Open in New Tab on the pane the
    /// user aimed at, with the app suite green. The polarity is `PaneSideChoice.sibling`, which
    /// `theSideChoiceReadsItsArgument` calls both ways; this scan keeps the hand-written form from
    /// coming back anywhere in the file, including at sites that don't exist yet.
    @Test func everyReachForTheSiblingPaneGoesThroughTheOneFlip() throws {
        let file = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        // The flip exists, and it is the only one written out in the file. Its behaviour is
        // `theSideChoiceReadsItsArgument`'s; this checks only that there is one of it.
        let flips = file.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("!isLeft") }
        #expect(flips.count == 1,
                "\(flips.count) hand-written `!isLeft` in the tabs file where 1 is expected (`PaneSideChoice.sibling`'s own body) — a side flip outside it is a polarity no test can drive")
        #expect(flips.first?.contains("static func sibling(") == true,
                "the one `!isLeft` in the file is not `PaneSideChoice.sibling`'s — the flip has moved back somewhere a test cannot call it")

        let extensionBody = try declarationBody(of: "extension ContentView {", in: file)
        let declared = Set(Self.matches(#"\n    (?:private )?func ([a-zA-Z]\w*)\("#,
                                        in: extensionBody, group: 1))
        #expect(declared.count >= 20,
                "\(declared.count) members found in the tabs extension — the member scan is reading the wrong thing and every check below is vacuous")

        var mirrors: Set<String> = []
        for member in declared.sorted() {
            let body = Self.memberInterior(try declarationBody(of: "func \(member)(", in: file))
            if !Self.siblingLocals(in: body).isEmpty { mirrors.insert(member) }
            let hand = Self.handWrittenSideTokens(in: body)
            #expect(hand.isEmpty,
                    "“\(member)” passes \(hand) as a side — the pane it was given, or a sibling bound through `PaneSideChoice.sibling`, is what a side argument may name")
        }
        // The derived set, not a floor: a member that starts mirroring should not arrive
        // unremarked, since reaching for the sibling puts a tab on the pane the user didn't aim at.
        #expect(mirrors == ["paneShowsTabStrip", "openNewTabHere", "mirrorOpenInNewTab"],
                "the members reaching for the sibling pane are \(mirrors.sorted()) — a member has started or stopped mirroring, and which panes a verb touches is not a thing to change silently")
    }

    /// A tab verb aims every side-taking call it makes at the one pane it moves.
    /// `theOneDoorAimsEverySideTakingCallAtThePaneItWasGiven` covers only `tabAction`'s body, and
    /// the location pair (the `openedFromScope:` cuts, the save's overlay, `ColumnStackPruning`)
    /// lives outside it, where a transposition leaves the app suite green. Stated over the verbs
    /// and derived: the pane a verb moves is whatever it hands `tabAction`, and every other side it
    /// computes must be the same token, so `paneScope(isLeft: !isLeft)` fails by name.
    ///
    /// The opt-out justifies itself structurally. A verb may decline to move the focus only when it
    /// lands on the sibling (`movesFocus: false`, aimed at a `PaneSideChoice.sibling` local) or
    /// when the decline is its caller's mirror flag (`movesFocus: !mirrored`, on a member whose
    /// `mirrored` defaults to false). Anything else fails naming the verb.
    @Test func everyTabVerbAimsAllItsSideTakingCallsAtOnePane() throws {
        let file = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        let extensionBody = try declarationBody(of: "extension ContentView {", in: file)
        let declared = Set(Self.matches(#"\n    (?:private )?func ([a-zA-Z]\w*)\("#,
                                        in: extensionBody, group: 1))

        var aims: [String: String] = [:]
        var optOuts: [String: String] = [:]
        for member in declared.sorted() {
            let body = Self.memberInterior(try declarationBody(of: "func \(member)(", in: file))
            let calls = Self.callArguments(of: "tabAction(", in: body)
            guard !calls.isEmpty else { continue }
            // One per member: two would mean two panes moved by one verb, and the aim below would
            // silently be the first one's.
            try #require(calls.count == 1,
                         "“\(member)” runs \(calls.count) tab verbs through the one door — the aim read below would be only the first")
            let aim = try #require(Self.argumentTokens(labelled: "isLeft", in: calls[0]).first,
                                   "“\(member)” calls the one door without naming a pane")
            aims[member] = aim
            let strays = Self.sideLabels.flatMap { Self.argumentTokens(labelled: $0, in: body) }
                .filter { $0 != aim }
            #expect(strays.isEmpty,
                    "“\(member)” moves the “\(aim)” pane and passes \(strays) elsewhere — a value taken from the pane the verb is not moving. That is the `openedFromScope:` transposition: the tab is cut against the SIBLING's scope, so it opens with its columns flattened, or at a comparison scope the user never set")
            if let opt = Self.argumentTokens(labelled: "movesFocus", in: calls[0]).first {
                optOuts[member] = opt
            }
        }
        // The current count (eleven verbs through the one door). A floor well under it passes with
        // half of them gone.
        #expect(aims.count >= 11,
                "\(aims.count) members run a verb through the one door where 11 are expected — the derivation has stopped finding them and every check above is vacuous")
        #expect(Set(aims.keys).isSuperset(of: ["openTabHere", "openInNewTab", "mirrorOpenInNewTab",
                                               "closeTab", "selectTab", "setTabPinned"]),
                "the derivation lost verbs that are plainly there — it is reading the wrong members")
        // The mirror aims at a pane that isn't its own `isLeft`; every other verb aims at `isLeft`.
        // Without this, "every aim is the same token" satisfies everything above. Unwrapped rather
        // than compared with `!=`, because a missing entry makes `nil != "isLeft"` true and the
        // check would pass when the derivation found nothing.
        let mirrorAim = try #require(aims["mirrorOpenInNewTab"],
                                     "the mirror no longer runs its open through the one door")
        #expect(mirrorAim != "isLeft",
                "the mirror moves the pane it was given rather than the sibling — the linked half opens on the wrong pane")
        #expect(aims["openTabHere"] == "isLeft", "⌘T moves a pane other than the one it was given")

        #expect(!optOuts.isEmpty, "no verb opts out of the focus door — the checks below are vacuous")
        for (member, value) in optOuts.sorted(by: { $0.key < $1.key }) {
            let body = Self.memberInterior(try declarationBody(of: "func \(member)(", in: file))
            let aim = aims[member] ?? ""
            if value == "false" {
                #expect(Self.siblingLocals(in: body).contains(aim),
                        "“\(member)” declines to move the focus while acting on “\(aim)”, which is not a sibling it resolved — a verb the user aimed at a pane must say so, or ⌘W stays pointed at the pane they are not looking at")
            } else {
                #expect(value == "!mirrored",
                        "“\(member)” opts out of the focus door conditionally on “\(value)” — the only conditional opt-out this rule knows is a caller's mirror flag")
                let signature = Self.matches(#"func \#(member)\(([^)]*)\)"#, in: extensionBody, group: 1)
                #expect(signature.first?.contains("mirrored: Bool = false") == true,
                        "“\(member)” opts out on `!mirrored` but does not take `mirrored` defaulting to false, so its ordinary callers may be opting out too")
            }
        }
    }

    /// Every pane pair read in the tabs file is narrowed by the one door, or by a member asserted
    /// to want both sides. The invariant in `theOneDoorAims…` covers only `tabAction`'s body, so
    /// hand-written `isLeft ? leftX : rightX` cuts of the location pairs elsewhere in the file go
    /// unseen. The ban is stated over the pair: a token from either half may appear only inside a
    /// `PaneSideChoice.own(…)` call, on the line declaring a stored property named for one side, or
    /// inside one of two members that legitimately read both. Each exemption must still exist and
    /// hold a pair token, so it can't outlive its code and become a named hole. This sees the
    /// ternary, the `if isLeft { … } else { … }` and any other shape; sides transposed inside the
    /// `own(…)` call are `everyPaneSideChoiceCallNarrowsAMatchedPair`'s half.
    @Test func everyPaneLocationPairIsNarrowedByTheOneDoorOrAnAssertedException() throws {
        let file = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        let pairs = Self.occurrences(
            #"\b(?:left|right)(?:RelativePath|BrowsePath|TreeRoot|ChildrenIndex|ProviderId)\b"#,
            in: file)
        // The current count (26), not a number low enough to be safe. The floor only asks "am I
        // reading the file at all"; the rule below is about the tokens that are there.
        #expect(pairs.count >= 26,
                "\(pairs.count) pane-pair tokens found in the tabs file where 26 are expected — the scan is reading the wrong text and every judgement below is vacuous")

        let narrowings = Self.callSpans(of: "PaneSideChoice.own(", in: file)
        #expect(narrowings.count >= 6,
                "\(narrowings.count) `PaneSideChoice.own` calls in the tabs file where at least 6 are expected — the pairs are being narrowed somewhere this cannot see")

        // The two that read both sides on purpose, each proved non-vacuous below: the adopt helper
        // writes one id and re-keys the ignored-items store on the pair, and the persistence
        // modifier watches all six values because either pane moving must save that pane's strip.
        var exemptions: [(name: String, span: Range<String.Index>)] = []
        for (name, declaration, closing) in
                [("adoptProviderForTab", "func adoptProviderForTab(", "\n    }\n"),
                 ("BrowseTabPersistence", "struct BrowseTabPersistence: ViewModifier {", "\n}\n")] {
            let start = try #require(file.range(of: declaration),
                                     "“\(name)” is exempted from this rule and is no longer in the file — the exemption is a name that could be hiding a hand-written narrowing")
            let rest = file[start.upperBound...]
            let end = try #require(rest.range(of: closing), "“\(name)” never closes")
            let span = start.lowerBound..<end.upperBound
            #expect(pairs.contains { span.contains($0.lowerBound) },
                    "“\(name)” is exempted as a member that reads both sides and now reads neither — a stale exemption")
            exemptions.append((name, span))
        }

        var loose: [String] = []
        for hit in pairs {
            if narrowings.contains(where: { $0.contains(hit.lowerBound) }) { continue }
            if exemptions.contains(where: { $0.span.contains(hit.lowerBound) }) { continue }
            // A stored property named for one side of a pair its owner is handed (`let
            // leftTreeRoot: String`). The declaration is not a narrowing and can't be transposed;
            // its uses are what this rule is about.
            let lineStart = file[..<hit.lowerBound].lastIndex(of: "\n").map { file.index(after: $0) }
                ?? file.startIndex
            let lineEnd = file[hit.upperBound...].firstIndex(of: "\n") ?? file.endIndex
            let line = String(file[lineStart..<lineEnd])
            if line.range(of: #"^\s*let (?:left|right)\w+: \w+$"#, options: .regularExpression) != nil {
                continue
            }
            loose.append(line.trimmingCharacters(in: .whitespaces))
        }
        #expect(loose.isEmpty,
                "a pane pair is narrowed to a side by hand at \(loose) — transposing it is invisible to every argument check in this suite, and for the location pair it opens tabs with their columns flattened, saves the sibling's folder as this pane's, or prunes one pane's column stack against the other's tree")
    }

    /// Every `PaneSideChoice.own` call in the app target hands it a matched pair, on the side it
    /// says. A per-argument check passes
    /// `own(isLeft, left: syncManager.leftRelativePath, right: syncManager.rightBrowsePath)`,
    /// since each argument has its own side's word, yet it returns a folder for one side and a
    /// column stack for the other; blanking the side word makes that comparable. `PaneSideChoice`
    /// is used app-wide (`CompareReviewReducer`, `DuplicateReviewCoordinator`), so the whole of
    /// `MacApp/**` is walked and the known users must be in the derived set.
    @Test func everyPaneSideChoiceCallNarrowsAMatchedPair() throws {
        let macApp = macAppDirectory()
        let hostFiles = Self.swiftFiles(under: macApp)
        #expect(hostFiles.count > 20,
                "the host walk found \(hostFiles.count) Swift files — it is reading the wrong folder, or the enumerator yielded nothing")

        var users: Set<String> = []
        var narrowings: [(file: String, call: SideNarrowing?)] = []
        for url in hostFiles {
            let code = sourceCodeOnly(try String(contentsOf: url, encoding: .utf8))
            guard code.contains("PaneSideChoice.") else { continue }
            users.insert(url.lastPathComponent)
            for call in Self.sideNarrowings(in: code) {
                narrowings.append((url.lastPathComponent, call))
            }
        }
        // The derivation found the users it must find, or the loop below is satisfied by reading
        // nothing at all.
        #expect(users.isSuperset(of: ["ContentView+PaneTabs.swift", "CompareReviewReducer.swift",
                                      "DuplicateReviewCoordinator.swift"]),
                "the derivation found \(users.sorted()) as the users of `PaneSideChoice` and is missing one that plainly uses it — it is reading the wrong tree")
        #expect(narrowings.count >= 6,
                "\(narrowings.count) `PaneSideChoice.own` calls found across the app target where at least 6 are expected — the checks below are vacuous")
        // …and a known call site is in the set, read whole. It wraps over two lines and nests a
        // call inside its argument, which a regex can't read.
        #expect(narrowings.contains { $0.call?.left == "syncManager.leftChildrenIndex(treeRoot: root)" },
                "the column-stack prune's children-index narrowing is not in the derived set — a call this scan cannot read is a call whose sides may be swapped with nothing to say so")

        for (file, call) in narrowings {
            let call = try #require(call,
                                    "a `PaneSideChoice.own` call in \(file) is written in a shape this scan cannot read — it may have its sides swapped and nothing would say so")
            #expect(call.choice == "isLeft",
                    "“\(file)” narrows a pair on “\(call.choice)” rather than on the side its member was given")
            #expect(call.left.lowercased().contains("left") && !call.left.lowercased().contains("right"),
                    "“\(file)” hands the RIGHT pane's “\(call.left)” to `left:` — the pane a verb was aimed at would read its sibling's")
            #expect(call.right.lowercased().contains("right") && !call.right.lowercased().contains("left"),
                    "“\(file)” hands the LEFT pane's “\(call.right)” to `right:` — the pane a verb was aimed at would read its sibling's")
            #expect(Self.sideStemmed(call.left) == Self.sideStemmed(call.right),
                    "“\(file)” narrows a MISMATCHED pair — `left: \(call.left)` and `right: \(call.right)` are halves of two different pairs, so one pane's answer is assembled out of two questions")
        }
    }

    /// The fixture for the pair reader. Handed known text, because the production file is (and
    /// must stay) correct, and a scan proved only against correct source has never been seen to
    /// fail.
    @Test func theSideNarrowingScanSeesAMismatchedPair() throws {
        let mismatched = Self.sideNarrowings(
            in: "PaneSideChoice.own(isLeft, left: m.leftRelativePath, right: m.rightBrowsePath)")
        let bad = try #require(mismatched.first ?? nil, "the reader could not parse a one-line call")
        #expect(Self.sideStemmed(bad.left) != Self.sideStemmed(bad.right),
                "a `left:`/`right:` pair drawn from two DIFFERENT pairs reads as matched — the hole a per-argument check cannot see, since each argument contains its own side's word")

        // …and the matched pair it must not flag, wrapped over two lines with a nested call in its
        // argument.
        let wrapped = Self.sideNarrowings(in: """
            PaneSideChoice.own(isLeft, left: m.leftChildrenIndex(treeRoot: root),
                               right: m.rightChildrenIndex(treeRoot: root))
            """)
        #expect(wrapped.count == 1, "a call that wraps or nests parentheses is not read as one call")
        let good = try #require(wrapped.first ?? nil, "the reader could not parse a wrapped call")
        #expect(good.choice == "isLeft" && good.left == "m.leftChildrenIndex(treeRoot: root)"
                && good.right == "m.rightChildrenIndex(treeRoot: root)",
                "the reader split a wrapped call's arguments wrongly — it read \(good)")
        #expect(Self.sideStemmed(good.left) == Self.sideStemmed(good.right),
                "a genuinely matched pair is reported as mismatched, so the check above would fire on correct code and get loosened")

        // A camelCase pair, where the side word is not at the start of the identifier: the stemmer
        // has to blank it there too, or every such pair reads as mismatched.
        #expect(Self.sideStemmed("syncManager.isLoadingLeftTree")
                == Self.sideStemmed("syncManager.isLoadingRightTree"),
                "the stemmer only blanks a leading `left`/`right`, so a mid-identifier pair reads as mismatched")

        // And an unreadable call comes back as `nil` rather than being skipped: "this scan doesn't
        // cover it" is not "there is nothing to cover".
        #expect(Self.sideNarrowings(in: "PaneSideChoice.own(isLeft, first, second)") == [nil],
                "a call in a shape the reader does not understand is silently dropped instead of reported")
    }

    /// A focus move is logged with its cause, and a move that moves nothing says nothing.
    /// `focusedPaneSide` decides whether ⌘W closes a tab or the window, and many strip gestures
    /// move it, so a report of "⌘W closed my window" needs a trace. The silent half keeps the
    /// commonest case, clicking in the pane you're already in, out of the log he audits.
    ///
    /// Read from a `LogCapture` opened before the moves, with reasons unique to this run, since
    /// `Logger.shared` is process-wide and `entries` is a rolled 1000-line window. The move's own
    /// line keeps the silent half honest: a capture that saw nothing fails the count.
    @Test func aFocusMoveIsLoggedWithItsCauseAndANoOpIsNot() async {
        let manager = FileSyncManager.scratch(fileManager: FileManager.default)
        let token = String(UUID().uuidString.prefix(8))

        let log = LogCapture()
        manager.noteFocusedPane(isLeft: false, because: "moved \(token)")
        // The same side again: nothing changes, so nothing may be said.
        manager.noteFocusedPane(isLeft: false, because: "again \(token)")
        let entries = await log.entries
        let window = entries.map(\.message)

        let moved = window.filter { $0.contains("moved \(token)") }
        // Info, the shipped level: at Debug the only record of where ⌘W was aimed is filtered out
        // of every installed copy's log, and this test's forced Debug gate could not see it.
        #expect(entries.filter { $0.message.contains("moved \(token)") }.allSatisfy { $0.level == .info },
                "the focus move is no longer Info, so the shipped log level drops it")
        #expect(moved.count == 1,
                "\(moved.count) lines for one focus move — a move of the pane-scoped chords is unlogged, so a window that closed has no trace of which pane ⌘W was aimed at")
        #expect(moved.first?.contains("the right pane") == true,
                "the line does not name the pane the chords now aim at, which is the whole question it exists to answer")
        #expect(moved.first?.contains("⌘W") == true,
                "the line does not name the chord whose destructive outcome this value decides")
        #expect(!window.contains(where: { $0.contains("again \(token)") }),
                "re-aiming at the pane already focused wrote a line — the log fills with the most ordinary gesture in the strip and buries the moves that explain a window closing")
    }

    /// …and an arrival that does move the pane reloads exactly once, from the host. Which arrivals
    /// reload is `theScanIsGatedOnTheSameRuleTheInvalidationUses` below. Here: `applyTab` must not
    /// ring `refreshSubject` itself, because it runs before the provider id is written and would
    /// load the new tab's path under the old tab's root.
    @Test func theReloadIsDrivenByTheHostAndNotByApplyTab() throws {
        let body = try declarationBody(of: "private func tabAction(isLeft: Bool",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(body.contains("refreshForTabSwitch(movedPane: isLeft)"),
                "a tab switch never reloads — a source change would keep the previous tab's tree")
        let sync = try repoFile("Modules/Sync/Sources/Sync/FileSyncManager+PaneTabs.swift")
        // Sliced on the prefix, not the whole signature, so a growing parameter list doesn't
        // report "applyTab is gone" for a member that is right there.
        let apply = try declarationBody(of: "public func applyTab(_ tab: PaneTab, isLeft: Bool", in: sync)
        let applyCode = sourceCodeOnly(apply)
        #expect(!applyCode.contains("syncPathsFromHistory()") && !applyCode.contains("refreshSubject"),
                "applyTab rings the refresh itself — it runs before the provider id is written")
    }

    // MARK: ⌘W, which replaced File ▸ Close

    /// ⌘W on a pane's last tab closes the window, as Finder does, so ⌘W keeps meaning "get rid of
    /// this". `PaneTabList.close(at:)` refuses the last tab, so losing this branch throws nothing
    /// and empties nothing: ⌘W silently does nothing on a one-tab window, the state every install
    /// starts in. Distinct from `CloseTabCommand`'s fallback
    /// (`closeFallsBackToTheWindowWhenNoTabIsPublished`), which is ⌘W in a window with no tabs.
    @Test func closingTheLastTabClosesTheWindowInsteadOfDoingNothing() throws {
        let body = sourceCodeOnly(try declarationBody(of: "func closeTab(id: UUID, isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        let gate = try #require(body.range(of: "guard syncManager.paneTabs(isLeft: isLeft).count > 1 else {"),
                                "the last-tab branch is gone — ⌘W on a one-tab window now does nothing")
        let rest = String(body[gate.upperBound...])
        let close = try #require(rest.range(of: "NSApp.keyWindow?.performClose(nil)"),
                                 "the last tab no longer closes its window")
        let verb = try #require(rest.range(of: "tabAction(isLeft: isLeft)"),
                                "closeTab no longer runs a tab verb at all")
        // Nesting, not just order: an unconditional `performClose` moved below the branch is
        // still before the verb, and every ⌘W would close the window. The branch's closing brace
        // sits at member-body indentation, so its absence ahead of the close proves the close is
        // still inside it.
        #expect(close.upperBound < verb.lowerBound,
                "the window close comes after the tab verb, so ⌘W closes the tab and the window")
        let branch = String(rest[..<close.lowerBound])
        #expect(!branch.contains("\n        }"),
                "the guard's branch has already closed — the window close is unconditional, so every ⌘W closes the window whether the pane has one tab or five")
        // And the line names the pane. This is the feature's one destructive outcome, and a ⌘W
        // aimed at the pane the user wasn't looking at is the bug `noteWorkingIn` guards against,
        // so which pane the press landed in is the question this line has to answer.
        #expect(branch.contains("PaneSideChoice.name(isLeft)"),
                "the line that closes the window does not say which pane's ⌘W did it")
        #expect(branch.contains("\\(closing)"),
                "the line that closes the window does not say which tab was aimed at")
        // …and the branch returns. Falling through would ask the list to close a tab it refuses to
        // close, on a window already going: harmless only because of that refusal.
        #expect(textBetween(rest, from: close.upperBound, to: verb.lowerBound)?.contains("return") == true,
                "the last-tab branch closes the window and then goes on to close a tab as well")
    }

    // MARK: The launch restore

    /// The restore arms the suppression counter like every other adopt. The bootstrap guard is no
    /// substitute: SwiftUI evaluates `onChange` on the next view update, and the bootstrap's tail
    /// lowers `isBootstrappingProviders` synchronously right after these restores, so the write
    /// arrives with the guard already down and the user-switch path's re-home would wipe the pane
    /// back to its root over the strip just restored. (A write with an `await` before the guard
    /// drops, as in `applyProviderSelection`, is protected.) The counter can't strand, because the
    /// handler consumes counters before testing the guard
    /// (`aSuppressionCounterIsConsumedWhereverItsWriteLands`).
    @Test func theLaunchRestoreArmsTheSuppressionCounterLikeEveryOtherAdopt() throws {
        let body = try declarationBody(of: "func restoreBrowseTabs(isLeft: Bool)",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(body.contains("adoptProviderForTab(adopt, isLeft: isLeft"),
                "the launch restore writes the provider id its own way again")
        // Threaded, not hardcoded: the restore runs for both panes, and a right pane that adopted
        // no source would reopen every tab under whichever provider it happened to be on, showing
        // the right folder path under the wrong root.
        for side in ["leftProviderId", "rightProviderId"] {
            #expect(!sourceCodeOnly(body).contains("\(side) = active.providerId"),
                    "the bare \(side) write is back, and the bootstrap guard does not stop it")
        }
    }

    /// The restore is behind "reopen the last folder". Someone who turned that off wants the app to
    /// start at the root, not five tabs of where they were. Both mutations are silent: without the
    /// guard tabs come back for someone who asked for none, and inverted they come back for nobody,
    /// and the first save overwrites the strip. Pinned as the exact literal, so
    /// `guard !GeneralSettings…` fails rather than matching a looser check.
    @Test func theLaunchRestoreObeysTheReopenTheLastFolderSetting() throws {
        let body = sourceCodeOnly(try declarationBody(of: "func restoreBrowseTabs(isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        let gate = try #require(body.range(of: "guard GeneralSettings.shouldRestoreLastFocus() else { return }"),
                                "the restore ignores the reopen-last-folder setting, or tests it inverted")
        let read = try #require(body.range(of: "PaneTabsStore.load(isLeft: isLeft)"),
                                "the restore no longer reads the stored strip")
        #expect(gate.upperBound < read.lowerBound,
                "the setting is consulted after the strip has already been read and acted on")
    }

    /// The account of the restore is decided in `BrowseTabRestorePlan` and only emitted here.
    /// `BrowseTabRestorePlanTests` runs every branch, including the order of lines, so what's left
    /// for a scan is the glue the planner can't see: the host emits the plan's lines at their
    /// stated levels, installs only what the plan installs, and takes the plan's adoption through
    /// the counter (the test above).
    @Test func theLaunchRestoreExecutesThePlanItWasHanded() throws {
        let body = sourceCodeOnly(try declarationBody(of: "func restoreBrowseTabs(isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        let decide = try #require(body.range(of: "BrowseTabRestorePlan.plan(storedCount:"),
                                  "the restore no longer decides through the tested planner")
        let emit = try #require(body.range(of: "for line in plan.lines"),
                                "the plan's lines are computed and never reach the log")
        #expect(body.contains("case .warning: Logger.shared.warning(line.message)"),
                "a warning line is emitted below warning, where a launch-time loss would not stand out")
        #expect(body.contains("case .info: Logger.shared.info(line.message)"))
        let install = try #require(body.range(of: "guard let restored = plan.install else { return }"),
                                   "the host installs something other than what the plan decided")
        #expect(decide.upperBound < emit.lowerBound && emit.upperBound < install.lowerBound,
                "lines must be emitted after the decision and before the install — the abandoned branch's truthful line rides on the plan being consulted first")
        #expect(body.contains("setPaneTabs(restored, isLeft: isLeft)"),
                "the plan's strip is not what reaches the pane")
    }

    /// Both panes are restored, and the right one is easy to drop: an edit that restores only the
    /// left leaves Compare's right pane seeding one tab every launch.
    @Test func bothPanesAreRestoredAtLaunch() throws {
        let source = sourceCodeOnly(try macAppFile("ContentView.swift"))
        #expect(source.contains("restoreBrowseTabs(isLeft: true)"))
        #expect(source.contains("restoreBrowseTabs(isLeft: false)"),
                "the right pane's strip is never restored, so it seeds one tab every launch")
    }

    /// The swap moves the lists as well as the panes, so what is saved has to move with them, on
    /// both sides. Saving only the left leaves the right's stored strip naming the pane that left,
    /// and the next launch restores half of a swap. Nothing on screen shows it until a relaunch,
    /// so it is pinned here.
    @Test func swappingThePanesSavesBothStrips() throws {
        let body = try declarationBody(of: "func swapPanesAction()", in: macAppFile("ContentView.swift"))
        #expect(body.contains("saveBrowseTabs(isLeft: true)"),
                "a swap leaves the saved strip describing the pane that just left")
        #expect(body.contains("saveBrowseTabs(isLeft: false)"),
                "a swap saves only the left strip, so a relaunch restores half a swap")
    }

    // MARK: The seam

    /// The seam's ⇄ / 🔗 capsule is drawn on top of the strip, over the left pane's ＋ and the
    /// right pane's first chip, so those two edges give it up, and only in Compare: any other edge
    /// would be track given up for nothing, and Browse and the rail have no seam.
    @Test(arguments: [true, false], [true, false])
    func theStripGivesUpOnlyTheEdgeTheSeamControlsSitOn(isLeft: Bool, leading: Bool) {
        let underTheSeam = isLeft != leading
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: isLeft, leading: leading)
                == (underTheSeam ? PaneTabSeam.reserve : 0), "isLeft \(isLeft), leading \(leading)")
        #expect(PaneTabSeam.inset(isCompare: false, isLeft: isLeft, leading: leading) == 0,
                "a single-pane workspace lost strip track to a seam it does not have")
    }

    /// The call-site half: the pane column asks the rule rather than spelling a number.
    @Test func thePaneColumnReservesTheSeamThroughTheRule() throws {
        let tabs = try macAppFile("ContentView+PaneTabs.swift")
        let body = try declarationBody(of: "func seamInset(isLeft: Bool, leading: Bool)", in: tabs)
        #expect(body.contains("PaneTabSeam.inset("), "the seam reserve is spelled by hand")
        let content = try macAppFile("ContentView.swift")
        #expect(content.contains("leadingInset: seamInset(isLeft: isLeft, leading: true)"),
                "the strip is not given the seam reserve")
    }

    /// Pinning is wired, and it saves — a pin that did not survive a quit would be a worse
    /// promise than no pin at all.
    @Test func pinningIsWiredAndPersisted() throws {
        let content = try macAppFile("ContentView.swift")
        #expect(content.contains("onSetPinned: { id, pinned in setTabPinned(pinned, id: id, isLeft: isLeft) }"),
                "the strip's pin action is wired to nothing")
        let body = try declarationBody(of: "func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(body.contains("syncManager.setTabPinned("), "pinning does not reach the manager")
        // The save is the one door's. `setTabPinned` goes through `tabAction` with a `nil` answer,
        // the branch that saves the strip and drives no reload. Both halves are checked here, the
        // routing and the `nil` branch saving; either alone would let a pin stop persisting with
        // this test green.
        #expect(body.contains("tabAction(isLeft: isLeft)"),
                "a pin no longer goes through the one door, so it saves nothing and moves no focus")
        #expect(body.contains("return nil"),
                "a pin claims the pane moved — the one door would then write a provider and drive a reload for a chip that only changed its own state")
        let door = sourceCodeOnly(try declarationBody(of: "private func tabAction(isLeft: Bool",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        let noMove = try #require(door.range(of: "guard let arrived = verb() else {"),
                                  "the one door no longer distinguishes a verb that moved the pane")
        let after = String(door[noMove.upperBound...].prefix(200))
        #expect(after.contains("saveBrowseTabs(isLeft: isLeft)"),
                "the one door's “the pane did not move” branch no longer saves the strip — a pin, an unpin and a reorder all stop surviving a quit")
        // Pinning moves no pane, so it must not pay for a reload.
        #expect(!sourceCodeOnly(body).contains("refreshForTabSwitch"),
                "pinning reloads the tree for nothing")
    }

    /// The File menu, read off the running app rather than out of the source. The test host is the
    /// app, so `NSApp.mainMenu` is what AppKit built from the `.commands` declarations, the one
    /// check that sees what the group replacements produce. A source scan can't see
    /// `CommandGroup(replacing: .saveItem)` failing to remove AppKit's own Close (two items on ⌘W,
    /// one dead), or the tab items landing in the wrong group: Close Tab belongs beside New Tab,
    /// not below Delete.
    @Test func theFileMenuIsInTheRoadmapsOrder() throws {
        let file = try appMenu("File")
        let titles = file.items.map(\.title).filter { !$0.isEmpty }
        // New Text File… leads: ⌘N is the item AppKit's `.newItem` group is named for, and the two
        // "new" items belong together at the top. Open Recent sits under it, where a document app
        // keeps it.
        #expect(titles.prefix(6)
                == ["New Text File…", "Open Recent", "New Folder…", "New Tab", "Close Tab", "Reopen Closed Tab"],
                "the File menu opens with \(titles.prefix(6)) — Fig. 9 puts the tab items with the new-item pair")

        // AppKit's own Close is gone, and exactly one item claims ⌘W. Two would leave one of them
        // dead, and which one AppKit picks is not something this app decides.
        #expect(!titles.contains("Close"), "the standard File ▸ Close is still there beside Close Tab")
        // Close All (⌥⌘W) goes with it, on purpose. It came from the same group, this app is one
        // window plus three utilities, and an ⌥ chord fires through the ⌥-hold reveal, which
        // `AppChordTests` forbids app-wide.
        #expect(!titles.contains("Close All"),
                "Close All is back — it registers an ⌥ chord, which fires through the ⌥-hold reveal")
        let closers = file.items.filter { $0.keyEquivalent == "w" }
        #expect(closers.count == 1, "\(closers.count) items register ⌘W")
        #expect(closers.first?.title == "Close Tab")

        // Close Document sits where AppKit's Close sat, directly above Save, with no key: ⌘W is
        // Close Tab's, and ⌥⌘W would fire through the ⌥-hold reveal. Read off the real menu, so an
        // item in the wrong group, or with a chord, fails here.
        let closeDocument = try #require(titles.firstIndex(of: "Close Document"), "File ▸ Close Document is gone")
        let save = try #require(titles.firstIndex(of: "Save"), "File ▸ Save is gone")
        #expect(closeDocument + 1 == save,
                "the File menu reads \(titles[min(closeDocument, save)...max(closeDocument, save)]) — Close Document belongs directly above Save")
        let closeItem = try #require(file.items.first { $0.title == "Close Document" })
        #expect(closeItem.keyEquivalent.isEmpty, "Close Document has acquired a chord: '\(closeItem.keyEquivalent)'")

        // Reopen Closed Tab has no chord on purpose: ⇧⌘T is the Tab Bar, and an ⌥ chord is the one
        // kind that can fire through the ⌥-hold reveal.
        let reopen = try #require(file.items.first { $0.title == "Reopen Closed Tab" })
        #expect(reopen.keyEquivalent.isEmpty, "Reopen Closed Tab has acquired a chord")

        // Download sits where the row menu puts it, under Quick Look: the row verbs are one group,
        // in the row menu's order, so a reader who knows the right-click finds the same list here.
        // No chord: nothing conventional is free for it.
        let quickLook = try #require(titles.firstIndex(of: "Quick Look"))
        let download = try #require(titles.firstIndex(of: "Download"), "File ▸ Download is gone")
        let reveal = try #require(titles.firstIndex(of: "Reveal in Finder"))
        #expect(quickLook + 1 == download && download + 1 == reveal,
                "the row verbs read \(titles[quickLook...reveal]) — Download belongs between Quick Look and Reveal in Finder")
        #expect(file.items.first { $0.title == "Download" }?.keyEquivalent.isEmpty == true,
                "Download has acquired a chord")

        // Open in Edit leads the row verbs, on ⌘O, as it leads the row context menu. Read off the
        // real menu, which is where the chord a person presses lives.
        let editor = try #require(titles.firstIndex(of: "Open in Edit"), "File ▸ Open in Edit is gone")
        let newTab = try #require(titles.firstIndex(of: "Open in New Tab"))
        #expect(editor + 1 == newTab,
                "the row verbs read \(titles[min(editor, newTab)...max(editor, newTab)]) — Open in Edit belongs first, directly above Open in New Tab")
        let editorItem = try #require(file.items.first { $0.title == "Open in Edit" })
        #expect(editorItem.keyEquivalent == "o", "Open in Edit is on '\(editorItem.keyEquivalent)', not ⌘O")
        #expect(editorItem.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
                "Open in Edit carries modifiers beyond ⌘")

        // And nothing else in the menu bar has taken ⌘O. Two claimants leave one of them dead, and
        // which one AppKit picks is not something this app decides.
        let claimants = try menuItems(claiming: "o", modifiers: .command).map(\.title)
        #expect(claimants == ["Open in Edit"], "⌘O is claimed by \(claimants)")
    }

    /// The View menu's Tab Bar switch, same source: a checkmark item, above the other switches.
    @Test func theViewMenuCarriesTheTabBarSwitch() throws {
        let view = try appMenu("View")
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        let tabBar = try #require(titles.firstIndex(of: "Tab Bar"), "View ▸ Tab Bar is gone")
        let hidden = try #require(titles.firstIndex(of: "Hidden Files"))
        #expect(tabBar < hidden, "Tab Bar sits below the other switches")
        #expect(view.items.first { $0.title == "Tab Bar" }?.keyEquivalent == "t")
        // A noun with a tick, never a Show/Hide pair.
        #expect(!titles.contains { $0.hasPrefix("Show Tab") || $0.hasPrefix("Hide Tab") },
                "the tab bar switch became a Show/Hide pair")
    }

    /// View ▸ Filter by Type: a submenu right after Hidden Files (the two decide which files a pane
    /// shows), with no chord of its own. Registered is not reachable, so this walks
    /// `NSApp.mainMenu`.
    @Test func theViewMenuCarriesFilterByTypeAfterHiddenFiles() throws {
        let view = try appMenu("View")
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        let hidden = try #require(titles.firstIndex(of: "Hidden Files"))
        let filter = try #require(titles.firstIndex(of: "Filter by Type"), "View ▸ Filter by Type is gone")
        #expect(filter == hidden + 1, "Filter by Type sits right after Hidden Files: \(titles)")
        let item = try #require(view.items.first { $0.title == "Filter by Type" })
        #expect(item.submenu != nil, "Filter by Type is a submenu of kinds, not a single command")
        #expect(item.keyEquivalent.isEmpty, "Filter by Type took a chord: \(item.keyEquivalent)")
    }

    // MARK: The right-click routes

    /// The pane's own background menu offers New Tab. It's the only right-click route that works
    /// at one tab: the row menu needs a folder under the pointer and the strip's menu needs a
    /// strip, and neither exists in the state every install starts in.
    @Test func thePaneBackgroundMenuOffersANewTab() throws {
        let shared = try declarationBody(of: "static func tabActions(at path: String, delegate: FileActionDelegate)",
                                         in: repoFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift"))
        #expect(shared.contains("delegate.canOpenInNewTab"), "the item is offered by hosts with no strip")
        #expect(shared.contains("handleNewTab(at: path)"), "New Tab is wired to nothing")
        #expect(shared.contains("delegate.canCloseTab"),
                "Close Tab is offered at one tab, where it would close the window instead")

        // …and both view modes' background menus actually build it.
        for file in ["FileTreeView.swift", "PaneColumnsView.swift"] {
            #expect(try repoFile("Modules/FileExplorer/Sources/FileExplorer/" + file).contains("SharedFileMenuItems.tabActions("),
                    "\(file)'s empty-area menu has no tab items")
        }
    }

    /// Right-clicking the header card offers a new tab. It's the surface a Mac user reaches for to
    /// act on a pane, and the other routes need a folder under the pointer, a strip, or empty space
    /// below the rows, which a full column doesn't have. The bar itself is untouched: no glyph, no
    /// `PaneBarItem`, nothing in the customize sheet.
    @Test func theHeaderCardsMenuOffersANewTab() throws {
        let header = try repoFile("Modules/Dashboard/Sources/Dashboard/DashboardViews.swift")
        let menu = try declarationBody(of: "private func barContextMenu() -> some View {", in: header)
        #expect(menu.contains("Button(\"New Tab\")"), "the header card's menu has no New Tab")
        #expect(menu.contains("Button(\"Close Tab\")"), "the header card's menu has no Close Tab")
        #expect(menu.contains("Customize Pane Bar…"), "the menu lost what it already carried")
        // No chord badges: the pair is registered once in the menu bar, and a `.keyboardShortcut`
        // here would register a second pair — one per pane.
        #expect(!sourceCodeOnly(menu).contains("keyboardShortcut"),
                "the header menu registers its own chords, so ⌘T is claimed twice")

        // …and the call site withholds Close Tab at one tab rather than offering to close the window.
        let content = try macAppFile("ContentView.swift")
        #expect(content.contains("onCloseTab: syncManager.paneTabs(isLeft: isLeft).count > 1"),
                "the header menu offers Close Tab at one tab, where it would close the window")
    }

    /// Open in Edit leads the single-file branch, ahead of Get Info and Reveal in Finder: Edit is a
    /// workspace of this app, the other two hand the file to something else, and this menu is the
    /// one door into Edit shared by Browse, both Compare panes, Organize's rail and Edit's source
    /// pane. `OpenInEditorVerbTests` pins the item's existence and text gate; this pins the order.
    /// Sliced to `FileContextMenu`'s body first, because `SharedFileMenuItems.openInEditor` is
    /// declared above the menu, and a whole-file scan would find the declaration first and call the
    /// order correct whatever the menu does.
    @Test func openInEditLeadsTheRowMenusSingleFileBranch() throws {
        let code = try repoFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let menu = sourceCodeOnly(try declarationBody(of: "struct FileContextMenu: View {", in: code))
        // The region really is the menu, and not an empty or wrongly-sliced one.
        #expect(menu.contains("Label(\"Reveal in Finder\""), "the slice is not FileContextMenu's body")
        #expect(menu.contains("Label(\"Quick Look\""), "the slice is not FileContextMenu's body")

        let editor = try #require(menu.range(of: "SharedFileMenuItems.openInEditor("),
                                  "the row menu no longer offers Open in Edit")
        let getInfo = try #require(menu.range(of: "SharedFileMenuItems.getInfo("),
                                   "the row menu no longer offers Get Info")
        let reveal = try #require(menu.range(of: "Label(\"Reveal in Finder\""))
        #expect(editor.lowerBound < getInfo.lowerBound,
                "Open in Edit sank below Get Info — it is no longer where the eye lands")
        #expect(getInfo.lowerBound < reveal.lowerBound, "Get Info and Reveal in Finder swapped")

        // And it is still gated on the row being a file: leading the menu must not mean offering
        // the editor for a folder, which the verb's own text gate would then silently refuse.
        let lead = String(menu[..<editor.lowerBound].suffix(200))
        #expect(lead.contains("!singleNode.isDirectory"), "a FOLDER is offered to the editor")
    }

    /// Discovery beats tidiness: the row menu's tab item sits above Quick Look, not at the bottom
    /// of the folder branch.
    @Test func openInNewTabSitsAheadOfQuickLook() throws {
        let code = try repoFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let tab = try #require(code.range(of: "Label(\"Open in New Tab\""),
                               "the row menu no longer offers Open in New Tab")
        let quickLook = try #require(code.range(of: "Label(\"Quick Look\""))
        #expect(tab.lowerBound < quickLook.lowerBound,
                "Open in New Tab sank below Quick Look — it is the whole discovery story for tabs")
    }

    // MARK: The row menu's entry point

    /// The discovery route. ⌘T opens the folder you're already in, so this is the only entry point
    /// that makes a second tab somewhere else. Gated on the delegate's own capability like the two
    /// items beside it, and on the row being a folder, because a tab is a location.
    @Test func theRowMenuOffersOpenInNewTabForFoldersOnly() throws {
        let code = try repoFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let item = try #require(code.range(of: "Label(\"Open in New Tab\""),
                                "the row menu no longer offers Open in New Tab")
        // The gate is the lines just above the label: the item sits ahead of Quick Look, outside
        // the folder branch, so it carries its own `isDirectory` test.
        let lead = String(code[..<item.lowerBound].suffix(300))
        #expect(lead.contains("singleNode.isDirectory"), "a FILE can be opened as a tab")
        #expect(lead.contains("delegate.canOpenInNewTab"),
                "Open in New Tab is offered by hosts that have no strip to open a tab in")
        let after = String(code[item.upperBound...].prefix(200))
        #expect(after.contains("handleOpenInNewTab(singleNode)") || lead.contains("handleOpenInNewTab(singleNode)"),
                "Open in New Tab is not wired to the delegate")
    }

    // MARK: The strip stays under the pointer (TE214)

    /// A hold is per pane and ends when asked: the value `paneShowsTabStrip` folds in.
    @Test func aHeldStripIsHeldPerPaneUntilReleased() {
        var hold = PaneTabStripHold()
        #expect(!hold.holds(isLeft: true) && !hold.holds(isLeft: false))
        hold.hold(isLeft: true)
        #expect(hold.holds(isLeft: true))
        #expect(!hold.holds(isLeft: false), "holding the left strip held the right one too")
        hold.release(isLeft: true)
        #expect(!hold.holds(isLeft: true))
    }

    @Test func thePointerIsTrackedPerStrip() {
        let pointer = PaneTabStripPointer()
        pointer.setOver(true, isLeft: false)
        #expect(pointer.isOver(isLeft: false))
        #expect(!pointer.isOver(isLeft: true))
        pointer.setOver(false, isLeft: false)
        #expect(!pointer.isOver(isLeft: false))
    }

    /// The hold is wired where it acts: both panes' terms of the visibility rule fold it in (so in
    /// Compare a held strip keeps its sibling's up, as two tabs would); the strip's close and Close
    /// Others go through the hold; the strip reports the pointer and lets a held strip go when it
    /// leaves; and a close from anywhere else (⌘W) releases it first. The value tests above pass
    /// with every one of these lines reverted.
    @Test func theHoldIsWiredWhereItActs() throws {
        let tabs = try macAppFile("ContentView+PaneTabs.swift")
        let shows = try declarationBody(of: "func paneShowsTabStrip(isLeft: Bool) -> Bool {", in: tabs)
        #expect(shows.contains("showsStrip || tabStripHold.holds(isLeft: isLeft)"),
                "this pane's strip no longer counts a hold — closing to one tab jumps the header under the pointer")
        #expect(shows.contains("showsStrip || tabStripHold.holds(isLeft: sibling)"),
                "the sibling's hold is not counted — in Compare the other pane's strip goes and its header jumps")
        let close = try declarationBody(of: "func closeTab(id: UUID, isLeft: Bool) {", in: tabs)
        let release = try #require(close.range(of: "tabStripHold.release(isLeft: isLeft)"),
                                   "a keyboard close no longer lets a held strip go")
        let guardLine = try #require(close.range(of: "guard syncManager.paneTabs(isLeft: isLeft).count > 1"))
        #expect(release.lowerBound < guardLine.lowerBound, "the release comes after the last-tab guard returns")
        let content = try macAppFile("ContentView.swift")
        let column = try declarationBody(of: "func paneColumn(isLeft: Bool) -> some View {", in: content)
        #expect(column.contains("onClose: { id in holdingTabStrip(isLeft: isLeft) { closeTab(id: id, isLeft: isLeft) } }"),
                "the strip's close button closes without the hold")
        #expect(column.contains("holdingTabStrip(isLeft: isLeft) { closeOtherTabs(keeping: id, isLeft: isLeft) }"),
                "the strip's Close Other Tabs closes without the hold")
        #expect(column.contains("tabStripPointer.setOver(inside, isLeft: isLeft)"),
                "the strip no longer reports the pointer, so no click ever holds it")
        #expect(column.contains("if !inside, tabStripHold.holds(isLeft: isLeft) { tabStripHold.release(isLeft: isLeft) }"),
                "the pointer leaving no longer lets a held strip go — it would stay until the next close")
        #expect(column.contains(".designAnimation(.easeOut(duration: 0.18), value: paneShowsTabStrip(isLeft: isLeft))"),
                "the strip's coming and going is no longer animated on its presence — a released strip would vanish, not slide")
        // It slides in: ⌘T opens the folder you're already in, so the strip's arrival is the only
        // feedback, and an abrupt one reads as a glitch.
        #expect(column.contains(".transition(.move(edge: .top)"),
                "the strip appears with no transition — nothing marks the arrival ⌘T is fed back by")
    }

    /// Where a right-click menu stood (top-left at the click, moved on-screen as AppKit moves one
    /// at the edges) is the area a Close Tab chosen from it holds the strip for.
    @Test func aMenusAreaIsWhereItOpenedMovedOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 200, height: 300)
        #expect(PaneMenuOrigin.estimatedFrame(origin: NSPoint(x: 100, y: 700), size: size, visible: visible)
                == NSRect(x: 100, y: 400, width: 200, height: 300))
        #expect(PaneMenuOrigin.estimatedFrame(origin: NSPoint(x: 900, y: 700), size: size, visible: visible).maxX == 1000,
                "a menu opened near the right edge was placed off the screen")
        #expect(PaneMenuOrigin.estimatedFrame(origin: NSPoint(x: 100, y: 100), size: size, visible: visible).minY == 0,
                "a menu opened near the bottom was placed off the screen")
    }

    /// Only a menu up or just closed counts, and the point the item was chosen at is inside the
    /// area even where AppKit drew the menu elsewhere than estimated.
    @Test func aMenuCountsOnlyWhileUpOrJustClosed() throws {
        let origin = PaneMenuOrigin()
        let point = NSPoint(x: 150, y: 600)
        #expect(origin.justChosenArea(at: point) == nil, "an area with no menu ever opened")
        origin.menuOpened(size: NSSize(width: 200, height: 300), at: NSPoint(x: 100, y: 700), visible: nil)
        #expect(origin.justChosenArea(at: point)?.contains(point) == true, "the menu is up and its area is gone")
        let closed = Date()
        origin.menuClosed(now: closed)
        #expect(origin.justChosenArea(at: point, now: closed.addingTimeInterval(0.5)) != nil,
                "the item's action, sent just after the menu went, found no area")
        #expect(origin.justChosenArea(at: point, now: closed.addingTimeInterval(PaneMenuOrigin.freshness + 0.5)) == nil,
                "a menu closed long ago still holds strips")
        origin.menuOpened(size: NSSize(width: 200, height: 300), at: NSPoint(x: 100, y: 700), visible: nil)
        let far = NSPoint(x: 600, y: 100)
        #expect(try #require(origin.justChosenArea(at: far)).contains(far),
                "the point the item was chosen at is outside the area")
    }

    /// The header's and a row's Close Tab go through the hold, as the strip's own do.
    @Test func theMenuClosesGoThroughTheHold() throws {
        let content = try macAppFile("ContentView.swift")
        let column = try declarationBody(of: "func paneColumn(isLeft: Bool) -> some View {", in: content)
        #expect(CodeText(column).contains("? { holdingTabStrip(isLeft: isLeft) {\n closeTab(id: syncManager.paneTabs(isLeft: isLeft).active.id"),
                "the header menu's Close Tab closes without the hold")
        let delegate = try declarationBody(of: "func paneActionDelegate(for pane: PaneContext) -> PaneActionDelegate {", in: content)
        #expect(delegate.contains("onCloseTab: { holdingTabStrip(isLeft: pane.isLeft) {"),
                "the row menu's Close Tab closes without the hold")
        let hold = try declarationBody(of: "private func holdingTabStrip(isLeft: Bool, _ close: () -> Void) {", in: content)
        #expect(hold.contains("PaneMenuOrigin.shared.justChosenArea"), "a menu's close is never held")
        #expect(hold.contains("PaneMenuOrigin.shared.watch("), "a strip held for a menu is never let go")
    }

    // MARK: Compare — both panes wear the strip

    /// The term that makes Compare readable: a second tab on either pane draws the strip on both.
    /// Without it the pane that grew the tab has its header pushed 34pt down, and every row after
    /// it names a different folder on the left than on the right.
    @Test func inCompareOnePanesSecondTabDrawsBothStrips() {
        #expect(PaneTabStripVisibility.shows(own: false, sibling: true, isCompare: true, switchIsOn: false),
                "the sibling grew a second tab and this pane drew nothing — the two rows are now offset")
        #expect(PaneTabStripVisibility.shows(own: true, sibling: false, isCompare: true, switchIsOn: false),
                "the pane with the tabs does not draw its own strip")
    }

    /// …and the other direction, which costs a 34pt row if it goes wrong. Browse and the
    /// single-source rail have no sibling on screen, so the sibling's list must not reach them: the
    /// right pane's list exists in both, it just isn't shown.
    @Test func outsideCompareTheSiblingsTabsDrawNothing() {
        #expect(!PaneTabStripVisibility.shows(own: false, sibling: true, isCompare: false, switchIsOn: false),
                "Browse drew a strip because the hidden right pane has two tabs")
        #expect(!PaneTabStripVisibility.shows(own: false, sibling: false, isCompare: true, switchIsOn: false),
                "a strip is drawn with one tab on each side and the switch off")
        #expect(PaneTabStripVisibility.shows(own: false, sibling: false, isCompare: false, switchIsOn: true),
                "View ▸ Tab Bar no longer shows the strip")
    }

    /// The call-site half: the rule is fed the sibling's list and the layout, not just this pane's.
    /// Reading `paneTabs(isLeft: isLeft)` twice would pass every rule test above and still ship the
    /// offset rows.
    @Test func theStripGateAsksBothPanes() throws {
        let rule = try declarationBody(of: "func paneShowsTabStrip(isLeft: Bool) -> Bool",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(rule.contains("PaneTabStripVisibility.shows("),
                "the gate is built by hand — the tested rule is unused")
        // Through the one flip, like every other reach for the sibling in the tabs file; the local
        // it binds is read off the member rather than spelled here.
        let sibling = try #require(Self.siblingLocals(in: rule).first,
                                   "the gate flips the side by hand instead of through `PaneSideChoice.sibling`, where a test can drive the polarity")
        #expect(rule.contains("paneTabs(isLeft: \(sibling)).showsStrip"),
                "the gate never asks the sibling pane, so Compare's two rows can sit at different heights")
        #expect(rule.contains("layoutMode == .compare"),
                "the gate does not restrict the sibling term to Compare")
        #expect(rule.contains("tabBarVisible"), "View ▸ Tab Bar no longer shows the strip")
    }

    // MARK: Compare — a linked pane opens the tab too

    /// The mirror lands on the deepest folder the sibling really has. A tab naming a folder that
    /// pane doesn't carry is a chip that can't be navigated to, and the sides are being compared
    /// because they differ.
    @Test func aMirroredTabIsPrunedToWhatTheSiblingHas() {
        let has: Set<String> = ["Photos", "Photos/2024"]
        #expect(PaneTabMirror.landing(for: "Photos/2024") { has.contains($0) } == "Photos/2024",
                "a folder the sibling has in full was still pruned")
        #expect(PaneTabMirror.landing(for: "Photos/2024/June") { has.contains($0) } == "Photos/2024",
                "the mirror did not stop at the deepest shared folder")
        #expect(PaneTabMirror.landing(for: "Taxes/2024") { has.contains($0) } == "",
                "a folder the sibling shares nothing of did not fall back to its root")
        #expect(PaneTabMirror.landing(for: "") { _ in true } == "",
                "the root mirrored as something other than the root")
    }

    /// A folder missing halfway down must not be walked past: pruning stops, it doesn't skip. The
    /// fixture is the whole test. A sibling holding `Photos` and `Photos/2024/June` can't tell the
    /// two apart, since a skipping walk then asks about `Photos/June`, which is missing too. This
    /// sibling does have `Photos/June`, so a skipping walk assembles a path out of two folders that
    /// aren't parent and child.
    @Test func theMirrorStopsAtTheFirstMissingFolder() {
        let has: Set<String> = ["Photos", "Photos/June"]
        #expect(PaneTabMirror.landing(for: "Photos/2024/June") { has.contains($0) } == "Photos",
                "the walk skipped a missing folder and landed on a path with a hole in it")
    }

    /// Both entry points mirror, and both go through the one predicate.
    @Test func bothWaysOfOpeningATabMirrorOntoTheLinkedPane() throws {
        let code = sourceCodeOnly(try macAppFile("ContentView+PaneTabs.swift"))
        let here = try declarationBody(of: "func openNewTabHere(isLeft: Bool)", in: code)
        #expect(here.contains("guard tabsOpenOnBothPanes else { return }"),
                "⌘T and the ＋ do not open a tab on the linked pane")
        // Through the one flip, like the other mirror (see `PaneSideChoice.sibling`). Which local
        // it binds is read off the member rather than spelled here.
        let hereSibling = try #require(Self.siblingLocals(in: here).first,
                                       "the mirrored ⌘T does not take its side through `PaneSideChoice.sibling`, so the flip is back in a `ContentView` extension where no test can drive it")
        #expect(here.contains("openTabHere(isLeft: \(hereSibling), mirrored: true)"),
                "the mirrored ⌘T does not target the other pane")

        let openThere = try declarationBody(of: "func openInNewTab(absolutePath: String, isLeft: Bool)", in: code)
        #expect(openThere.contains("mirrorOpenInNewTab(relative, from: isLeft)"),
                "Open in New Tab does not mirror onto the linked pane")

        let mirror = try declarationBody(of: "private func mirrorOpenInNewTab(", in: code)
        #expect(mirror.contains("guard tabsOpenOnBothPanes else { return }"),
                "the mirror runs unlinked, or in Browse, where there is no sibling")
        #expect(mirror.contains("PaneTabMirror.landing("),
                "the mirror copies the path outright instead of pruning it")
        #expect(mirror.contains("expandingTildeInPath"),
                "the sibling's root is compared unexpanded, so every mirror prunes to its root")
        // And this mirror takes its side the same way ⌘T's does: a hand-written `!` here would open
        // both tabs of an ⌥/linked Open in New Tab on the pane the user aimed at, with the app
        // suite green.
        let mirrorSibling = try #require(Self.siblingLocals(in: mirror).first,
                                         "the mirror flips the side by hand instead of through `PaneSideChoice.sibling` — dropping the `!` is a measured survivor of the whole suite")
        #expect(mirror.contains("tabAction(isLeft: \(mirrorSibling), movesFocus: false)"),
                "the mirror opens its tab on a pane other than the sibling it just resolved")
    }

    // MARK: What the launch sequence may not overwrite

    /// The save must refuse during the provider bootstrap. Launch points the pane at its stored
    /// folder and then reads the stored strip; the first move fires the persistence `onChange`
    /// while the pane still holds a fresh one-tab list, so a save in between overwrites the user's
    /// whole strip with a single tab and the restore reads back what it destroyed. Whether that
    /// happens depends on when SwiftUI runs an update across the `await` between the two steps,
    /// which is not a thing to leave to timing.
    @Test func theStripIsNotSavedWhileTheProvidersAreStillBootstrapping() throws {
        let rule = try declarationBody(of: "func saveBrowseTabs(isLeft: Bool)",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(rule.contains("!isBootstrappingProviders"),
                "a save during launch can overwrite the stored strip before the restore reads it")
        // And it must not refuse the right pane: a `guard isLeft` here kills right-pane
        // persistence while every store test stays green, since they call the store directly.
        // Negative, so it goes through `codeOnly`.
        #expect(!sourceCodeOnly(rule).contains("guard isLeft"),
                "the save refuses the right pane again, so its strip is never written")
    }

    /// The save writes the live pane over the active entry, through a rule that can be tested. The
    /// active entry is a snapshot from when that tab was last parked (see `PaneTab`), so a strip
    /// written straight off the list saves the tab on screen at the folder it was opened at, and
    /// the active tab loses its columns across a quit. The overlay is
    /// `PaneTabList.replacingActive`, unit-tested in `PaneTabsTests`; this is the half a value
    /// can't state: the host calls it with the pane's own three values and hands the store the
    /// result, not the list.
    @Test func theSaveWritesTheLivePaneOverTheActiveEntryThroughTheRule() throws {
        let save = sourceCodeOnly(try declarationBody(of: "func saveBrowseTabs(isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        #expect(save.contains("replacingActive("),
                "the save writes the list's own stale active entry — the tab on screen is stored where it was parked")
        // All three parts of where the pane is, and the two paths separately: `PaneTabsStore`
        // records the cut between scope and stack as a depth, so an entry rebuilt from the joined
        // path reports a depth of zero and the columns flatten one layer down. Each through its own
        // narrowing wrapper, since a transposed path would store the sibling pane's folder or
        // column stack as this pane's active tab.
        for value in ["providerId: paneProviderId(isLeft: isLeft)",
                      "relativePath: paneScope(isLeft: isLeft)",
                      "browsePath: paneStack(isLeft: isLeft)"] {
            #expect(save.contains(value), "the save does not hand the rule the pane's own \(value)")
        }
        // …and what goes to disk is the overlaid strip, not the one it was built from: passing the
        // un-overlaid list would satisfy every presence above. This positive pins the whole
        // argument, so any other value in it fails.
        #expect(save.contains("PaneTabsStore.save(tabs: saving.tabs"),
                "the overlaid strip is built and then not the one that is saved")
    }

    /// One body serves both panes, so every side-dependent call inside it must thread `isLeft`. A
    /// hardcoded side is this feature's worst and quietest failure: the app compiles, the package
    /// suite is green (it calls `PaneTabsStore` directly), and nothing looks wrong until a
    /// relaunch. A save pinned to `true` makes every right-pane move overwrite the left pane's
    /// stored strip; a `setPaneTabs`/`applyTab` pinned to `true` installs the right pane's tabs on
    /// the left at launch. Pinned both ways: the threading is present and the literals are absent,
    /// since either alone can pass while the other is broken.
    @Test func theSaveAndRestoreThreadTheirSideRatherThanHardcodingIt() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        let save = sourceCodeOnly(try declarationBody(of: "func saveBrowseTabs(isLeft: Bool)", in: source))
        let restore = sourceCodeOnly(try declarationBody(of: "func restoreBrowseTabs(isLeft: Bool)",
                                                        in: source))

        #expect(save.contains("PaneTabsStore.save(") && save.contains("isLeft: isLeft"),
                "the save does not pass its own side to the store")
        #expect(restore.contains("applyTab(restored.active, isLeft: isLeft"),
                "the restored tab is applied to a fixed pane")

        for (name, body) in [("saveBrowseTabs", save), ("restoreBrowseTabs", restore)] {
            #expect(!body.contains("isLeft: true") && !body.contains("isLeft: false"),
                    "\(name) hardcodes a side, so one pane acts on the other's state")
        }
    }

    /// The source is part of where a tab is, and it moves without either path moving: switching
    /// source at the root leaves the history default, the stack empty and the path `""`, so neither
    /// path `onChange` fires. Unwatched, the stored entry keeps naming the old source, and because
    /// the restore writes the tab's provider over `selectedLeftProviderId`, the next launch undoes
    /// the switch.
    @Test func theSavedStripFollowsTheSourceAndNotOnlyThePath() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        let modifier = try declarationBody(of: "struct BrowseTabPersistence: ViewModifier {", in: source)
        #expect(modifier.contains("onChange(of: leftProviderId)"),
                "a source switch at the root is never saved, so the next launch reopens the old one")
        #expect(modifier.contains("onChange(of: syncManager.leftRelativePath)"),
                "the scope is no longer watched")
        #expect(modifier.contains("onChange(of: syncManager.leftBrowsePath)"),
                "the column stack is no longer watched")

        // The same three for the right pane, which is persisted too. Watching only the left would
        // leave the right strip written by tab verbs but never by navigation, so it would come back
        // at the folder its tabs were opened at rather than where they were left.
        #expect(modifier.contains("onChange(of: rightProviderId)"),
                "a right-pane source switch at the root is never saved")
        #expect(modifier.contains("onChange(of: syncManager.rightRelativePath)"),
                "the right pane's scope is not watched")
        #expect(modifier.contains("onChange(of: syncManager.rightBrowsePath)"),
                "the right pane's column stack is not watched")

        // …and the call site feeds it: a modifier watching a value nobody passes watches nothing.
        let callSite = try macAppFile("ContentView.swift")
        #expect(callSite.contains("leftProviderId: leftProviderId"),
                "BrowseTabPersistence is built without the source it watches")
        #expect(callSite.contains("rightProviderId: rightProviderId"),
                "BrowseTabPersistence is built without the right pane's source")
        // And its callback saves the side that moved. A call site that ignores which pane changed
        // and saves a fixed side puts every right-pane move into the left pane's stored strip, and
        // six correct `onChange`s above can't catch one wrong closure here.
        #expect(sourceCodeOnly(callSite).contains("saveBrowseTabs(isLeft: $0)"),
                "the persistence callback ignores which pane moved and saves a fixed side")
    }

    // MARK: The scan a tab switch does not run

    /// A tab switch inside one source at one scope reloads nothing and rescans nothing. The trees
    /// walk one root at one focus and the differences concern one pair of focused folders, so a
    /// switch that changes neither leaves both correct; refreshing is the Refresh button's job,
    /// just as drilling through columns doesn't rescan. Both halves must ask one rule: the manager
    /// uses it to decide whether to drop the trees and comparison, the host whether to scan. Two
    /// copies could invalidate without reloading, leaving a pane with no tree and no scan until
    /// Refresh.
    @Test func theScanIsGatedOnTheSameRuleTheInvalidationUses() throws {
        let host = try declarationBody(of: "private func tabAction(isLeft: Bool, movesFocus: Bool = true, _ verb: () -> PaneTab?)",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(host.contains("PaneTabArrival.needsReload("),
                "the host rescans on every tab switch, or decides with its own copy of the rule")
        let gate = try #require(host.range(of: "PaneTabArrival.needsReload("))
        let refresh = try #require(host.range(of: "refreshForTabSwitch(movedPane:"),
                                   "the reload is gone entirely — a source switch would never load")
        #expect(gate.lowerBound < refresh.lowerBound, "the gate does not guard the reload")

        // Captured before the verb runs, because the verb moves the pane: read afterwards, the
        // "from" focus is the arriving tab's and the rule says "no reload" for every switch,
        // including source changes that need one. Asserted as an order, since a presence check
        // passes with the read moved below `verb()`.
        let read = try #require(host.range(of: "let fromFocus = paneScope(isLeft: isLeft)"),
                                "the pane's focus before the switch is never captured")
        let verb = try #require(host.range(of: "verb() else {"), "the verb call is gone")
        #expect(read.upperBound < verb.lowerBound,
                "the focus is read after the pane has already moved, so the rule always says no")
    }

    /// The prune must also fire when a pane finishes loading, not only when its tree changes.
    /// `pruneBrowsePath` refuses while a tree is loading, because progressive loading publishes a
    /// shallow root-children tree first and pruning against it cuts a valid stack to one
    /// component. The deep tree is published before `await applyFilters()` and the flag is cleared
    /// after it, so the final tree's update can arrive with the flag still up; the republish
    /// handler skips and nothing re-fires it, and an externally deleted folder keeps its dead
    /// stack. The falling edge closes that whichever side of the `await` a SwiftUI update lands on.
    @Test func theStackIsAlsoPrunedWhenAPaneFinishesLoading() throws {
        let body = try declarationBody(of: "struct ColumnStackPruning: ViewModifier {",
                                     in: macAppFile("ContentView+PaneTabs.swift"))
        for flag in ["isLoadingLeftTree", "isLoadingRightTree"] {
            let handler = try #require(body.range(of: "onChange(of: syncManager.\(flag))"),
                                       "nothing prunes \(flag)'s pane when it settles")
            // Sliced to this handler's own closure, not a fixed window, which would reach into the
            // next handler and find its guard instead.
            let rest = body[handler.upperBound...]
            let end = rest.range(of: "\n            .onChange") ?? rest.range(of: "\n    }")
            let own = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
            #expect(own.contains("guard !isLoading else { return }"),
                    "the \(flag) handler prunes on the RISING edge too, against a tree still loading")
            #expect(own.contains("prune(isLeft:"), "the \(flag) handler does not prune")
        }
        // The republish trigger is still there: the falling edge is an addition, not a swap.
        #expect(body.contains("onChange(of: syncManager.leftPaneTree)"),
                "a republish no longer prunes, so a deleted folder keeps its stack until a reload")
        #expect(body.contains("onChange(of: syncManager.rightPaneTree)"))
        // And the modifier is actually installed.
        #expect(try macAppFile("ContentView.swift").contains("ColumnStackPruning("),
                "the pruning modifier is defined and never applied")
    }

    // MARK: Log coverage

    /// Every verb that changes the strip writes a line, because he audits `~/sync-cloud.log` and
    /// the app's house style logs far smaller things ("User toggled hidden files", "User changed
    /// sort option"). Named one by one rather than scanned as a family, since a blanket rule passes
    /// the moment a verb is renamed out of the pattern.
    @Test func everyVerbThatChangesTheStripIsLogged() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        let verbs = [
            "private func openTabHere(isLeft: Bool, mirrored: Bool = false)",
            "func openInNewTab(absolutePath: String, isLeft: Bool)",
            "private func mirrorOpenInNewTab(",
            // The other nine verbs' lines are required by `theTabLinesNameTheSideTheTabAndItsPath`
            // and `cyclingIsQuietAndClosingIsNot`.
        ]
        for verb in verbs {
            let body = try declarationBody(of: verb, in: source)
            #expect(body.contains("Logger.shared."),
                    "“\(verb)” changes the strip and writes nothing to the log")
        }
    }

    /// The verbs deliberately quieter, and the ones deliberately louder. A level picked on purpose
    /// is worth pinning, or "make it consistent" would flatten them.
    @Test func cyclingIsQuietAndClosingIsNot() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        for quiet in ["func selectTab(id: UUID, isLeft: Bool)",
                      "func cycleTab(forward: Bool, isLeft: Bool)",
                      "func moveTab(id: UUID, to index: Int, isLeft: Bool)"] {
            let body = try declarationBody(of: quiet, in: source)
            #expect(body.contains("Logger.shared.debug"),
                    "“\(quiet)” logs at info — holding ⌃⇥ then buries the lines worth reading")
        }
        for loud in ["func closeTab(id: UUID, isLeft: Bool)",
                     "func closeOtherTabs(keeping id: UUID, isLeft: Bool)"] {
            let body = try declarationBody(of: loud, in: source)
            #expect(body.contains("Logger.shared.info"),
                    "“\(loud)” throws tabs away at debug level")
        }
    }

    /// A line that names no tab can't be read back. ⌘T opens the folder you're already in, so
    /// same-named chips are the ordinary state, and a line that is true of any tab in any pane (a
    /// chip's title is only the leaf path component) tells two closes apart for nobody; in Compare
    /// it doesn't say which pane moved. Every verb here is aimed at one strip, so each names the
    /// side and the tab. Named verb by verb, like the log checks above. `closeOtherTabs` isn't
    /// here: its line is about a count, the one thing about that gesture that can't be recovered
    /// later. `copyTabPath` also keeps the absolute path on the end, since that is what went onto
    /// the pasteboard, while `tabLogDescription` carries the relative one the chip is named for.
    @Test func theTabLinesNameTheSideTheTabAndItsPath() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        for verb in ["func selectTab(id: UUID, isLeft: Bool)",
                     "func cycleTab(forward: Bool, isLeft: Bool)",
                     "func closeTab(id: UUID, isLeft: Bool)",
                     "func duplicateTab(id: UUID, isLeft: Bool)",
                     "func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                     "func moveTab(id: UUID, to index: Int, isLeft: Bool)",
                     "func reopenClosedTab(isLeft: Bool)",
                     "func copyTabPath(id: UUID, isLeft: Bool)"] {
            let body = sourceCodeOnly(try declarationBody(of: verb, in: source))
            #expect(body.contains("tabLogDescription("),
                    "“\(verb)” writes a line that names no particular tab")
            // Every call, not the member: `closeTab` logs twice (the last-tab branch that closes
            // the window, and the ordinary close), and a member-wide check is satisfied by the
            // first. Through `PaneSideChoice.name`, whose polarity `theSideChoiceReadsItsArgument`
            // drives, since a swapped ternary would name the wrong pane with this scan passing.
            let calls = Self.logCalls(in: body)
            #expect(!calls.isEmpty, "“\(verb)” writes no line at all")
            for call in calls {
                #expect(call.contains("PaneSideChoice.name(isLeft)"),
                        "“\(verb)” writes a line that does not say which pane it happened in — in Compare it is true of any tab in either strip: \(call.prefix(120))")
            }
        }
        // …and the description carries both halves: the title alone is the leaf component ⌘T makes
        // ambiguous by design, and a path alone is not what the chip says.
        let describe = try declarationBody(of: "private func tabLogDescription(id: UUID, isLeft: Bool) -> String",
                                           in: source)
        #expect(describe.contains("paneTabItems(isLeft: isLeft)"),
                "the line names the tab by something other than the chip the user is looking at")
        #expect(describe.contains("combinedRelativePath"),
                "the line carries the leaf component only, which two tabs can share")
        // The active entry is a stale snapshot, so describing it from the list would name the
        // folder that tab was parked at.
        #expect(describe.contains("index == list.selectedIndex"),
                "the active tab is described from its parked snapshot rather than from the live pane")

        // Copy Path also carries the absolute path, which is what went onto the pasteboard;
        // `tabLogDescription` has only the relative one the chip is named for. Read from the log
        // call onward, since `item.fullPath` also appears earlier on the `setString`.
        let copy = sourceCodeOnly(try declarationBody(of: "func copyTabPath(id: UUID, isLeft: Bool)",
                                                     in: source))
        let logCall = try #require(copy.range(of: "Logger.shared.info("),
                                   "Copy Path no longer writes its line at info")
        #expect(copy[logCall.upperBound...].contains("item.fullPath"),
                "Copy Path's line dropped the absolute path it put on the pasteboard — the relative path in `tabLogDescription` is not what was copied")
    }

    /// Each line is taken from the side of its verb that can still answer. Selecting and closing
    /// name the tab before the verb runs: after a switch the parked snapshot is the live pane's,
    /// and after a close it's gone, so the line would fall back to a bare "a tab". Cycling names it
    /// after, and must: which tab ⌃⇥ lands on is the verb's answer, and working it out here would
    /// be a second copy of `selectNext`'s wrap for the log to disagree with. The family test above
    /// only asks that `tabLogDescription(` appears somewhere in the member.
    @Test func eachTabLineIsNamedFromTheSideOfItsVerbThatCanAnswer() throws {
        let source = try macAppFile("ContentView+PaneTabs.swift")
        // (member, the verb's own call, whether the name is taken before it)
        let verbs = [("func selectTab(id: UUID, isLeft: Bool)", "syncManager.switchTab(to: id", true),
                     ("func closeTab(id: UUID, isLeft: Bool)", "syncManager.closeTab(id: id", true),
                     ("func cycleTab(forward: Bool, isLeft: Bool)", "syncManager.cycleTab(forward: forward", false)]
        for (member, call, namedFirst) in verbs {
            let body = sourceCodeOnly(try declarationBody(of: member, in: source))
            let describe = try #require(body.range(of: "tabLogDescription("),
                                        "“\(member)” names no particular tab")
            let verb = try #require(body.range(of: call), "“\(member)” no longer runs its verb")
            if namedFirst {
                #expect(describe.upperBound < verb.lowerBound,
                        "“\(member)” names the tab after the verb has already moved or removed it — the line describes the live pane, or falls back to “a tab”")
            } else {
                #expect(verb.lowerBound < describe.lowerBound,
                        "“\(member)” names the tab before the verb has decided which one it is")
            }
        }
    }

    /// Clicking the chip you're already on is a no-op, and says so by saying nothing.
    /// `PaneTabStrip` fires `onSelect(item.id)` from every chip including the active one, and
    /// `FileSyncManager.switchTab` answers `nil` for it, so an unguarded line would log the most
    /// ordinary gesture in the strip into the log he audits. The guard is on the index, not on
    /// moving the log below the verb, because the name is taken while the tab is still parked
    /// (`eachTabLineIsNamedFromTheSideOfItsVerbThatCanAnswer`).
    @Test func selectingTheChipYouAreAlreadyOnWritesNoLine() throws {
        let body = sourceCodeOnly(try declarationBody(of: "func selectTab(id: UUID, isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        // Asked the way `switchTab` asks it, both halves: an id not in this strip doesn't move the
        // pane either, which is the verb's other `nil`.
        #expect(body.contains("list.index(of: id)"),
                "the no-op test does not ask where in the strip the clicked chip is")
        #expect(body.contains("target != nil && target != list.selectedIndex"),
                "the test the line is guarded on is no longer the one `switchTab` refuses on, so either a re-click logs again or a real switch goes unlogged")
        let gate = try #require(body.range(of: "if moves {"),
                                "the selection line is unconditional again — clicking the active chip logs a switch that did not happen")
        let log = try #require(body.range(of: "Logger.shared.debug("))
        let verb = try #require(body.range(of: "syncManager.switchTab(to: id"))
        // Order first, then nesting. A log line above the `if` would fail the emptiness check
        // below too, but saying "not inside the guard"; this names the real fault. Necessary, not
        // sufficient, as in `closeOtherTabsSaysNothingWhenThereWasNothingToClose`: `if moves { }`
        // with the log after it passes this and still logs every re-click, which the emptiness
        // check catches.
        #expect(gate.upperBound < log.lowerBound,
                "the line is written before the guard even opens, so it is not guarded at all and every re-click logs a switch that did not happen")
        #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                "the line is not inside the guard — an empty branch with the log after it reads the same way round and logs every re-click")
        #expect(log.upperBound < verb.lowerBound,
                "the line is written after the switch it announces")
    }

    /// Close Other Tabs says nothing when it closed nothing. The count comes from `closableOthers`,
    /// which excludes pinned tabs, so an ⌥-click on the ✕ of a strip whose other tabs are all
    /// pinned would log "User closed 0 other browse tabs, keeping 1 pinned" for something that
    /// didn't happen. The verb still runs, because "leave me with this one" also makes the kept tab
    /// live.
    @Test func closeOtherTabsSaysNothingWhenThereWasNothingToClose() throws {
        let body = sourceCodeOnly(try declarationBody(of: "func closeOtherTabs(keeping id: UUID, isLeft: Bool)",
                                                     in: macAppFile("ContentView+PaneTabs.swift")))
        let count = try #require(body.range(of: "closableOthers(keeping: id)"),
                                 "the line no longer counts what the gesture would actually close")
        let verb = try #require(body.range(of: "syncManager.closeOtherTabs(keeping: id"),
                                "the verb is gone")
        let gate = try #require(body.range(of: "if closing > 0 {"),
                                "an ⌥-click with nothing to close still logs “User closed 0 other browse tabs”")
        let log = try #require(body.range(of: "Logger.shared.info("))
        #expect(count.upperBound < verb.lowerBound,
                "the count is taken after the verb, where the tabs it counts are already gone")
        #expect(verb.lowerBound < gate.lowerBound,
                "the line is written before the close it describes")
        // Nesting, not just order: `if closing > 0 { }` with the log after it holds every
        // comparison here and still logs a zero close. The line must be the first thing inside the
        // branch.
        #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                "the line is not inside the `if closing > 0` branch — an ⌥-click with nothing to close still logs a close that did not happen")
    }

    /// A mirrored ⌘T must not log the same sentence as the one that caused it. Both panes open a
    /// tab at their own folder, so without a distinct line the log shows one keystroke firing twice
    /// in the same second, which reads as a bug in the log used to rule bugs out.
    @Test func theMirroredNewTabSaysItIsTheMirror() throws {
        let body = try declarationBody(of: "private func openTabHere(isLeft: Bool, mirrored: Bool = false)",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        #expect(body.contains("mirrored"), "the log line cannot tell a mirrored ⌘T from a real one")
        #expect(body.contains("Linked panes:"),
                "the mirrored line does not say the link is why it happened")
        #expect(try declarationBody(of: "func openNewTabHere(isLeft: Bool)",
                                    in: macAppFile("ContentView+PaneTabs.swift"))
                    .contains("mirrored: true"),
                "the mirror is opened without marking itself as one")
    }

    /// Reopen logs from inside the verb, so a press that brings nothing back writes no line
    /// claiming a tab did. The item is disabled when there's nothing to reopen
    /// (`shortcutReopenClosedTab` returns nil when `canReopen` is false, and
    /// `ReopenClosedTabCommand` is `.disabled(reopen == nil)`), so the guard inside the verb is
    /// defensive, but it is the only thing between an empty stack and a false line.
    @Test func reopenOnlyClaimsATabWhenOneComesBack() throws {
        let body = try declarationBody(of: "func reopenClosedTab(isLeft: Bool)",
                                       in: macAppFile("ContentView+PaneTabs.swift"))
        let guardIndex = try #require(body.range(of: "else { return nil }"),
                                      "reopen no longer distinguishes an empty stack")
        let log = try #require(body.range(of: "Logger.shared.info"))
        #expect(guardIndex.upperBound < log.lowerBound,
                "reopen logs before it knows whether anything came back")
    }

    // MARK: Chips that would otherwise read alike

    private func drive(_ name: String) -> PaneTabChips.Source {
        PaneTabChips.Source(displayName: name, markImageName: "googledrive",
                            root: "~/Library/CloudStorage/GoogleDrive-\(name)")
    }

    /// Two Google Drive accounts both land on `My Drive`, and the mark can't tell them apart: the
    /// two chips carry the same title and the same brand mark. The mark separates two "Documents"
    /// chips across brands but not the commonest collision, two accounts of one brand.
    @Test func twoSourcesLandingOnTheSameFolderNameAreQualifiedByTheirSource() {
        let items = PaneTabChips.items(
            list(["My Drive", "My Drive"], selected: 0,
                 providers: ["gdrive-personal", "gdrive-emp"]),
            liveProviderId: "gdrive-personal", livePath: "My Drive", drawsColumns: true,
            source: { id in self.drive(id == "gdrive-personal" ? "Google Drive (Personal)"
                                                              : "Google Drive (EMP)") })
        #expect(items[0].title == "My Drive — Google Drive (Personal)")
        #expect(items[1].title == "My Drive — Google Drive (EMP)")
    }

    /// One source: chips that already read differently are left as they were (width is the
    /// strip's scarcest resource, so a needless "— iCloud Drive" costs a chip somewhere else); two
    /// folders sharing a leaf name take their parent; a duplicated tab or two root chips are the
    /// same folder, so nothing separates them and they are left alone (no `iCloud Drive — iCloud
    /// Drive`).
    @Test(arguments: [
        (["Finance", "Photos"], ["Finance", "Photos"]),
        (["2026/Statements", "2025/Statements"], ["Statements — 2026", "Statements — 2025"]),
        (["2026/Statements", "2026/Statements"], ["Statements", "Statements"]),
        (["", ""], ["iCloud Drive", "iCloud Drive"]),
    ])
    func chipsOnOneSourceAreQualifiedOnlyWhereThatSeparatesThem(paths: [String], titles: [String]) {
        let items = PaneTabChips.items(list(paths, selected: 0), liveProviderId: "iCloud", livePath: paths[0],
                                       drawsColumns: true, source: { _ in self.iCloud })
        #expect(items.map(\.title) == titles)
    }

    /// One setting, every way of walking into a folder. The mirror predicate is the same expression
    /// `applyColumnNavigation` uses; two copies would let a link mean one thing for a drill and
    /// another for a tab, with nothing on screen to say which.
    @Test func theMirrorObeysTheSameLinkTestAsAMirroredDrill() throws {
        let predicate = "layoutMode == .compare\n && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))"
        #expect(try CodeText(macAppFile("ContentView+PaneTabs.swift")).contains(predicate),
                "the tab mirror invented its own link test")
        #expect(try CodeText(macAppFile("ContentView.swift")).contains(predicate),
                "the mirrored drill's link test moved — the two have drifted apart")
    }
}

/// The focused pane's one door, scanned across every shipping source, off the main actor. Not
/// `@MainActor`, which is why it's a suite of its own: the scan reads hundreds of files through a
/// character-level comment stripper and a regex, and on the main thread (where
/// `PaneTabWiringTests` runs for its window tests) it takes over half a second and holds up every
/// main-actor wait in the process. Marking the test `nonisolated` inside that suite still runs it
/// on main.
@Suite struct PaneFocusDoorWiringTests {

    /// `focusedPaneSide` has one writer in the host, and it is the manager's door. The value
    /// decides whether ⌘W closes a tab or the window, and the door logs each move; a bare writer
    /// would leave a log of a window closing with nothing saying which pane the chords were aimed
    /// at. Scanned as an absence, not per known site, since a per-site check passes the moment a
    /// new one appears. Recursive, and over the modules and the CLI too, because `focusedPaneSide`
    /// is a `@Published public var` writable from any of them. The one file allowed to write it is
    /// the one that declares the door, named rather than pattern-matched. Test sources are out of
    /// scope: `SwapPanesTests` sets the property directly as a fixture.
    @Test func theHostWritesTheFocusedPaneSideOnlyThroughTheManagersDoor() throws {
        let macApp = macAppDirectory()
        let repo = macApp.deletingLastPathComponent()
        let hostFiles = PaneTabWiringTests.swiftFiles(under: macApp)
        #expect(hostFiles.count > 20,
                "the host scan found \(hostFiles.count) Swift files — it is reading the wrong folder, or the enumerator yielded nothing")

        // Every shipping source outside the host, minus the tests: `Tests` directories hold
        // fixtures that legitimately seed the property.
        let elsewhere = (PaneTabWiringTests.swiftFiles(under: repo.appendingPathComponent("Modules"))
                         + PaneTabWiringTests.swiftFiles(under: repo.appendingPathComponent("SyncCloudCLI")))
            .filter { !$0.pathComponents.contains("Tests") }
        // The floor is near the current count (about 285), not a round number well under it: a
        // loose floor passes a walk that has stopped reading most of the tree.
        #expect(elsewhere.count >= 250,
                "the module scan found \(elsewhere.count) Swift files where ~285 are expected — it is reading the wrong folder, or the walk stopped early")

        /// The file that declares the door, and the only place the property may be written bare.
        let declaringFile = "FileSyncManager+Navigation.swift"
        var doors = 0
        var declaredWrites = 0
        for file in hostFiles + elsewhere {
            let code = PaneTabWiringTests.normalizingAssignments(
                sourceCodeOnly(try String(contentsOf: file, encoding: .utf8)))
            let writes = code.components(separatedBy: "focusedPaneSide = ").count - 1
            if file.lastPathComponent == declaringFile {
                declaredWrites += writes
            } else {
                #expect(writes == 0,
                        "\(file.lastPathComponent) writes focusedPaneSide itself rather than through noteFocusedPane — the move is silent, and the log cannot say which pane ⌘W was aimed at")
            }
            doors += code.components(separatedBy: "noteFocusedPane(").count - 1
        }
        #expect(declaredWrites == 1,
                "\(declaredWrites) bare writes inside \(declaringFile) where 1 is expected — the door either stopped writing the property or grew a second path that skips its log line")
        #expect(doors >= 5,
                "\(doors) calls to the door across the shipping sources — the strip verb, the row selection, ⌃⇥ and the swap each need one, so this scan has stopped finding them and the absence above is vacuous")
    }
}
