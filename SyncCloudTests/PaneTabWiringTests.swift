import AppKit
import SwiftUI
import Testing
import Foundation
import Events
import Sync
@testable import SyncCloud

/// The app-side half of Browse tabs: where the strip is mounted, what the ⌃⇥ item says, and the
/// three-state Tab Bar switch.
///
/// `ContentView` is a `View` with `@State` and cannot be instantiated here, so the rules that
/// matter are extracted as values (`TabBarSwitch.resolve`, `PaneFocusSwitch.menuTitle`) and pinned
/// twice: the rule directly, and the call site by a source scan — because a rule nothing calls is
/// one revert away from being decoration, and this repo has shipped exactly that.
@MainActor
@Suite struct PaneTabWiringTests {

    /// One member's body: from its declaration to the first line that is a closing brace at
    /// member indentation.
    ///
    /// **Not a fixed character window.** A window is what `QuickLookOriginTests` uses, and this
    /// change is what showed the cost: one more argument on an unrelated call site pushed the line
    /// it looks for out of range, and a *tab* handler failed a *Quick Look* test. Slicing to the
    /// member's own end cannot go stale as the member grows, and a member that outgrows its own
    /// closing brace is not a thing.
    private static func memberBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"),
                               "\(declaration) never closes at member indentation")
        return String(rest[..<end.lowerBound])
    }

    /// One TYPE's body — to its closing brace at column zero.
    ///
    /// Separate from `memberBody` because the two close at different indentations, and using the
    /// member form on a type silently returns the first member instead: `CloseTabCommand`'s slice
    /// stopped at its static helper and the scan below reported the item as still disabled. A
    /// scan that reads the wrong region is worse than no scan, so the two are named apart.
    private static func typeBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"), "\(declaration) never closes at column zero")
        return String(rest[..<end.lowerBound])
    }

    /// Source with its comments removed.
    ///
    /// **Every negative assertion below must go through this.** A scan for the ABSENCE of something
    /// is answered by any comment that mentions it — this file has now tripped over its own prose
    /// twice: a doc comment naming `FileTreeView(` broke a Quick Look scan, and a comment
    /// explaining why the header menu registers no `keyboardShortcut` made the check for one pass.
    ///
    /// **This was a whole-LINE filter, which is the hole `538ac2e1` had already fixed elsewhere.**
    /// Dropping only lines whose first non-space characters are `//` leaves a *trailing* comment in
    /// the text, and the large majority of this suite's scans read it — including positive controls
    /// like `#expect(body.contains("noteWorkingIn(isLeft: "))`, whose entire job is to stop the
    /// checks under them passing vacuously. Any of those could be satisfied by the same words
    /// written after code on any line of the member, with the real call deleted.
    ///
    /// It also desynchronised ``topLevelCall``, which counts braces over this text: a `{` or `}`
    /// inside a trailing comment shifted the depth counter for everything after it, so a call at
    /// the member's top level could read as `.onlyInsideABranch` or the reverse.
    ///
    /// `SyncCloudTests.strippingComments` is the corrected one — a character scanner rather than a
    /// regex, because a `//` inside `"https://…"` is code — and it is reused rather than copied: a
    /// third implementation of this is how the three copies of `declarationBody` came to disagree.
    /// `theCommentStripperIsTheCorrectedOne` is the proof that this file gets that behaviour, and
    /// that the file it scans stays inside the stripper's stated limits.
    private static func codeOnly(_ source: String) -> String {
        SyncCloudTests.strippingComments(source)
    }

    /// One member's body, found by NAME rather than by its whole declaration — for the scans that
    /// DERIVE which members to read instead of listing them, where the full declaration is not
    /// something the deriving side knows. Same slice as ``memberBody`` otherwise.
    private static func memberBodyNamed(_ name: String, in source: String) throws -> String {
        try memberBody("func \(name)(", in: source)
    }

    /// Every capture of `group` for `pattern` in `source`. The seam that lets a scan derive its
    /// subject from the code rather than keeping a list beside it.
    private static func matches(_ pattern: String, in source: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
    }

    /// Every argument written against `label:` in `source`, as the whole TOKEN it names.
    ///
    /// A `contains` check cannot tell `isLeft: isLeft` from `isLeft: isLeftTarget` — the second
    /// contains the first — so a wrongly-polarised local satisfies a scan that looks for the
    /// spelling. That hole was real: the invariant over the one door counted `"isLeft: "` against
    /// `"isLeft: isLeft"`, and any identifier with that prefix balanced the two. Capturing the
    /// identifier (with any leading `!`) makes the comparison a token comparison.
    /// Pinned by ``theArgumentScanReadsATokenAndNotAPrefix``.
    static func argumentTokens(labelled label: String, in source: String) -> [String] {
        matches(#"\#(label):[ \t]*(!?[ \t]*[A-Za-z_][A-Za-z0-9_]*)"#, in: source, group: 1)
            .map { $0.replacingOccurrences(of: " ", with: "")
                     .replacingOccurrences(of: "\t", with: "") }
    }

    /// Every occurrence of `pattern` in `source`, as RANGES rather than as text — for the scans
    /// that have to ask *where* a match sits (inside a narrowing call, inside an exempt member)
    /// rather than only whether it exists.
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

    /// Every call of `opener` in `source`, as the span from the opener to its BALANCED closing
    /// parenthesis.
    ///
    /// **Balanced, because the regex this replaces could not be.** The `PaneSideChoice.own` scan
    /// matched `own\(isLeft,\s*left:\s*[^,]+?,\s*right:\s*[^)\n]+\)`, which cannot read a call whose
    /// argument contains a comma or a nested `(`, and stops dead at a newline — so
    /// `own(isLeft, left: syncManager.leftChildrenIndex(treeRoot: root), right: …)` wrapped over two
    /// lines is a call the scan silently does not see. A call it cannot see is a call whose sides
    /// may be swapped with nothing to say so.
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

    /// One argument list split on its TOP-LEVEL commas — a comma inside a nested call or a
    /// collection literal belongs to that argument, not to this list.
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

    /// Every `PaneSideChoice.own(…)` call in `source`, whatever shape it is written in.
    ///
    /// A call this cannot parse comes back as `nil` and the caller fails on the count — the old
    /// regex simply skipped it, which is the difference between "unreadable" and "absent".
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

    /// One side of a pair with its side-word blanked, so the two halves of a MATCHED pair compare
    /// equal and a mismatched one does not.
    ///
    /// **The hole this closes.** The per-argument check — every `left:` names something left-ish,
    /// every `right:` something right-ish — is satisfied by
    /// `own(isLeft, left: syncManager.leftRelativePath, right: syncManager.rightBrowsePath)`,
    /// because each argument contains its own side's word. That call narrows two DIFFERENT pairs
    /// and hands back one of each, which is not a pane's value at all.
    static func sideStemmed(_ argument: String) -> String {
        argument
            .replacingOccurrences(of: "left", with: "«side»",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "right", with: "«side»",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// The locals a member binds through the one flip — `let other = PaneSideChoice.sibling(isLeft)`.
    ///
    /// A member reaching for the SIBLING pane is not a bug; reaching for it by writing the `!` out
    /// by hand is, because that `!` sits in a `ContentView` extension no test can instantiate.
    /// `let other = !isLeft` in `mirrorOpenInNewTab` with the `!` dropped survived the whole app
    /// suite: ⌥/linked Open in New Tab then opened both tabs on the pane the user aimed at.
    static func siblingLocals(in body: String) -> Set<String> {
        Set(matches(#"let (\w+) = PaneSideChoice\.sibling\(isLeft\)"#, in: body, group: 1))
    }

    /// Every label a side is passed under in the tabs file. `refreshForTabSwitch(movedPane:)` and
    /// `mirrorOpenInNewTab(_:from:)` spell it differently and would be missed by `isLeft:` alone —
    /// which is a hole the one door's own invariant had to note in prose.
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

    /// Every Swift file under `root`, **recursively**.
    ///
    /// The scans that read a whole tree used `contentsOfDirectory`, which is one level deep: they
    /// see `MacApp/*.swift` and nothing under a `MacApp/Tabs/` the moment anybody makes one. The
    /// callers keep their own floor on the count, which is also what covers the other half of this
    /// — `enumerator(at:)` answers NON-NIL and yields nothing for a directory it cannot list, so a
    /// zero here is not distinguishable from an empty tree except by that floor.
    static func swiftFiles(under root: URL) -> [URL] {
        var found: [URL] = []
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found
    }

    /// Every `Logger.shared.<level>(…)` call in `body`, as the text of its ARGUMENTS.
    ///
    /// **Per call, not per member**, and that distinction is a live defect: `closeTab` writes two
    /// lines — the last-tab branch that closes the WINDOW, and the ordinary close — so a
    /// member-wide `contains` for the side is satisfied by the first, and stripping the side from
    /// every ORDINARY ⌘W line was green. Balanced parentheses, because these arguments are string
    /// interpolations full of them. Pinned by ``theLogCallScanReadsEachCallSeparately``.
    static func logCalls(in body: String) -> [String] {
        var calls: [String] = []
        for level in ["info", "debug", "warning", "error"] {
            let opener = "Logger.shared.\(level)("
            var search = body.startIndex
            while let start = body.range(of: opener, range: search..<body.endIndex) {
                var depth = 1
                var index = start.upperBound
                while index < body.endIndex, depth > 0 {
                    if body[index] == "(" { depth += 1 }
                    if body[index] == ")" { depth -= 1 }
                    if depth > 0 { index = body.index(after: index) }
                }
                calls.append(String(body[start.upperBound..<index]))
                search = index < body.endIndex ? body.index(after: index) : body.endIndex
            }
        }
        return calls
    }

    /// A member body with its own opening brace removed, so brace depth inside it starts at zero.
    ///
    /// ``memberBody`` slices from just after the DECLARATION, which leaves the ` {` on the front —
    /// with it every statement in the member reads as depth 1 and ``topLevelCall`` could never
    /// answer `.found` for anything.
    static func memberInterior(_ body: String) -> String {
        guard let brace = body.firstIndex(of: "{") else { return body }
        return String(body[body.index(after: brace)...])
    }

    /// Whether `call` is reached unconditionally in `body`.
    ///
    /// **The guarantee a text walk cannot give.** "Does the member mention the focus door" is
    /// satisfied by `if pinned { noteWorkingIn(…) }` — a measured surviving mutation, under which
    /// unpinning a chip moves no focus and ⌘W stays aimed at the pane the user is not looking at —
    /// and by a call parked after an early `return`. Brace depth answers both: a call inside any
    /// `if`/`guard`/`switch` branch or closure is at depth ≥ 1, and a `guard … else { return }`
    /// puts its `return` at depth 1, which is correct and must NOT count (`copyTabPath` bails on a
    /// chip its strip does not hold before it moves anything, deliberately).
    ///
    /// Depth is counted over `codeOnly` text; braces inside a string literal would fool it, and
    /// none of the members read here has one. ``theTopLevelCallScanTellsABranchFromAStatement``
    /// is the fixture that proves all four answers are reachable.
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

    /// Source with a plain **assignment** `=` normalised to one space each side — and nothing else
    /// touched, which is the entire point.
    ///
    /// What this replaces opened with `.replacingOccurrences(of: " +=", with: " +=")`, which
    /// replaces a string with itself: measured, that step returned its input unchanged. So the `+=`
    /// protection it was written for never happened at all, and `pendingTabProviderChanges += 1`
    /// came out of the next step as `… + = 1`.
    ///
    /// The other direction is the one with teeth: `\s*=\s*` rewrites a COMPARISON too, so
    /// `if leftProviderId == id` became `leftProviderId =  = id` — which contains
    /// `"leftProviderId = "` and was therefore counted as a WRITE. Measured against the mixed
    /// fixture below, the old normaliser answered **3** where 2 were real, one extra per `==` on a
    /// pane provider id. No such comparison is in the file today, so it is latent; the first one
    /// anybody adds fails the count on a *read*, and the tempting repair is to loosen the number
    /// that is the whole value of the assertion.
    ///
    /// The lookbehind refuses an `=` that is the tail of a compound operator (`+=`, `-=`, `!=`,
    /// `<=`, `>=`, `==`); the lookahead refuses one that is the head of `==`. Horizontal whitespace
    /// only — `\s` would swallow newlines and join two statements into one. Pinned by
    /// ``theWriteScanTellsAnAssignmentFromAComparison``, which is the fixture this had none of.
    static func normalizingAssignments(_ source: String) -> String {
        source.replacingOccurrences(of: #"(?<![-+*/%<>!=])[ \t]*=[ \t]*(?!=)"#,
                                    with: " = ", options: .regularExpression)
    }

    /// How many times `source` WRITES a pane provider id, by any spelling the compiler accepts.
    ///
    /// Extracted from the assertion so a fixture can be handed known text: counted inline, the
    /// miscount above could only be found by reading the regex, and it was not.
    static func paneProviderIdWrites(in source: String) -> Int {
        let code = normalizingAssignments(source)
        var writes = 0
        for direct in ["leftProviderId = ", "rightProviderId = "] {
            writes += code.components(separatedBy: direct).count - 1
        }
        // The projected and underscored forms are counted on the RAW text: they are not assignments
        // to normalise, they are the refactor someone reaches for to delete the ternary — a write
        // through `$leftProviderId.wrappedValue` names the property nowhere the pattern above looks.
        for indirect in ["$leftProviderId", "$rightProviderId", "_leftProviderId", "_rightProviderId"] {
            writes += source.components(separatedBy: indirect).count - 1
        }
        return writes
    }

    // Both readers carry the truncation guard `macAppSources()` documents as load-bearing: a
    // partially read file makes ~80 `contains` scans below answer false and every `!contains`
    // vacuously true. These two were the only readers in the target without it.
    private static func fileExplorer(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text
    }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text
    }

    /// The positive control. Every scan below asserts a presence in one of two files; a reader that
    /// silently returned the wrong text would make them all pass.
    @Test func theScanCanActuallyFail() throws {
        #expect(try Self.source("ContentView.swift").contains("func paneColumn(isLeft: Bool)"),
                "this is not ContentView")
        #expect(try Self.source("ShortcutCommands.swift").contains("struct TabBarSwitch"),
                "this is not the shortcuts file")
        #expect(try !Self.source("ContentView.swift").contains("a string that is definitely not in ContentView"))

        // Both slicers, against a member and a type whose contents are known — a helper that
        // returned the wrong region would make every scan below pass on the wrong text, which is
        // exactly what `typeBody` was added for.
        let commands = try Self.source("ShortcutCommands.swift")
        #expect(try Self.typeBody("struct CloseTabCommand: View {", in: commands).contains("keyboardShortcut"),
                "the type slice does not reach the item's body")
        #expect(try Self.memberBody("static func run(_ close: CloseTabAction?", in: commands)
                    .contains("closeWindow()"),
                "the member slice does not reach the rule's body")
    }

    /// The fixture for ``argumentTokens(labelled:in:)`` — and for the hole it was written to close.
    ///
    /// `"isLeft: isLeftTarget"` CONTAINS `"isLeft: isLeft"`, so the substring invariant that used to
    /// guard the one door was balanced by a wrongly-polarised local with that name. Handed known
    /// text, this reads tokens: a `!`, an unrelated identifier and a lookalike all come back as
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

    /// The fixture for ``topLevelCall(_:in:)``, which is the half a text walk never had.
    ///
    /// All four answers are produced from known text, and the two that matter are the ones a
    /// `contains` cannot tell apart: a call the member always makes, and the same call wrapped in a
    /// branch. The `guard … else { return }` case is the third — its `return` is inside braces, so
    /// it does NOT count as an early return, which is what lets `copyTabPath` bail on a chip its
    /// strip does not hold before it moves anything.
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

    /// The fixture for ``logCalls(in:)`` — the helper that turns a member-wide check into a
    /// per-line one. Two calls where only the first carries the marker is exactly `closeTab`'s
    /// shape, and the whole point is that it must come back as two.
    @Test func theLogCallScanReadsEachCallSeparately() {
        let body = """
                Logger.shared.info("closing the \\(PaneSideChoice.name(isLeft)) pane's last tab")
                Logger.shared.info("closed a tab \\(describe(id: id, isLeft: isLeft))")
                Logger.shared.debug("reordered")
            """
        let calls = Self.logCalls(in: body)
        #expect(calls.count == 3, "\(calls.count) log calls read where 3 are written")
        #expect(calls.filter { $0.contains("PaneSideChoice.name(isLeft)") }.count == 1,
                "the scan is not reading each call's own arguments — a member whose FIRST line names the side would pass for all of them")
        // The nested `describe(…)` proves the balance: a naive scan to the first `)` would cut the
        // second call short and lose everything after it.
        #expect(calls[1].hasSuffix("\\(describe(id: id, isLeft: isLeft))\""),
                "a call with a nested call in its interpolation is cut short — the text after it is invisible to every check")
    }

    /// **The polarity of the two things `isLeft` decides, driven rather than scanned.**
    ///
    /// Both were ternaries written out at every site inside a `ContentView` extension, which no
    /// test can instantiate. Two measured survivors of the whole app suite:
    /// `current: isLeft ? rightProviderId : leftProviderId` in `tabAction` — `d655b528`'s headline
    /// defect verbatim, a cross-source chip click asking about the SIBLING pane's source — and
    /// `isLeft ? "right" : "left"` in a log line, every tab line naming the wrong pane. On a type
    /// that needs nothing to exist, both are a real assertion.
    @Test func theSideChoiceReadsItsArgument() {
        #expect(PaneSideChoice.own(true, left: "the left one", right: "the right one") == "the left one",
                "a verb aimed at the LEFT pane reads the right pane's value")
        #expect(PaneSideChoice.own(false, left: "the left one", right: "the right one") == "the right one",
                "a verb aimed at the RIGHT pane reads the left pane's value")
        #expect(PaneSideChoice.name(true) == "left",
                "a line about the left pane says it happened in the right one")
        #expect(PaneSideChoice.name(false) == "right",
                "a line about the right pane says it happened in the left one")
        // **The third thing `isLeft` decides, and the third measured survivor.** `let other =
        // !isLeft` in `mirrorOpenInNewTab` with the `!` dropped left the whole app suite green, and
        // ⌥/linked Open in New Tab then opened BOTH tabs on the pane the user aimed at and none on
        // the sibling — while ⌘T's identical mirror was pinned, which is the asymmetry that exposed
        // it. Here it is one call a test can make.
        #expect(PaneSideChoice.sibling(true) == false,
                "the sibling of the LEFT pane is the left pane — a mirrored open lands twice on the pane the user aimed at")
        #expect(PaneSideChoice.sibling(false) == true,
                "the sibling of the RIGHT pane is the right pane — a mirrored open lands twice on the pane the user aimed at")
        // Both directions, because a flip and a constant are told apart only by asking twice.
        #expect(PaneSideChoice.sibling(PaneSideChoice.sibling(true)) == true,
                "the flip does not come back — it is a constant, not a negation")
    }

    // MARK: Where the strip is mounted

    /// **A sibling above the header, never a wrapper around it.**
    ///
    /// `PaneQuickLookScopeTests` fails if the pane column's `VStack` is re-nested — but it fails
    /// with a message about Quick Look's scope, which is a long way from "someone wrapped the tab
    /// strip around the pane". This says it directly, and it is the one structural fact the whole
    /// feature rests on: one insertion point serves Browse, both Compare panes and the rail.
    @Test func theStripIsMountedAboveTheHeaderInTheSamePaneColumn() throws {
        let content = try Self.source("ContentView.swift")
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

    /// **Drawn only when there is something to draw.** At one tab the strip must occupy no space
    /// at all — an empty 34pt row above every pane is what an install that never opens a second tab
    /// would otherwise get, and the whole "unchanged unless you use it" claim rests on this `if`.
    @Test func theStripIsGatedOnHavingTabsOrTheSwitch() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        let body = String(content[column.upperBound...].prefix(20_000))
        let gate = try #require(body.range(of: "if paneShowsTabStrip(isLeft: isLeft) {"),
                                "the strip is built unconditionally — one tab now costs a 34pt row")
        let strip = try #require(body.range(of: "PaneTabStrip("))
        #expect(gate.lowerBound < strip.lowerBound, "the gate does not guard the strip")

        let rule = try Self.memberBody("func paneShowsTabStrip(isLeft: Bool) -> Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(rule.contains("showsStrip"), "the gate no longer asks the tab list")
        #expect(rule.contains("tabBarVisible"), "View ▸ Tab Bar no longer shows the strip")
    }

    /// One call site, so Compare's two panes and the Organize/Storage rail get the strip for free.
    /// A second would be the plumbing this design exists to avoid.
    @Test func thereIsExactlyOnePlaceThatBuildsAStrip() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.components(separatedBy: "PaneTabStrip(").count - 1 == 1,
                "more than one place builds a tab strip — they will drift")
    }

    // MARK: The Tab Bar switch

    @Test func aSecondTabForcesTheTabBarSwitchOnAndFreezesIt() {
        let forced = TabBarSwitch.resolve(hasSecondTab: true, preference: false) { _ in }
        #expect(forced.isOn, "the switch reads OFF while a tab bar is on screen")
        #expect(forced.isForced, "the switch could hide a strip whose tabs would be unreachable")
    }

    @Test func atOneTabTheSwitchIsThePreferenceAndIsLive() {
        let off = TabBarSwitch.resolve(hasSecondTab: false, preference: false) { _ in }
        #expect(!off.isOn)
        #expect(!off.isForced)

        let on = TabBarSwitch.resolve(hasSecondTab: false, preference: true) { _ in }
        #expect(on.isOn)
        #expect(!on.isForced)
    }

    /// **The switch has to ask the same question the visibility rule answers, which is both panes.**
    ///
    /// `TabBarSwitch.resolve` is pure and the two tests above pin it completely, so they pass just as
    /// well when the caller feeds it the wrong pane — which it did. `shortcutTabBar` asked only
    /// `shortcutTabTargetIsLeft` while `PaneTabStripVisibility.shows` decides from `own` *and*
    /// `sibling`: in Compare with the second tab in the *unfocused* pane, a strip was on screen and
    /// the menu item read unticked and live, offering to hide a strip it did not describe and taking
    /// its tabs out of reach. That is the case the forcing exists to prevent, reached from the other
    /// side — the extracted rule was right and the argument was wrong, which is the shape a
    /// value-only test cannot see.
    ///
    /// **The forcing is exactly "the strip shows even with the switch off", and this proves it for
    /// every combination rather than asserting a spelling.**
    ///
    /// The first version of this test was a source scan for `paneTabs(isLeft: true)` and
    /// `layoutMode == .compare` in the call site's body. It caught the defect, and it pinned the
    /// *wording* of the fix: any refactor — a loop, a helper, `!isLeft` instead of a literal — would
    /// have failed it while behaving identically. That is the trap this repo keeps re-finding, so
    /// the rule moved into `PaneTabStripVisibility.forcesTabBarSwitch` and the identity is asserted
    /// against `shows` directly. If either rule changes without the other, this fails and names the
    /// combination.
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
        // The case the defect was: Compare, second tab in the SIBLING only. Spelled out because the
        // sweep above would still pass if both rules lost the sibling term together.
        #expect(PaneTabStripVisibility.forcesTabBarSwitch(own: false, sibling: true, isCompare: true),
                "a second tab in the unfocused pane draws a strip on both panes, and the switch must not be able to hide it")
        #expect(!PaneTabStripVisibility.forcesTabBarSwitch(own: false, sibling: true, isCompare: false),
                "outside Compare there is no sibling strip on screen, so the switch must stay live")
    }

    /// The rule above is pure, so every assertion in it passes with the call site still asking one
    /// pane — the "extracted for testability, one revert from unused" pairing this file already makes
    /// for the monitors. One line, and it is the line that was wrong.
    @Test func theTabBarSwitchGoesThroughThatRule() throws {
        let body = try Self.memberBody("var shortcutTabBar: TabBarSwitch {",
                                       in: try Self.source("ShortcutCommands.swift"))
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

    /// The call-site half: the resolver is what the focused value actually publishes.
    @Test func theTabBarSwitchIsResolvedThroughTheRule() throws {
        let commands = try Self.source("ShortcutCommands.swift")
        let body = try Self.memberBody("var shortcutTabBar: TabBarSwitch {", in: commands)
        #expect(body.contains("TabBarSwitch.resolve("),
                "shortcutTabBar builds the switch by hand — the tested rule is unused")
    }

    /// …and the item disables on it, which is the half a value cannot state.
    @Test func theTabBarItemDisablesWhileTheSwitchIsForced() throws {
        let commands = try Self.source("ShortcutCommands.swift")
        let body = try Self.typeBody("struct ToggleTabBarCommand: View {", in: commands)
        #expect(body.contains("isForced == true"),
                "the Tab Bar item stays clickable while a second tab is open")
    }

    // MARK: ⌃⇥ says which of its two jobs it will do

    @Test func theFocusItemNamesTheOtherPaneInCompare() {
        #expect(PaneFocusSwitch.menuTitle(for: PaneFocusSwitch(targetName: "Dropbox", run: {}))
                == "Focus Dropbox")
    }

    /// In Browse the same chord cycles tabs, and the menu is the only place that says so at rest.
    @Test func theFocusItemReadsNextTabInBrowse() {
        #expect(PaneFocusSwitch.menuTitle(for: .nextTab(run: {})) == "Next Tab")
    }

    @Test func theDisabledFocusItemNamesNoPane() {
        #expect(PaneFocusSwitch.menuTitle(for: nil) == "Focus Other Pane")
    }

    /// The Browse branch is real, not just expressible: ⌃⇥ resolves to a tab cycle there, and only
    /// when the pane has a second tab to cycle to.
    @Test func browseResolvesTheChordToATabCycle() throws {
        let search = try Self.source("ContentView+PaneSearch.swift")
        let body = try Self.memberBody("var switchPaneFocusAction: PaneFocusSwitch? {", in: search)
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

    /// **The active chip reads the LIVE pane; every other chip reads its own parked snapshot.**
    /// The active entry in the list is stale by construction, so a strip drawn entirely from the
    /// list is correct when you arrive and wrong one click later.
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

    /// **A parked chip promises what selecting it will show, and in Tree that is the tab's SCOPE.**
    /// The presentation belongs to the pane, not to a tab, so every chip in this strip will be drawn
    /// the same way — a parked one titled from its column stack renames itself on click (`2024` to
    /// `Finance`) and its tooltip points at a folder the pane never shows. The stored location keeps
    /// both halves either way; only the readout resolves.
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

        // The ACTIVE chip's path is what Copy Path puts on the pasteboard and what the tooltip
        // shows, so the three agree by construction — see `copyTabPath`. In Tree that means the
        // clipboard carries the scope, which is where selecting the tab lands you; a deeper string
        // than both the label and the tooltip would be the stranger result.
        let liveInTree = PaneTabChips.items(list, liveProviderId: "iCloud", livePath: "Photos",
                                            drawsColumns: false, source: { _ in self.iCloud })
        #expect(liveInTree[0].fullPath.hasSuffix("/Photos"),
                "Copy Path and the tooltip no longer agree with the chip's own label")
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

    /// **The tooltip's path is expanded.** A source's stored root may carry a tilde; the chip's
    /// help tag is the strip's answer to "which Documents is this?", and `~/Documents/Finance`
    /// answers it worse than the real path does.
    @Test func theChipsPathIsExpanded() {
        let items = PaneTabChips.items(list(["Finance"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "Finance",
                                       drawsColumns: true,
                                       source: { _ in self.iCloud })
        #expect(!items[0].fullPath.hasPrefix("~"), "the chip's path still carries a tilde")
        #expect(items[0].fullPath.hasSuffix("/Documents/Finance"))
    }

    // MARK: Whether a switch changes the source

    @Test func aTabOnTheSameSourceWritesNoProviderId() {
        #expect(PaneTabProviderSwitch.decide(arrived: "iCloud", current: "iCloud",
                                             isAvailable: { _ in true }) == .keep)
    }

    @Test func aTabOnAnotherAvailableSourceIsAdopted() {
        #expect(PaneTabProviderSwitch.decide(arrived: "Dropbox", current: "iCloud",
                                             isAvailable: { _ in true }) == .adopt("Dropbox"))
    }

    /// The invisible one: a tab whose source has been removed must not have its folder rendered
    /// under whatever source the pane happens to be showing.
    @Test func aTabOnASourceThatIsGoneIsRefusedRatherThanReinterpreted() {
        #expect(PaneTabProviderSwitch.decide(arrived: "Dropbox", current: "iCloud",
                                             isAvailable: { _ in false }) == .unavailable("Dropbox"))
    }

    /// …and the call site **acts on it**, which for most of this feature's life it did not.
    ///
    /// The branch only logged, under a comment claiming the pane "stayed on its current source".
    /// That is true of the source and false of the folder: the verb has already applied the tab, so
    /// the pane is sitting on the removed source's folder path under the LIVE source's root — a
    /// path that usually exists nowhere, which shows as an empty pane. `discardTab` drops the tab
    /// and lands the pane on one that works; see `PaneTabSwitchingTests` for both of its cases.
    @Test func aTabOnASourceThatIsGoneIsDiscardedAndNotJustLogged() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        let branch = try #require(body.range(of: "case .unavailable"),
                                  "the removed-source case is no longer handled")
        let rest = String(body[branch.upperBound...])
        // `discardDeadTabs`, not `discardTab`: the fallback is a neighbour and neighbours die
        // together, so a single discard landed the pane straight onto the next dead tab.
        #expect(rest.contains("syncManager.discardDeadTabs("),
                "a tab on a removed source is only warned about — the pane is left on a path under the wrong root")
        // And the pane's search field follows the tab it lands on, like every other arrival.
        #expect(rest.contains("paneSearchState(isLeft: isLeft).wrappedValue"),
                "the discarded tab's search query is left in the field of the tab that replaced it")
    }

    /// **Every question about whether a PANE may be pointed at a source asks `enabledProviders`,
    /// and it asks it through one predicate.**
    ///
    /// Three of them asked `availableProviders` instead — the *discovered* list, which keeps a
    /// source the user has switched off in Settings. `refreshAction` and `refreshForTabSwitch`
    /// resolve their pair out of `enabledProviders` and return without loading anything when either
    /// is missing, so a pane on a disabled source is a pane nothing will ever walk.
    ///
    /// The launch path was the sharp end, and it is the one this scan is really about. Open a tab
    /// on a source, switch that source off, quit, relaunch: `applyProviderSelection` resolves the
    /// pane's id against the enabled list, then `restoreBrowseTabs` writes the disabled one back
    /// over it, and the bootstrap's `refreshAction()` bails. Both panes up, empty, no scan and
    /// nothing said — and nothing re-resolves, because `enabledProviders` never changed and its
    /// `onChange` never fires.
    ///
    /// Scanned as an ABSENCE across the whole file rather than as three presences, because the
    /// failure is a list being asked for somewhere new: a per-site check passes the moment a fourth
    /// site is added. The one legitimate reading is asserted by name below, so this cannot pass by
    /// the file having lost the ability to name a source at all.
    @Test func everyPaneProviderQuestionAsksTheEnabledList() throws {
        let code = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        #expect(code.contains("settings.enabledProviders.contains { $0.id == id }"),
                "paneCanShowSource no longer reads the enabled list")
        for site in ["isAvailable: paneCanShowSource", "isKnownProvider: paneCanShowSource",
                     "canShowSource: paneCanShowSource"] {
            // The third site is the launch restore's adoption gate, handed to
            // `BrowseTabRestorePlan` as a value — the plan's own use of it
            // (`canShowSource(active.providerId)`) is executed, not scanned, by
            // `BrowseTabRestorePlanTests.adoptionIsWithheldWhenThePaneCannotShowTheSource`.
            #expect(code.contains(site), "\(site) no longer routes through the one predicate")
        }
        // The chip's NAME and mark are the one thing the discovered list is right for: a source
        // switched off still has a display name, and a chip reading "Dropbox" for the moment before
        // the tab is discarded beats one reading its raw id.
        let uses = code.components(separatedBy: "availableProviders").count - 1
        #expect(uses == 1,
                "\(uses) uses of availableProviders — a pane may be pointed at a source no refresh will walk")
        let items = try Self.memberBody("func paneTabItems(isLeft: Bool",
                                        in: Self.source("ContentView+PaneTabs.swift"))
        #expect(items.contains("settings.availableProviders"),
                "the one legitimate use has moved — this scan is now counting something else")
    }

    /// **…and the restore says what it threw away.**
    ///
    /// `PaneTabsStore.restore` drops an entry whose source this pane cannot be pointed at, and now
    /// that the list is `enabledProviders` the commonest way to reach that is not a source
    /// vanishing but the user switching one OFF in Settings. Dropping stays the right answer —
    /// there is no root for such a tab to fall back to — but the strip is rewritten by the first
    /// thing that saves, so a silent drop loses those tabs for good with nothing to say where they
    /// went. The line beside it counts what was RESTORED, which cannot answer that.
    @Test func theLaunchRestoreSaysWhatItDropped() throws {
        // The counting and the warning line live in `BrowseTabRestorePlan` now and are executed by
        // `BrowseTabRestorePlanTests` (dropped-before-anything-else, the wholly-dropped strip).
        // What only this scan can see is the threading: the plan can only notice a drop if the
        // host hands it the STORED count to compare against what the restore kept.
        let body = Self.codeOnly(try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
        #expect(body.contains("storedCount: stored.entries.count"),
                "nothing hands the plan what was stored, so no drop can be noticed")
    }

    /// **Every verb that OPENS a tab cuts its location through `PaneTabOpening`.**
    ///
    /// A pane's location is two values and only the stack draws columns past the first. All three
    /// openers used to hand the joined path over as the SCOPE with no stack, so a tab opened from a
    /// pane four columns deep was flattened the moment it was created — and persistence then
    /// round-tripped that flattening perfectly, which is why it presented as "the columns are
    /// collapsed again after a restart" long after the restore had been fixed to carry the depth.
    /// His stored strip: `Health/Medical/Included Health/Expert Opinions` at `stackDepth` 0.
    ///
    /// Scanned as an ABSENCE of the flattening form as well as a presence of the rule — a presence
    /// check alone passes with a fourth opener added beside them still doing it the old way.
    @Test func everyTabOpenerCutsItsLocationThroughTheRule() throws {
        let code = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        let uses = code.components(separatedBy: "PaneTabOpening.location(").count - 1
        #expect(uses == 3, "\(uses) openers cut through the rule — expected ⌘T, Open in New Tab, and the mirror")
        #expect(code.components(separatedBy: "browsePath: cut.stack").count - 1 == 3,
                "an opener resolves the cut and then does not use its stack half")
        for flattened in ["relativePath: here)", "relativePath: relative)", "relativePath: landing)"] {
            #expect(!code.contains(flattened),
                    "an opener still hands the joined path over as the scope — the tab opens with its columns collapsed")
        }
    }

    /// **Open in New Tab expands the pane's root before it compares anything against it.**
    ///
    /// A source's stored path may be written with a tilde while a row's id is always absolute, and
    /// `PathBoundary.relativize` compares them as strings — so an unexpanded root matches nothing,
    /// the guard below it takes the "outside this pane's source" branch, and the whole entry point
    /// becomes a silent no-op with a warning that names the wrong reason. The MIRROR's expansion is
    /// scanned by `bothWaysOfOpeningATabMirrorOntoTheLinkedPane`; this one, the half a user actually
    /// clicks, was not scanned at all.
    @Test func openInNewTabExpandsTheSourceRootBeforeRelativizing() throws {
        let body = Self.codeOnly(try Self.memberBody("func openInNewTab(absolutePath: String, isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
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
        let body = try Self.memberBody("private func adoptProviderForTab(",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("pendingTabProviderChanges += 1"),
                "adopting a source does not suppress the navigation reset")
        let tab = try Self.memberBody("private func tabAction(isLeft: Bool",
                                      in: Self.source("ContentView+PaneTabs.swift"))
        let adopt = try #require(tab.range(of: "case .adopt(let id):"),
                                 "the provider decision is no longer handled by case")
        #expect(String(tab[adopt.upperBound...]).contains("adoptProviderForTab("),
                "the adopt case writes the id some other way than through the one door")
    }

    /// **Every write of a pane provider id in the tabs file goes through `adoptProviderForTab`.**
    ///
    /// Scanned as a COUNT, not per-site: a per-site check passes the moment a fourth writer appears,
    /// and three writers each forgetting a different part of the handler's work is precisely the
    /// defect this helper was introduced to end (`.adopt` skipped the ignore-store re-key and the
    /// lens clear, the discard branch never wrote the id at all, the launch restore wrote it with no
    /// suppression). The two assignments below are the ones INSIDE the helper.
    @Test func theOnlyWriterOfAPaneProviderIdInTheTabsFileIsTheAdoptHelper() throws {
        // Counted through `paneProviderIdWrites`, which normalises assignment — Swift accepts
        // `leftProviderId=id` and any run of spaces around the `=`, and a plain substring count
        // sees neither. It deliberately does NOT normalise `==`, `!=` or `+=`; the fixture below is
        // what holds that, because the version this replaced got it wrong in both directions and
        // nothing could tell.
        let raw = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        let writes = Self.paneProviderIdWrites(in: raw)
        #expect(writes == 2,
                "\(writes) writes of a pane provider id — the helper's own two are the only ones allowed")
        let helper = try Self.memberBody("private func adoptProviderForTab(",
                                         in: Self.source("ContentView+PaneTabs.swift"))
        #expect(helper.contains("if isLeft { leftProviderId = id } else { rightProviderId = id }"),
                "the two writes are not the helper's — this scan is counting someone else's")
    }

    /// **The counter above tells a write from a read, and that was provably not true.**
    ///
    /// Its normaliser opened with a step that replaced a string with itself, so the `+=` it was
    /// written to protect was split into `+ =` — and its `\s*=\s*` rewrote comparisons too, so
    /// `if leftProviderId == id` normalised into text containing `"leftProviderId = "` and counted
    /// as a write. Measured against the fixture below: three writes for two, one extra per `==` on
    /// a pane provider id. Nothing in the file happens to contain such a
    /// comparison today, which is exactly why it needed a fixture rather than a reading of the
    /// production file — the miscount is latent until someone adds the first `==`, at which point
    /// the count fails on a READ and the obvious repair is to raise the number the assertion is
    /// entirely made of.
    @Test func theWriteScanTellsAnAssignmentFromAComparison() {
        // A comparison is not a write. This is the latent case, and the reason this fixture exists.
        #expect(Self.paneProviderIdWrites(in: "if leftProviderId == id { return }") == 0,
                "a `==` comparison counts as a write — the count breaks on the first read anyone adds")
        #expect(Self.paneProviderIdWrites(in: "guard rightProviderId != id else { return }") == 0,
                "a `!=` comparison counts as a write")
        // Nor is a compound assignment to something else — the case the inert first step was for.
        #expect(!Self.normalizingAssignments("pendingTabProviderChanges += 1").contains("+ ="),
                "a compound assignment is still split into `+ =`, so the inert guard is still inert")
        #expect(Self.paneProviderIdWrites(in: "pendingTabProviderChanges += 1") == 0)

        // …and a real write still counts, at every spacing Swift accepts. Without these the fix
        // could be "normalise nothing", which passes every assertion above and sees no writes.
        #expect(Self.paneProviderIdWrites(in: "leftProviderId=id") == 1, "a tight `=` is not seen")
        #expect(Self.paneProviderIdWrites(in: "rightProviderId   =   id") == 1, "a padded `=` is not seen")
        #expect(Self.paneProviderIdWrites(in: "$leftProviderId.wrappedValue = id") == 1,
                "a write through the projected binding is not seen")

        // The measured miscount, whole: two real writes beside one read and one compound
        // assignment. Measured with the old normaliser restored, this answered 3 — the `==` line
        // counts as a write, and the `+=` line comes out as `+ =` rather than being protected.
        let mixed = """
            if leftProviderId == id { return }
            pendingTabProviderChanges += 1
            if isLeft { leftProviderId = id } else { rightProviderId = id }
            guard rightProviderId != id else { return }
            """
        let counted = Self.paneProviderIdWrites(in: mixed)
        #expect(counted == 2, "\(counted) writes counted where 2 are real")
    }

    /// The helper does everything the suppressed `onChange` would have done — except the one thing
    /// the suppression exists for.
    ///
    /// Each of these three was silently skipped for a source change made through a tab. The re-key
    /// is the one with teeth: `IgnoredItemsStore` is keyed on the PAIR of sources, so leaving it on
    /// the old pair hides items ignored for a comparison that is no longer on screen and persists
    /// new ones under the wrong key.
    @Test func adoptingDoesEverythingTheSuppressedHandlerWouldExceptTheReset() throws {
        let body = try Self.memberBody("private func adoptProviderForTab(",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        // Positives through `codeOnly` as well as the negative below: this file has tripped over its
        // own prose twice, and a doc comment naming any of these would satisfy the check with the
        // call deleted.
        let code = Self.codeOnly(body)
        #expect(code.contains("ignoredItemsStore?.activate("),
                "a tab-driven source change leaves the ignored-items store on the old pair")
        #expect(code.contains("clearLensResultsForProviderSwitch()"),
                "stale Tidy results outlive their provider when a tab changes it")
        // Through the coordinator's tab-shaped door, WITH the side: `.tabChangedSource` carries no
        // side of its own, and the stranded-pin warning it triggers is a question about the pane
        // the tab did NOT move (see `StrandedProviderPin`).
        #expect(code.contains("noteTabChangedSource(isLeft: isLeft)"),
                "a guided review framed on the old pair survives a tab-driven source change, or the event no longer says which pane the tab moved")
        // **Not `.providerSwitched`.** That event can answer with `.undoProviderPin`, which
        // repoints the SIBLING pane and restores no folder because it expects the caller's
        // `retargetPane()` to re-home it — and this method exists precisely to not reset. The
        // reducer half is `CompareReviewReducerTests.aTabDrivenSourceChangeNeverRepointsTheSiblingPane`;
        // this is the call site, which is what actually chooses the event.
        #expect(!Self.codeOnly(body).contains("providerSwitched"),
                "the tab path is back on the event that can repoint the other pane")
        // **The NAME, not a spelling of the call.** This read `contains("resetNavigation()")` and
        // was by then vacuous: every live call site spells the landings as arguments, so the
        // realistic regression — pasting the provider-switch handler into the tab path — matched
        // nothing and sailed through. A bare name cannot go stale the same way, and the `codeOnly`
        // strip above is what keeps the doc comment two lines up from satisfying it.
        //
        // **Both names, because the verb was renamed.** `resetNavigation(leftLanding:rightLanding:)`
        // became `retargetPane(isLeft:landing:)` when the provider switch stopped resetting the pane
        // the user had not touched. A scan naming only the old one would have gone quietly vacuous
        // at that rename — which is the exact failure the paragraph above describes, so it is worth
        // paying a dead string to keep it from happening twice.
        for verb in ["resetNavigation", "retargetPane"] {
            #expect(!Self.codeOnly(body).contains(verb),
                    "the whole point of the suppression is that the TAB carries the navigation, but this calls \(verb)")
        }
    }

    /// A discard that lands the pane on a third, live source adopts it.
    ///
    /// `discardDeadTabs` stops at the first neighbour the pane *can show*, which is a wider set than
    /// "is currently on" — pinned on the manager side by
    /// `PaneTabSwitchingTests.aDiscardCanLandOnATabFromAThirdLiveSource`. Taking only the landed
    /// tab's search field, which is all this branch used to do, left the pane on the old source
    /// showing the landed tab's path under the wrong root, and `saveBrowseTabs` then rewrote that
    /// tab's source id to the old one.
    @Test func aDiscardThatLandsOnAnotherSourceAdoptsIt() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        let branch = try #require(body.range(of: "case .unavailable:"),
                                  "the unavailable branch is gone")
        let after = String(body[branch.upperBound...])
        #expect(after.contains("adoptProviderForTab("),
                "the pane keeps the dead tab's source after landing on a live one")
        #expect(after.contains("paneCanShowSource(landed.providerId)"),
                "the landing is adopted without checking the pane may be pointed there")
    }

    /// The rule behind the two provider handlers, and the ORDER that is its whole content.
    @Test func aSuppressionCounterIsConsumedWhereverItsWriteLands() {
        // Bootstrap or not, an armed counter is consumed — this is the case that used to strand it.
        #expect(PaneProviderChange.decide(swapPending: 0, tabPending: 1, isBootstrapping: true)
                == .consumeTab)
        #expect(PaneProviderChange.decide(swapPending: 1, tabPending: 0, isBootstrapping: true)
                == .consumeSwap)
        // …and the guard-down case, which is where the launch restore's write actually arrived.
        #expect(PaneProviderChange.decide(swapPending: 0, tabPending: 1, isBootstrapping: false)
                == .consumeTab)
        // Swap wins when both are armed, matching the order the handlers tested them in.
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
        let code = Self.codeOnly(try Self.source("ContentView.swift"))
        #expect(code.components(separatedBy: "PaneProviderChange.decide(").count - 1 == 2,
                "one of the two provider handlers no longer goes through the rule")
        #expect(!code.contains("if pendingTabProviderChanges > 0 {"),
                "a handler is back to testing the counters inline, where the order is unpinned")
    }

    /// A tab verb the user aimed at a pane moves the keyboard focus there — and the MIRRORED half
    /// of a linked open does not.
    ///
    /// Without the first half, opening a tab on the right pane of a Compare while the ring sits on a
    /// one-tab left pane leaves ⌘W aimed left, where `closeTab`'s last-tab branch closes the WINDOW.
    /// Without the second, ⌘T in a linked Compare hands every pane-scoped chord to the sibling.
    @Test func aTabVerbMovesTheFocusToThePaneItWasAimedAt() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let body = try Self.memberBody("private func tabAction(isLeft: Bool", in: source)
        #expect(body.contains("if movesFocus { noteWorkingIn(isLeft: isLeft"),
                "a tab verb no longer says which pane the user is working in")
        // **The call site of the tested rule.** The polarity itself is no longer here to scan: it
        // moved to `FileSyncManager.noteFocusedPane(isLeft:because:)`, where
        // `theFocusedSideFollowsThePaneAVerbWasAimedAt` really calls it, because
        // `isLeft ? .left : .right` sitting in a `ContentView` extension could be flipped with all
        // 563 tests green — it aimed every tab verb at the opposite pane and nothing could see it.
        // What is left to pin here is that the host still goes through that door.
        let focus = try Self.memberBody("private func noteWorkingIn(isLeft: Bool", in: source)
        #expect(focus.contains("syncManager.noteFocusedPane(isLeft: isLeft, because: reason)"),
                "noteWorkingIn no longer routes through the manager's one door, so the polarity is back somewhere untested")
        // **The opt-out defaults to NOT opting out**, which is what lets the reachability walk
        // below read an argument-free `tabAction(` as the door.
        let code = Self.codeOnly(source)
        #expect(code.components(separatedBy: "movesFocus: Bool = true").count - 1 == 1,
                "the one door's focus move is no longer on by default, so every verb that does not mention `movesFocus` has quietly stopped moving the focus")

        // **Every `movesFocus` in the file is one this suite actually READ out of a `tabAction(`
        // call**, and which verbs may spell it is
        // `everyTabVerbAimsAllItsSideTakingCallsAtOnePane`'s structural question, not a number.
        //
        // This used to be `movesFocus:` occurrences == 3. That literal is what kills a
        // `tabAction(isLeft: isLeft, movesFocus: false)` mutation in `closeTab` — but it reports
        // `(4) == 3` rather than naming the verb, and the next LEGITIMATE opt-out bumps it to 4
        // too, at which point a wrong fourth and a right fourth are indistinguishable and the
        // tempting repair is to raise the number the assertion is entirely made of.
        let declared = Self.callArguments(of: "func tabAction(", in: code)
        #expect(declared.count == 1, "\(declared.count) declarations of the one door")
        let optOuts = Self.callArguments(of: "tabAction(", in: code)
            .filter { !declared.contains($0) && $0.contains("movesFocus:") }
        #expect(code.components(separatedBy: "movesFocus: ").count - 1 == optOuts.count + 1,
                "a `movesFocus` is spelled somewhere this scan cannot read it — an opt-out outside a `tabAction(` call is covered by nothing (the +1 is the declaration)")
        #expect(optOuts.count >= 1, "no opt-out found at all — the accounting above is vacuous")
        // The two mirrored halves, by the shape of their opt-out rather than by their whole call
        // text: `!mirrored` is ⌘T's, which opts out only for the mirrored pass, and a bare `false`
        // is the mirror's own, which always lands on the pane the user did not aim at.
        #expect(optOuts.contains { $0.contains("movesFocus: !mirrored") },
                "the mirrored ⌘T is not the opted-out one")
        #expect(optOuts.contains { $0.contains("movesFocus: false") },
                "the mirrored Open in New Tab is not the opted-out one")
    }

    /// **The polarity, on a type a test can actually call.**
    ///
    /// This is the assertion the feature never had. `noteWorkingIn` resolved the side itself with
    /// `isLeft ? .left : .right`, in a `ContentView` extension nothing can instantiate — so
    /// flipping that ternary to `isLeft ? .right : .left` aimed every tab verb at the opposite
    /// pane and left the whole 563-test app suite green. That mutation IS the shipped bug
    /// `noteWorkingIn` exists to fix: open a second tab on the RIGHT pane while the ring sits on a
    /// one-tab LEFT pane, press ⌘W, and `closeTab`'s last-tab branch closes the WINDOW.
    ///
    /// The rule lives on `FileSyncManager` now, which a test can build — so the flip is a failure
    /// rather than a survivor. The call site is pinned above; the two together are what the source
    /// scan alone could not do.
    @Test func theFocusedSideFollowsThePaneAVerbWasAimedAt() {
        let manager = FileSyncManager(fileManager: FileManager.default)
        manager.noteFocusedPane(isLeft: true, because: "a test aimed at the left pane")
        #expect(manager.focusedPaneSide == .left,
                "a verb aimed at the LEFT pane pointed the pane-scoped chords at the right one")
        manager.noteFocusedPane(isLeft: false, because: "a test aimed at the right pane")
        #expect(manager.focusedPaneSide == .right,
                "a verb aimed at the RIGHT pane pointed the pane-scoped chords at the left one")
        // Both directions, from both starting points: `isLeft ? .right : .left` is caught by the
        // pair above, but so is a door that simply toggles, and only going back catches that.
        manager.noteFocusedPane(isLeft: true, because: "back to the left pane")
        #expect(manager.focusedPaneSide == .left, "the door toggles rather than reading its argument")
        // The explicit-`nil` spelling is the one the swap uses, and it must be reachable.
        manager.noteFocusedPane(nil, because: "focus is implicit again")
        #expect(manager.focusedPaneSide == nil, "the door cannot put the focus back to implicit")
    }

    /// **Every side-taking call in the one door is aimed at the pane the door was GIVEN.**
    ///
    /// `adoptProviderForTab(id, isLeft: isLeft, …)` appears twice in `tabAction` — the `.adopt`
    /// case and the discard branch — and mutating either to `isLeft: !isLeft` left the whole suite
    /// green. That mutation is `d655b528`'s headline defect verbatim: every cross-source tab click
    /// writes the SIBLING pane's provider id, leaving it claiming one source while showing
    /// another's tree, and `saveBrowseTabs` then persists it. Only the launch-restore site was
    /// protected, by an exact-string scan.
    ///
    /// Asked as an invariant over the whole member rather than as a spelling at each site: a
    /// per-site pin is brittle and still cannot see a `!` added at the next site along. `tabAction`
    /// is the one door for a verb the user aimed at ONE pane, so reaching for the sibling anywhere
    /// inside it is the bug — not a shape to enumerate exceptions to.
    /// **…and no side-taking TERNARY may be spelled in there at all**, which is the half that used
    /// to be missing. `current: isLeft ? leftProviderId : rightProviderId` swapped to
    /// `isLeft ? rightProviderId : leftProviderId` contains neither `"isLeft: "` nor `"!isLeft"`,
    /// so it satisfied both halves above and left the whole app suite green — the headline defect
    /// back, reached by a spelling the invariant had no way to look at. The ternaries are gone: the
    /// pair is narrowed to a side by `paneProviderId(isLeft:)` and `PaneSideChoice`, whose polarity
    /// `theSideChoiceReadsItsArgument` really drives, and this bans the shape from coming back.
    @Test func theOneDoorAimsEverySideTakingCallAtThePaneItWasGiven() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let body = Self.codeOnly(try Self.memberBody("private func tabAction(isLeft: Bool", in: source))
        // The positive control: the calls this is about are in here at all. Without it, a member
        // that had lost every one of them would satisfy every invariant below.
        #expect(body.components(separatedBy: "adoptProviderForTab(").count - 1 == 2,
                "the two adopt sites this is about are no longer both in the one door")
        #expect(body.contains("noteWorkingIn(isLeft: "),
                "the one door no longer says which pane the user is working in")
        let reads = body.components(separatedBy: "paneProviderId(isLeft: ").count - 1
        #expect(reads >= 4,
                "\(reads) reads of this pane's provider id in the one door — it has stopped asking through the one wrapper, and the pair-to-side arguments are loose in here again")

        // Every `isLeft:` argument in here names `isLeft` itself, compared as a TOKEN: the count
        // form this replaced was balanced by any local whose name merely STARTS with `isLeft`.
        let tokens = Self.argumentTokens(labelled: "isLeft", in: body)
        // TODAY'S measured count (12), not a number chosen low enough to be safe: a floor well
        // under the actual passes with half the calls gone.
        #expect(tokens.count >= 12,
                "\(tokens.count) `isLeft:` arguments in the one door where 12 are expected — it has lost calls this is meant to cover")
        let strays = tokens.filter { $0 != "isLeft" }
        #expect(strays.isEmpty,
                "\(strays) named instead of the pane the one door was given — a verb aimed at one pane is acting on the other")
        // …and nothing in here reaches for the sibling under any other label either
        // (`refreshForTabSwitch(movedPane:)` spells it differently, and would be missed above).
        #expect(!body.contains("!isLeft"),
                "the one door reaches for the SIBLING pane — every verb through it is aimed at exactly one pane, and the mirrored openers opt out before they get here")

        // **The ternary and the bare pair, both banned.** A swapped ternary is invisible to every
        // check above it; so is `if isLeft { … leftProviderId … } else { … rightProviderId … }`,
        // which is the shape someone reaches for once the ternary is refused.
        #expect(!body.contains("isLeft ?"),
                "a side-taking ternary is back in the one door — swapping it re-creates the headline defect and is invisible to every argument check here; narrow the pair through `paneProviderId(isLeft:)` or `PaneSideChoice.own`")
        for bare in ["leftProviderId", "rightProviderId"] {
            #expect(!body.contains(bare),
                    "the one door reads `\(bare)` directly — the pane's own value must come through `paneProviderId(isLeft:)`, which is the one place the view's PAIR is narrowed to a SIDE")
        }

        // The arguments `PaneSideChoice` itself cannot see are checked by
        // `everyPaneSideChoiceCallNarrowsAMatchedPair`, which reads them across the whole app
        // target rather than this one file — `PaneSideChoice` is app-wide, and a scan of one file
        // is a registry pretending to be a derivation.
    }

    /// **The verbs that reach the focus door THEMSELVES, and aim it at the pane they were given.**
    ///
    /// Three verbs never entered the one door — Pin/Unpin, drag-to-reorder and Copy Path — and the
    /// polarity invariant above is scoped to `tabAction`'s body, so `noteWorkingIn(isLeft: !isLeft)`
    /// survived the whole suite in every one of them. That is verbatim the sentence `becf9cbd`'s
    /// commit body describes: right-click a chip in the RIGHT strip ▸ Copy Path with a one-tab LEFT
    /// pane focused, press ⌘W, and `closeTab`'s last-tab branch closes the WINDOW.
    ///
    /// Two of the three are fixed structurally rather than by a scan: `setTabPinned` and `moveTab`
    /// now go through `tabAction` with a `nil` answer, which is the same four steps in the same
    /// order and puts them under every invariant above. Copy Path cannot — it must bail on a chip
    /// this strip does not hold BEFORE it moves anything, and it saves no strip — so it is the one
    /// member left holding a focus door of its own, and it is checked here by name.
    @Test func theVerbsOutsideTheOneDoorAimItAtThePaneTheyWereGiven() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let file = Self.codeOnly(source)

        // Exactly two members hold a focus door: the one door, and Copy Path. A third would be a
        // verb that has grown its own polarity again, unseen by every check here.
        let doors = file.components(separatedBy: "noteWorkingIn(").count - 1
        #expect(doors == 3,
                "\(doors - 1) call sites of the focus door in this file where 2 are expected (the third match is its declaration) — a verb outside the one door aims the pane-scoped chords itself, and nothing below covers it")

        let copy = Self.memberInterior(
            Self.codeOnly(try Self.memberBody("func copyTabPath(id: UUID, isLeft: Bool)", in: source)))
        #expect(Self.topLevelCall("noteWorkingIn(", in: copy) == .found,
                "Copy Path's focus move is conditional or unreachable — right-click a chip in the other strip, press ⌘W, and the last-tab branch closes the WINDOW")
        let copyStrays = Self.argumentTokens(labelled: "isLeft", in: copy).filter { $0 != "isLeft" }
        #expect(copyStrays.isEmpty,
                "\(copyStrays) in Copy Path name something other than the pane it was given")
        #expect(!copy.contains("!isLeft"), "Copy Path reaches for the SIBLING pane")
        #expect(!copy.contains("isLeft ?"),
                "a side-taking ternary is back in Copy Path — swapping it aims the chords at the pane the user is not looking at, and no argument check here can see it")
        // …and it refuses during bootstrap, like every other strip verb. This was the one that did
        // not: it moved the chords against a pane whose source the bootstrap had not chosen yet.
        #expect(Self.topLevelCall("guard !isBootstrappingProviders", in: copy) == .found,
                "Copy Path acts during the provider bootstrap, where every other tab verb refuses")

        // The two that were fixed by construction: through the one door, unconditionally.
        for verb in ["func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                     "func moveTab(id: UUID, to index: Int, isLeft: Bool)"] {
            let body = Self.memberInterior(Self.codeOnly(try Self.memberBody(verb, in: source)))
            #expect(Self.topLevelCall("tabAction(isLeft: isLeft)", in: body) == .found,
                    "“\(verb)” is back outside the one door, or its call is inside a branch — `if pinned { … }` around it is a measured survivor, and unpinning then leaves ⌘W aimed at the other pane")
            #expect(!body.contains("noteWorkingIn("),
                    "“\(verb)” keeps a focus door of its own alongside the one door's — two moves, one of which no invariant reads")
            let strays = Self.argumentTokens(labelled: "isLeft", in: body).filter { $0 != "isLeft" }
            #expect(strays.isEmpty, "\(strays) in “\(verb)” name something other than the pane it was given")
        }
    }

    /// **Every tab verb the HOST wires reaches the focus door unconditionally — derived from every
    /// file that wires one, with the derivation's own blind spot closed rather than described.**
    ///
    /// This started as a hand-written pair of signatures, which is a registry and not the whole
    /// set — `copyTabPath` was simply missing. Reading the set off the wiring instead fixed that
    /// and then made **the derivation's input file the new registry**: it regexed `on…: { … }`
    /// closures over the whole of `ContentView.swift`, so two of the nine it found came from the
    /// file-tree and header-card wiring rather than the strip, and `cycleTab` and `reopenClosedTab`
    /// — both strip-aimed, both wired in `ShortcutCommands.swift` and `ContentView+PaneSearch.swift`
    /// as `var shortcut…` closures rather than as `on…:` arguments — were invisible to it. The
    /// claim "the next verb added is covered by construction" was false for anything added there.
    ///
    /// So the set is every member of this file that any host file CALLS, and the derivation is
    /// closed at both ends:
    ///
    /// - **Which files may wire one is asserted, not assumed.** Every `MacApp/**` Swift file is
    ///   walked and any that calls into this file must be one of the three below — a fourth fails
    ///   here by name instead of quietly falling outside the scan.
    /// - **Which of those calls are VERBS** is the one judgement left, and it is spelled out: the
    ///   readers (`paneTabItems`, `paneShowsTabStrip`, `seamInset`) and the launch/quit persistence
    ///   pair (`saveBrowseTabs`, `restoreBrowseTabs`) must not move a focus, because nothing a user
    ///   aimed at a pane happened. Each exclusion is asserted to BE in the derived set, so a rename
    ///   or a removal fails here rather than silently hiding a real verb behind a stale name.
    ///
    /// **What it proves about each verb is stronger than "the text mentions a door".** That reading
    /// is satisfied by a call inside an `if`, after an early `return`, or in a closure nothing
    /// invokes — the first of those being a measured survivor. `topLevelCall` answers on brace
    /// depth instead, so the guarantee is: on every path through the member that does not bail out
    /// early, the door is called. It still cannot see a door reached only through a THIRD member,
    /// nor one whose *arguments* are wrong (that is `theOneDoorAims…`'s half), nor anything wired
    /// outside `MacApp/`.
    ///
    /// **…and the walk now means that.** It accepted any top-level `tabAction(`, but the door
    /// inside `tabAction` is `if movesFocus { noteWorkingIn(…) }` — inside a branch — so what the
    /// walk actually guaranteed was "reaches a function that MAY call the door". The thing that
    /// killed `tabAction(isLeft: isLeft, movesFocus: false)` in `closeTab` was an unrelated spelling
    /// count elsewhere, reporting `(4) == 3`. The walk reads the call's own arguments now: a
    /// `tabAction(` that passes `movesFocus: false` is not a door, so that mutation fails HERE, by
    /// the name of the verb that stopped moving the focus.
    ///
    /// A `movesFocus: !mirrored` still counts, and that is a modelling choice worth stating: the
    /// door runs for the unmirrored pass, which is the one the verb's own pane takes, and the
    /// mirrored pass is `openNewTabHere`'s deliberate second call onto the sibling. What makes the
    /// model honest rather than convenient is that `tabAction`'s door shape and its `= true`
    /// default are asserted in `aTabVerbMovesTheFocusToThePaneItWasAimedAt`, and every opt-out has
    /// to justify itself structurally in `everyTabVerbAimsAllItsSideTakingCallsAtOnePane`.
    @Test func everyTabVerbTheHostWiresReachesTheFocusDoorUnconditionally() throws {
        let tabs = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        // The extension's own members, not the file's: the helper types below it declare `items`,
        // `shows`, `inset` and `decide`, and names that common would match half the host.
        let extensionBody = try Self.typeBody("extension ContentView {", in: tabs)
        let declared = Set(Self.matches(#"\n    (?:private )?func ([a-zA-Z]\w*)\("#,
                                        in: extensionBody, group: 1))
        #expect(declared.count >= 20,
                "\(declared.count) members found in the tabs extension — the member scan is reading the wrong thing")
        #expect(declared.isSuperset(of: ["copyTabPath", "tabAction", "noteWorkingIn", "tabLogDescription"]),
                "the member scan lost members that are plainly there — every check below would be vacuous")
        #expect(!declared.contains("decide") && !declared.contains("items"),
                "the member scan has spilled out of the extension into the helper types below it")

        // Which host files wire into this file at all. Walked recursively: a `MacApp/Tabs/` folder
        // is the obvious next shape, and a flat listing would not see it.
        let macApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        let hostFiles = Self.swiftFiles(under: macApp)
        #expect(hostFiles.count > 20,
                "the host walk found \(hostFiles.count) Swift files — it is reading the wrong folder, or the enumerator yielded nothing")

        // `ContentView+FolderSidebar.swift` joined the list in v4.2: the Browse sidebar's ⌘-click
        // opens a remembered folder in a new tab, which is `openInNewTab` — a verb of this file.
        // The derivation reads it for exactly the reason it reads the other three; this test is
        // what noticed, by name, on the first full run after the sidebar landed.
        //
        // **It stays here while the sidebar is held for v4.3** (`FolderSidebarModel.isEnabled`).
        // The call is unreachable, not gone, so the coverage this derivation gives it is what keeps
        // the verb correct for the release that turns the column on — dropping the file from this
        // list because "nothing runs it" would silently uncover it on the day it runs again.
        let wiringFiles = ["ContentView.swift", "ShortcutCommands.swift", "ContentView+PaneSearch.swift",
                           "ContentView+FolderSidebar.swift"]
        var derived: Set<String> = []
        for file in hostFiles where file.lastPathComponent != "ContentView+PaneTabs.swift" {
            let code = Self.codeOnly(try String(contentsOf: file, encoding: .utf8))
            let calls = Set(Self.matches(#"\b([a-z][A-Za-z0-9]*)\("#, in: code, group: 1))
                .intersection(declared)
            guard !calls.isEmpty else { continue }
            #expect(wiringFiles.contains(file.lastPathComponent),
                    "\(file.lastPathComponent) calls \(calls.sorted()) in the tabs file and is not one of the wiring files this derivation reads — a verb wired there is covered by nothing")
            derived.formUnion(calls)
        }

        // The readers and the persistence pair: called by the host, and deliberately not verbs.
        let notVerbs = ["paneTabItems", "paneShowsTabStrip", "seamInset",
                        "saveBrowseTabs", "restoreBrowseTabs"]
        for excluded in notVerbs {
            #expect(derived.contains(excluded),
                    "“\(excluded)” is excluded from this rule as a reader, and the derivation no longer finds it being called at all — the exclusion is now a name that could be hiding a real verb")
        }
        let verbs = derived.subtracting(notVerbs)
        #expect(verbs.count >= 11,
                "the host's wiring resolved to \(verbs.count) verbs (\(verbs.sorted())) — the derivation has stopped finding them, and every check below is vacuous")
        // The two the old derivation could not see, named so their loss is not silent.
        for named in ["copyTabPath", "selectTab", "moveTab", "setTabPinned", "openNewTabHere",
                      "cycleTab", "reopenClosedTab"] {
            #expect(verbs.contains(named),
                    "“\(named)” is wired to a pane's tab strip and the derivation did not find it")
        }

        /// Whether `name` reaches the focus door on every path that does not bail out early —
        /// directly, or through one more member of this file. Two hops is what ⌘T needs:
        /// `openNewTabHere` mirrors through `openTabHere` to `tabAction`.
        func reachesTheFocusDoor(_ name: String, hops: Int) throws -> Bool {
            let body = Self.memberInterior(try Self.memberBodyNamed(name, in: tabs))
            if Self.topLevelCall("noteWorkingIn(", in: body) == .found { return true }
            // `tabAction(` is the door only when the call has not opted out of it. Reading the
            // call's own arguments is what makes this walk mean its name: `movesFocus: false` puts
            // `noteWorkingIn` behind a branch that is known to be false, so a verb whose only route
            // to the door is such a call reaches no door at all.
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

        // The negative control, first: a member of this same file that describes a tab for the log
        // and moves no focus. If this answers YES the walk cannot fail, and every verb below passes
        // for free.
        #expect(try !reachesTheFocusDoor("tabLogDescription", hops: 2),
                "the reachability walk says a member that touches no focus door reaches one — it cannot fail, so nothing below it means anything")
        // **The second negative control, and the one the walk had none of.** `mirrorOpenInNewTab`
        // goes through `tabAction` on every path and deliberately opts out of the focus door, so a
        // walk that reads `tabAction(` as a door regardless of its arguments answers YES here — the
        // reading under which the guarantee was only "reaches a function that MAY call the door".
        #expect(try !reachesTheFocusDoor("mirrorOpenInNewTab", hops: 2),
                "the walk counts a `tabAction(…, movesFocus: false)` as reaching the focus door — under that reading `tabAction(isLeft: isLeft, movesFocus: false)` in any verb below passes here, and nothing names the verb that stopped moving the focus")

        for verb in verbs.sorted() {
            #expect(try reachesTheFocusDoor(verb, hops: 2),
                    "“\(verb)” is wired to a pane's tab strip and does not say which pane the user is working in on every path — in Compare that leaves ⌘W aimed at the other pane, where its last-tab branch closes the WINDOW")
            // …and it acts on the pane it was GIVEN. Reaching the door is not enough: a verb that
            // hands the door its sibling aims every pane-scoped chord at the wrong strip, which is
            // the same shipped bug from one level up. A verb MAY reach for the sibling on purpose —
            // ⌘T's mirrored half opens a tab on the OTHER pane — but only through
            // `PaneSideChoice.sibling`, whose polarity `theSideChoiceReadsItsArgument` really
            // drives. That exception used to be the literal `["!isLeft"]` written against
            // `openNewTabHere` by name; it is derived from the member's own bindings now, so a
            // second deliberate mirror does not need this line edited and a hand-written `!` is
            // refused wherever it appears.
            let hand = Self.handWrittenSideTokens(
                in: Self.memberInterior(try Self.memberBodyNamed(verb, in: tabs)))
            #expect(hand.isEmpty,
                    "“\(verb)” passes \(hand) where the pane it was given, or a sibling taken through `PaneSideChoice.sibling`, is expected — the verb acts on the pane the user did not aim at")
        }
    }

    /// **The comment stripper this suite scans through is the corrected one, not a third copy.**
    ///
    /// ``codeOnly`` was byte-for-byte the whole-line filter `538ac2e1` replaced in
    /// `SyncCloudTests.swift` — satisfiable by a comment written after code on any line. The large
    /// majority of this suite's scans read it, including positive controls whose whole job is to
    /// stop the rest of a test passing vacuously.
    ///
    /// Both directions here, because only one of them is obvious: a trailing comment must not
    /// answer a `contains`, and a `//` inside a string literal must not eat real code. The stripper
    /// does not parse multiline or raw string literals, so — as its own test does for the file it
    /// reads — that limit is asserted against the file THIS suite scans rather than assumed.
    @Test func theCommentStripperIsTheCorrectedOne() throws {
        let stripped = Self.codeOnly("""
            let a = 1 // noteWorkingIn(isLeft:
            /* block noteWorkingIn(isLeft: */ let b = 2
            let url = "https://example.com" // tail
            real()
            """)
        #expect(!stripped.contains("noteWorkingIn(isLeft:"),
                "a trailing or block comment survives `codeOnly`, so this suite's positive controls can be satisfied by prose with the real call deleted")
        #expect(stripped.contains("let a = 1") && stripped.contains("let b = 2")
                && stripped.contains("\"https://example.com\"") && stripped.contains("real()"),
                "`codeOnly` ate real code — a stripper that returns nothing satisfies every absence check above")
        // …and the brace-depth desynchronisation the old filter caused, which `topLevelCall` reads.
        #expect(Self.topLevelCall("noteWorkingIn(", in: Self.codeOnly("""
                if x { save() } // a } and a { in prose
                noteWorkingIn(isLeft: isLeft, "x")
            """)) == .found,
                "braces inside a trailing comment still shift the depth counter, so a top-level call reads as being inside a branch")

        // The stated limit, asserted rather than assumed, on the file this suite actually scans.
        let raw = try Self.source("ContentView+PaneTabs.swift")
        #expect(!raw.contains("\"\"\"") && !raw.contains("#\""),
                "the tabs file has grown a multiline or raw string literal, which the stripper does not parse — it would mis-read from there to the end of the file")
    }

    /// **Every reach for the SIBLING pane in the tabs file goes through the one flip.**
    ///
    /// `let other = !isLeft` in `mirrorOpenInNewTab`, with the `!` dropped, survived the whole app
    /// suite: ⌥/linked **Open in New Tab** then opened both tabs on the pane the user aimed at and
    /// none on the sibling. ⌘T's identical mirror WAS pinned — `openTabHere(isLeft: !isLeft` was an
    /// exact-string scan — so the two mirrors of one feature were guarded to different standards
    /// and the unguarded one is where the defect was.
    ///
    /// A `!` in a `ContentView` extension is a spelling nothing can drive, so the fix is not a
    /// tighter scan: the polarity is `PaneSideChoice.sibling` now, which
    /// `theSideChoiceReadsItsArgument` really calls in both directions. What is left for a scan is
    /// the part a value cannot state — that the hand-written form does not come back, anywhere in
    /// the file, including at sites that do not exist yet.
    @Test func everyReachForTheSiblingPaneGoesThroughTheOneFlip() throws {
        let file = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        // The flip exists, and it is the ONLY one written out in the file. Its BEHAVIOUR is
        // `theSideChoiceReadsItsArgument`'s; this is only that there is one of it.
        let flips = file.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("!isLeft") }
        #expect(flips.count == 1,
                "\(flips.count) hand-written `!isLeft` in the tabs file where 1 is expected (`PaneSideChoice.sibling`'s own body) — a side flip outside it is a polarity no test can drive")
        #expect(flips.first?.contains("static func sibling(") == true,
                "the one `!isLeft` in the file is not `PaneSideChoice.sibling`'s — the flip has moved back somewhere a test cannot call it")

        let extensionBody = try Self.typeBody("extension ContentView {", in: file)
        let declared = Set(Self.matches(#"\n    (?:private )?func ([a-zA-Z]\w*)\("#,
                                        in: extensionBody, group: 1))
        #expect(declared.count >= 20,
                "\(declared.count) members found in the tabs extension — the member scan is reading the wrong thing and every check below is vacuous")

        var mirrors: Set<String> = []
        for member in declared.sorted() {
            let body = Self.memberInterior(try Self.memberBodyNamed(member, in: file))
            if !Self.siblingLocals(in: body).isEmpty { mirrors.insert(member) }
            let hand = Self.handWrittenSideTokens(in: body)
            #expect(hand.isEmpty,
                    "“\(member)” passes \(hand) as a side — the pane it was given, or a sibling bound through `PaneSideChoice.sibling`, is what a side argument may name")
        }
        // **The derived set, not a floor.** A member that stops mirroring and one that starts both
        // land here, and the second is the one worth a look: reaching for the sibling is a real
        // decision (it is what puts a tab on the pane the user did not aim at) and it should not
        // arrive unremarked.
        #expect(mirrors == ["paneShowsTabStrip", "openNewTabHere", "mirrorOpenInNewTab"],
                "the members reaching for the sibling pane are \(mirrors.sorted()) — a member has started or stopped mirroring, and which panes a verb touches is not a thing to change silently")
    }

    /// **A tab verb aims every side-taking call it makes at the ONE pane it moves.**
    ///
    /// `theOneDoorAimsEverySideTakingCallAtThePaneItWasGiven` says this of `tabAction`'s own body,
    /// and that scoping is exactly why the location pair went unguarded: the three `openedFromScope:`
    /// cuts, the save's overlay and `ColumnStackPruning` are all outside it. Transposing any of them
    /// left the whole app suite green.
    ///
    /// Stated over the verbs instead of over one member, and derived: the pane a verb moves is
    /// whatever it hands `tabAction`, and every other side it computes has to be the same one. A
    /// `paneScope(isLeft: !isLeft)` — the shape the `openedFromScope` transposition takes once the
    /// ternary is gone — is a different token from the verb's own aim and fails here by name.
    ///
    /// **The opt-out justifies itself structurally**, which is what the `movesFocus:` count could
    /// not do. A verb may decline to move the focus only when it is landing on the sibling
    /// (`movesFocus: false`, aimed at a `PaneSideChoice.sibling` local) or when the decline is its
    /// caller's mirror flag (`movesFocus: !mirrored`, on a member whose `mirrored` defaults to
    /// false). A `tabAction(isLeft: isLeft, movesFocus: false)` in any ordinary verb matches
    /// neither, and fails naming the verb rather than reporting `(4) == 3`.
    @Test func everyTabVerbAimsAllItsSideTakingCallsAtOnePane() throws {
        let file = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        let extensionBody = try Self.typeBody("extension ContentView {", in: file)
        let declared = Set(Self.matches(#"\n    (?:private )?func ([a-zA-Z]\w*)\("#,
                                        in: extensionBody, group: 1))

        var aims: [String: String] = [:]
        var optOuts: [String: String] = [:]
        for member in declared.sorted() {
            let body = Self.memberInterior(try Self.memberBodyNamed(member, in: file))
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
        // Measured today: eleven verbs go through the one door. A floor well under it passes with
        // half of them gone, so this is the count, not a safe number.
        #expect(aims.count >= 11,
                "\(aims.count) members run a verb through the one door where 11 are expected — the derivation has stopped finding them and every check above is vacuous")
        #expect(Set(aims.keys).isSuperset(of: ["openTabHere", "openInNewTab", "mirrorOpenInNewTab",
                                               "closeTab", "selectTab", "setTabPinned"]),
                "the derivation lost verbs that are plainly there — it is reading the wrong members")
        // The mirror aims at a pane that is not its own `isLeft`; every other verb aims at `isLeft`.
        // Without this, "every aim is the same token" satisfies everything above. Unwrapped rather
        // than compared with `!=`: a missing entry makes `nil != "isLeft"` TRUE, so the shape that
        // reads as the strongest check here is the one that passes when the derivation found
        // nothing.
        let mirrorAim = try #require(aims["mirrorOpenInNewTab"],
                                     "the mirror no longer runs its open through the one door")
        #expect(mirrorAim != "isLeft",
                "the mirror moves the pane it was given rather than the sibling — the linked half opens on the wrong pane")
        #expect(aims["openTabHere"] == "isLeft", "⌘T moves a pane other than the one it was given")

        #expect(!optOuts.isEmpty, "no verb opts out of the focus door — the checks below are vacuous")
        for (member, value) in optOuts.sorted(by: { $0.key < $1.key }) {
            let body = Self.memberInterior(try Self.memberBodyNamed(member, in: file))
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

    /// **Every pane PAIR read in the tabs file is narrowed by the one door, or by a member asserted
    /// to want both sides.**
    ///
    /// The commit that introduced `paneProviderId(isLeft:)` said the hand-written
    /// `isLeft ? leftX : rightX` were "gone" and that the view's pair was narrowed to a side in one
    /// place. It was true of `…ProviderId` and of nothing else: `leftRelativePath`/`rightRelativePath`,
    /// `leftBrowsePath`/`rightBrowsePath`, `leftTreeRoot`/`rightTreeRoot` and the two children
    /// indexes were still cut by hand at five sites in the same file, and the invariant that bans
    /// the shape is scoped to `tabAction`'s body, which none of them is in.
    ///
    /// So the ban is stated over the PAIR rather than over one member's text: a token from either
    /// half of a pane pair may appear only inside a `PaneSideChoice.own(…)` call, on the line that
    /// DECLARES a stored property named for one side, or inside one of three members that
    /// legitimately read both. Each of those three is asserted to still exist and still hold a pair
    /// token, so an exemption cannot outlive the code it was written for and become a hole with a
    /// name on it.
    ///
    /// This sees the ternary, the `if isLeft { … } else { … }` someone reaches for once the ternary
    /// is refused, and any other shape — what it cannot see is a narrowing whose sides are
    /// transposed INSIDE the `own(…)` call, which is
    /// `everyPaneSideChoiceCallNarrowsAMatchedPair`'s half.
    @Test func everyPaneLocationPairIsNarrowedByTheOneDoorOrAnAssertedException() throws {
        let file = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        let pairs = Self.occurrences(
            #"\b(?:left|right)(?:RelativePath|BrowsePath|TreeRoot|ChildrenIndex|ProviderId)\b"#,
            in: file)
        // TODAY'S measured count (28), not a number chosen low enough to be safe. The floor is only
        // "am I reading the file at all" — nothing is lost by a pair token going away, since the
        // rule below is about the ones that are THERE.
        #expect(pairs.count >= 28,
                "\(pairs.count) pane-pair tokens found in the tabs file where 28 are expected — the scan is reading the wrong text and every judgement below is vacuous")

        let narrowings = Self.callSpans(of: "PaneSideChoice.own(", in: file)
        #expect(narrowings.count >= 6,
                "\(narrowings.count) `PaneSideChoice.own` calls in the tabs file where at least 6 are expected — the pairs are being narrowed somewhere this cannot see")

        // The three that read BOTH sides on purpose. Named, and each proved non-vacuous below: the
        // adopt helper writes one id and re-keys the ignored-items store on the PAIR, the reload
        // resolves both providers because it refreshes a comparison, and the persistence modifier
        // watches all six values because either pane moving has to save that pane's strip.
        var exemptions: [(name: String, span: Range<String.Index>)] = []
        for (name, declaration, closing) in
                [("adoptProviderForTab", "private func adoptProviderForTab(", "\n    }\n"),
                 ("refreshForTabSwitch", "private func refreshForTabSwitch(movedPane isLeft: Bool)", "\n    }\n"),
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
            // A stored property named for one side of a pair its owner is HANDED — `let
            // leftTreeRoot: String`. The declaration is not a narrowing and cannot be transposed;
            // its uses below are what this rule is about.
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

    /// **Every `PaneSideChoice.own` call in the app target hands it a MATCHED pair, on the side it
    /// says.**
    ///
    /// Two holes, and the first is the one a per-argument check cannot have:
    /// `own(isLeft, left: syncManager.leftRelativePath, right: syncManager.rightBrowsePath)` passes
    /// "every `left:` is left-ish, every `right:` is right-ish" because each argument contains its
    /// own side's word — and it narrows two different pairs, so what comes back is a folder for one
    /// side and a column stack for the other. Blanking the side word turns that into a comparison
    /// the scan can make.
    ///
    /// The second is scope: this read `ContentView+PaneTabs.swift` alone while `PaneSideChoice` is
    /// app-target-wide — `CompareReviewReducer` and `DuplicateReviewCoordinator` already use it. A
    /// scan of one file is a registry pretending to be a derivation, which is the shape this repo
    /// keeps re-finding, so the whole of `MacApp/**` is walked and the known users are asserted to
    /// be IN the derived set rather than assumed to be all of it.
    @Test func everyPaneSideChoiceCallNarrowsAMatchedPair() throws {
        let macApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        let hostFiles = Self.swiftFiles(under: macApp)
        #expect(hostFiles.count > 20,
                "the host walk found \(hostFiles.count) Swift files — it is reading the wrong folder, or the enumerator yielded nothing")

        var users: Set<String> = []
        var narrowings: [(file: String, call: SideNarrowing?)] = []
        for url in hostFiles {
            let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            guard code.contains("PaneSideChoice.") else { continue }
            users.insert(url.lastPathComponent)
            for call in Self.sideNarrowings(in: code) {
                narrowings.append((url.lastPathComponent, call))
            }
        }
        // The derivation found the users it must find. Without this the loop below is satisfied by
        // reading nothing at all.
        #expect(users.isSuperset(of: ["ContentView+PaneTabs.swift", "CompareReviewReducer.swift",
                                      "DuplicateReviewCoordinator.swift"]),
                "the derivation found \(users.sorted()) as the users of `PaneSideChoice` and is missing one that plainly uses it — it is reading the wrong tree")
        #expect(narrowings.count >= 6,
                "\(narrowings.count) `PaneSideChoice.own` calls found across the app target where at least 6 are expected — the checks below are vacuous")
        // …and a known call site really is in the set, read whole. This one wraps over two lines and
        // nests a call inside its argument, which is the shape the regex this replaced could not
        // see at all.
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

    /// The fixture for the pair reader, and for the two holes it closes. Handed known text, because
    /// the production file is (and must stay) correct — a scan proved only against correct source
    /// is a scan nobody has watched fail.
    @Test func theSideNarrowingScanSeesAMismatchedPair() throws {
        let mismatched = Self.sideNarrowings(
            in: "PaneSideChoice.own(isLeft, left: m.leftRelativePath, right: m.rightBrowsePath)")
        let bad = try #require(mismatched.first ?? nil, "the reader could not parse a one-line call")
        #expect(Self.sideStemmed(bad.left) != Self.sideStemmed(bad.right),
                "a `left:`/`right:` pair drawn from two DIFFERENT pairs reads as matched — the hole a per-argument check cannot see, since each argument contains its own side's word")

        // …and the matched pair it must not flag, wrapped over two lines with a nested call in its
        // argument: the shape the regex this replaced stopped dead at.
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

        // And an unreadable call comes back as `nil` rather than being skipped — the difference
        // between "this scan does not cover it" and "there is nothing to cover".
        #expect(Self.sideNarrowings(in: "PaneSideChoice.own(isLeft, first, second)") == [nil],
                "a call in a shape the reader does not understand is silently dropped instead of reported")
    }

    /// **`focusedPaneSide` has one writer in the host, and it is the manager's door.**
    ///
    /// Five places wrote the property bare and none of them logged — a strip verb, a row selection,
    /// ⌃⇥, a pin and a reorder. The value decides whether ⌘W closes a tab or the WINDOW, so a user
    /// auditing a log that shows a window closing had nothing at all saying which pane the chords
    /// were aimed at. The door writes the line; a sixth bare writer would be silent again.
    ///
    /// Scanned as an ABSENCE across every file in `MacApp/`, not per known site: a per-site check
    /// passes the moment a new one appears, which is exactly how this got to five.
    ///
    /// **Recursively, and over the modules and the CLI too.** The walk was
    /// `contentsOfDirectory(at: MacApp)` — one level deep, `MacApp/*.swift` only — and
    /// `focusedPaneSide` is a `@Published public var`, writable from `Sync`, `FileExplorer`,
    /// `Settings`, `Dashboard` and `SyncCloudCLI`. No bare writer lives outside `MacApp/` today, so
    /// this widening breaks nothing; what it removes is the gap that opens the moment anybody makes
    /// a `MacApp/Tabs/` folder or reaches for the property from a module.
    ///
    /// The **one** production file allowed to write it is the one that DECLARES the door. Named
    /// rather than pattern-matched, so a second file cannot join it by resembling it. Test sources
    /// are out of scope — `SwapPanesTests` sets the property directly to build a starting state,
    /// which is a fixture, not a silent move.
    @Test func theHostWritesTheFocusedPaneSideOnlyThroughTheManagersDoor() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let macApp = repo.appendingPathComponent("MacApp")
        let hostFiles = Self.swiftFiles(under: macApp)
        #expect(hostFiles.count > 20,
                "the host scan found \(hostFiles.count) Swift files — it is reading the wrong folder, or the enumerator yielded nothing")

        // Every shipping source outside the host, minus the tests: `Tests` directories hold
        // fixtures that legitimately seed the property.
        let elsewhere = (Self.swiftFiles(under: repo.appendingPathComponent("Modules"))
                         + Self.swiftFiles(under: repo.appendingPathComponent("SyncCloudCLI")))
            .filter { !$0.pathComponents.contains("Tests") }
        // The floor is near today's measured 285, not a round number well under it: a loose floor
        // is passed by a walk that has stopped reading most of the tree.
        #expect(elsewhere.count >= 250,
                "the module scan found \(elsewhere.count) Swift files where ~285 are expected — it is reading the wrong folder, or the walk stopped early")

        /// The file that declares the door, and the only place the property may be written bare.
        let declaringFile = "FileSyncManager+Navigation.swift"
        var doors = 0
        var declaredWrites = 0
        for file in hostFiles + elsewhere {
            let code = Self.normalizingAssignments(
                Self.codeOnly(try String(contentsOf: file, encoding: .utf8)))
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

    /// **A focus move is logged with its cause, and a move that moves nothing says nothing.**
    ///
    /// `focusedPaneSide` decides whether ⌘W closes a tab or the window — this feature's one
    /// destructive outcome — and after the strip verbs started moving it, it moves on a chip click,
    /// the ＋, the header card's New Tab, the pane background menu, a reorder drag and a pin. None
    /// of those wrote anything, so a report of "⌘W closed my window" had no trace to read.
    ///
    /// The silent half is not tidiness: the commonest way to reach this door is clicking a row in
    /// the pane you are already working in, and a defect in this exact area logged the most
    /// ordinary gesture in the strip (clicking the chip you are already on) into the log he audits.
    ///
    /// **Read between this test's own markers, with the cause carrying a token.** `Logger.shared`
    /// is process-wide and `entries` is a rolled 1000-line window, so the opener is `#require`d as
    /// the eviction guard and the reason strings are unique to this run — nothing else in the
    /// process can write a line this reading then counts, in either direction.
    @Test func aFocusMoveIsLoggedWithItsCauseAndANoOpIsNot() async throws {
        let manager = FileSyncManager(fileManager: FileManager.default)
        let token = String(UUID().uuidString.prefix(8))

        await Logger.shared.debug("focus window open \(token)").value
        manager.noteFocusedPane(isLeft: false, because: "moved \(token)")
        // The same side again: nothing changes, so nothing may be said.
        manager.noteFocusedPane(isLeft: false, because: "again \(token)")
        await Logger.shared.debug("focus window close \(token)").value

        let messages = Logger.shared.entries.map(\.message)
        let opened = try #require(messages.firstIndex(where: { $0.contains("open \(token)") }),
                                  "the log window rolled past this test's own marker, so this reading is vacuous")
        // Sliced from the opener FIRST and searched inside that slice, so the two indices cannot be
        // found out of order — `messages[a...b]` traps rather than failing when they are.
        let tail = messages[opened...]
        let closed = try #require(tail.lastIndex(where: { $0.contains("close \(token)") }),
                                  "the closing marker never landed — this reading is vacuous")
        let window = tail[...closed]

        let moved = window.filter { $0.contains("moved \(token)") }
        #expect(moved.count == 1,
                "\(moved.count) lines for one focus move — a move of the pane-scoped chords is unlogged, so a window that closed has no trace of which pane ⌘W was aimed at")
        #expect(moved.first?.contains("the right pane") == true,
                "the line does not name the pane the chords now aim at, which is the whole question it exists to answer")
        #expect(moved.first?.contains("⌘W") == true,
                "the line does not name the chord whose destructive outcome this value decides")
        #expect(!window.contains(where: { $0.contains("again \(token)") }),
                "re-aiming at the pane already focused wrote a line — the log fills with the most ordinary gesture in the strip and buries the moves that explain a window closing")
    }

    /// …and an arrival that DOES move the pane reloads exactly once, from the host.
    ///
    /// The "which arrivals" half is `theScanIsGatedOnTheSameRuleTheInvalidationUses` above — a
    /// switch inside one source at one scope reloads nothing. What is pinned here is the half that
    /// has not changed: `applyTab` must not ring `refreshSubject` itself, because it runs *before*
    /// the provider id is written and would load the new tab's path under the old tab's root.
    @Test func theReloadIsDrivenByTheHostAndNotByApplyTab() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("refreshForTabSwitch(movedPane: isLeft)"),
                "a tab switch never reloads — a source change would keep the previous tab's tree")
        let sync = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Sync/Sources/Sync/FileSyncManager+PaneTabs.swift"),
                              encoding: .utf8)
        // Sliced on the prefix, not the whole signature: this scan broke once already when the
        // parameter list grew, reporting "applyTab is gone" for a member that was right there.
        let apply = try Self.memberBody("public func applyTab(_ tab: PaneTab, isLeft: Bool", in: sync)
        let applyCode = Self.codeOnly(apply)
        #expect(!applyCode.contains("syncPathsFromHistory()") && !applyCode.contains("refreshSubject"),
                "applyTab rings the refresh itself — it runs before the provider id is written")
    }

    // MARK: ⌘W, which replaced File ▸ Close

    /// **⌘W must still close a window that has no tabs.** This item takes the standard Close
    /// group's place, and the app has three auxiliary `Window` scenes — Keyboard Shortcuts,
    /// Activity Log, Sync History — none of which publishes a focused value. Disabled on `nil`,
    /// which is how every other item in that file spells "not available", left ⌘W dead in all
    /// three.
    @Test func closeFallsBackToTheWindowWhenNoTabIsPublished() {
        var closedWindow = false
        CloseTabCommand.run(nil) { closedWindow = true }
        #expect(closedWindow, "⌘W does nothing on a window that publishes no tab to close")
    }

    @Test func closeTakesTheTabWhenThereIsOne() {
        var closedTab = false
        var closedWindow = false
        CloseTabCommand.run(.closeTab({ closedTab = true })) { closedWindow = true }
        #expect(closedTab)
        #expect(!closedWindow, "⌘W closed the window as well as the tab")
    }

    /// **⌘W on a pane's LAST tab closes the window**, as Finder does — which is what keeps ⌘W
    /// meaning "get rid of this" rather than acquiring an exception nobody would remember.
    ///
    /// Unscanned until now, and invisible to every other test: `PaneTabList.close(at:)` refuses the
    /// last tab, so deleting this branch does not throw an error or empty a pane — it makes ⌘W do
    /// *nothing at all* on a one-tab window, silently, in the state every install starts in.
    ///
    /// **The other `performClose` is a different one.** `CloseTabCommand` falls back to the key
    /// window when no tab value is published at all (`closeFallsBackToTheWindowWhenNoTabIsPublished`,
    /// and the suspended case in `ShortcutCommandsTests`) — that is ⌘W in a window with no tabs. This
    /// is ⌘W in the window that HAS them, on the one tab it is down to, and nothing asserted it.
    @Test func closingTheLastTabClosesTheWindowInsteadOfDoingNothing() throws {
        let body = Self.codeOnly(try Self.memberBody("func closeTab(id: UUID, isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
        let gate = try #require(body.range(of: "guard syncManager.paneTabs(isLeft: isLeft).count > 1 else {"),
                                "the last-tab branch is gone — ⌘W on a one-tab window now does nothing")
        let rest = String(body[gate.upperBound...])
        let close = try #require(rest.range(of: "NSApp.keyWindow?.performClose(nil)"),
                                 "the last tab no longer closes its window")
        let verb = try #require(rest.range(of: "tabAction(isLeft: isLeft)"),
                                "closeTab no longer runs a tab verb at all")
        // **Nesting, not order.** This stood as `close.upperBound < verb.lowerBound` alone, whose
        // message named a mutation ("unconditional, after the guard") that position cannot tell
        // from "inside the else block" — an unconditional `performClose` moved below the branch is
        // still before the verb, and every ⌘W would close the window. The branch's own closing
        // brace sits at member-body indentation, so its absence ahead of the close is what proves
        // the close is still inside it.
        #expect(close.upperBound < verb.lowerBound,
                "the window close comes after the tab verb, so ⌘W closes the tab and the window")
        let branch = String(rest[..<close.lowerBound])
        #expect(!branch.contains("\n        }"),
                "the guard's branch has already closed — the window close is unconditional, so every ⌘W closes the window whether the pane has one tab or five")
        // **And the line names the pane.** This is the feature's one destructive outcome, and
        // `noteWorkingIn` records a ⌘W aimed at the pane the user was not looking at as a shipped
        // bug — so which pane the press landed in is the whole question this line has to answer. It
        // said "the pane's last tab", which is every pane and every tab.
        #expect(branch.contains("PaneSideChoice.name(isLeft)"),
                "the line that closes the window does not say which pane's ⌘W did it")
        #expect(branch.contains("\\(closing)"),
                "the line that closes the window does not say which tab was aimed at")
        // …and the branch RETURNS. Falling through would ask the list to close a tab it refuses to
        // close, on a window that is already going: harmless today, and only by that refusal.
        #expect(textBetween(rest, from: close.upperBound, to: verb.lowerBound)?.contains("return") == true,
                "the last-tab branch closes the window and then goes on to close a tab as well")
    }

    /// **The item must stay live when nothing is published, and grey out when a pick owns the
    /// keyboard — two different reasons that used to be one blanket ban.**
    ///
    /// This test forbade `.disabled(` outright, and the ban was wider than its own reason. What it
    /// protects is the fallback above: on the Keyboard Shortcuts, Activity Log and Sync History
    /// windows nothing publishes a focused value, and this item is standing in for the File ▸ Close
    /// it replaced — disable it there and those three windows lose ⌘W, which is a shipped bug this
    /// suite exists to keep fixed. That reason is entirely about the **nil** case.
    ///
    /// It says nothing about the suspended one, which is the opposite situation: the main window is
    /// there, an overlay owns the keyboard, and ⌘W does nothing. Left enabled that is a live menu
    /// item that silently no-ops — which this app's own ⌘K pill calls its own bug — so the item now
    /// greys out, keyed on `isSuspended` and never on `nil`. The blanket ban could not express the
    /// difference, so it is replaced by the two halves it was standing for.
    @Test func theCloseItemIsDisabledOnlyForASuspendedPick() throws {
        let body = Self.codeOnly(try Self.typeBody("struct CloseTabCommand: View {",
                                                   in: Self.source("ShortcutCommands.swift")))
        #expect(!body.contains(".disabled(close == nil"),
                "⌘W is disabled when no tab is published — it is also this app's only Close")
        #expect(body.contains(".disabled(close?.isSuspended == true)"),
                "a suspended ⌘W is an enabled menu item that silently does nothing")
        // The disable is not a substitute for the rule: menu validation follows SwiftUI's update
        // cycle rather than the flag, so the item can still be performed in the window between the
        // two — and `run`'s `.suspended` case is what makes that harmless.
        #expect(body.contains("Self.run(close)"), "the item does not go through the tested rule")
    }

    // MARK: The launch restore

    /// **The restore arms the suppression counter like every other adopt.**
    ///
    /// This test used to assert the opposite, on the reasoning that the bootstrap guard was the
    /// suppression and an armed counter would strand at one. Both halves were wrong, and the
    /// second measurably so: SwiftUI evaluates `onChange` on the NEXT view update, and the
    /// bootstrap's tail lowers `isBootstrappingProviders` synchronously right after these restores
    /// — so the write arrived with the guard already DOWN and ran the full user-switch path, whose
    /// the user-switch path's re-home wiped the pane back to its root over the strip just restored.
    /// (Measured with a minimal SwiftUI host: a `@State` write followed synchronously by lowering
    /// a guard flag reaches `onChange` with the flag false; the same write with an `await` between
    /// is protected, which is why `applyProviderSelection` was genuinely safe.) Stranding is no
    /// longer possible either, because the handler consumes counters BEFORE testing the guard —
    /// `aSuppressionCounterIsConsumedWhereverItsWriteLands`.
    @Test func theLaunchRestoreArmsTheSuppressionCounterLikeEveryOtherAdopt() throws {
        let body = try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("adoptProviderForTab(adopt, isLeft: isLeft"),
                "the launch restore writes the provider id its own way again")
        // Threaded, not hardcoded — the restore runs for BOTH panes, and a right pane that adopted
        // no source would reopen every tab under whichever provider the pane happened to be on,
        // showing the right folder path under the wrong root.
        for side in ["leftProviderId", "rightProviderId"] {
            #expect(!Self.codeOnly(body).contains("\(side) = active.providerId"),
                    "the bare \(side) write is back, and the bootstrap guard does not stop it")
        }
    }

    /// **The restore is behind "reopen the last folder", and nothing else says so.**
    ///
    /// Someone who has turned that setting off has said they want the app to start at the root;
    /// handing them five tabs' worth of where they were is that answer at five times the volume.
    /// Unscanned until now, and both mutations are silent: deleting the guard restores tabs for
    /// someone who asked for none, and inverting it restores them for nobody — a strip that quietly
    /// never comes back, which the first save then overwrites. Pinned as the exact literal, so
    /// `guard !GeneralSettings…` fails rather than matching a looser check.
    @Test func theLaunchRestoreObeysTheReopenTheLastFolderSetting() throws {
        let body = Self.codeOnly(try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
        let gate = try #require(body.range(of: "guard GeneralSettings.shouldRestoreLastFocus() else { return }"),
                                "the restore ignores the reopen-last-folder setting, or tests it inverted")
        let read = try #require(body.range(of: "PaneTabsStore.load(isLeft: isLeft)"),
                                "the restore no longer reads the stored strip")
        #expect(gate.upperBound < read.lowerBound,
                "the setting is consulted after the strip has already been read and acted on")
    }

    /// **The account of the restore is DECIDED in `BrowseTabRestorePlan` and merely EMITTED here.**
    ///
    /// Two elaborate scans stood in this spot (`theLaunchRestoreNamesTheFolderAReRootedTabLost`,
    /// `theLostFolderLineDoesNotClaimARestoreThatWasAbandoned`), pinning as source text which lines
    /// are said, per side, in what order, and never for an abandoned restore. Those branches are
    /// now executable — `BrowseTabRestorePlanTests` runs every one, including the ordering the
    /// second scan asserted — so what remains for a scan is the glue the planner cannot see:
    /// the host must emit the plan's lines at their stated levels, install only what the plan
    /// installs, and take the plan's adoption through the counter (the test above).
    @Test func theLaunchRestoreExecutesThePlanItWasHanded() throws {
        let body = Self.codeOnly(try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
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

    /// **Both panes are restored, and the right one is easy to drop.** The launch sequence called
    /// this once for years; a later edit that re-collapses it to the left leaves Compare's right
    /// pane seeding one tab again, which is the state this whole feature exists to end.
    @Test func bothPanesAreRestoredAtLaunch() throws {
        let source = Self.codeOnly(try Self.source("ContentView.swift"))
        #expect(source.contains("restoreBrowseTabs(isLeft: true)"))
        #expect(source.contains("restoreBrowseTabs(isLeft: false)"),
                "the right pane's strip is never restored, so it seeds one tab every launch")
    }

    /// The swap moves the lists as well as the panes, so what is saved has to move with them.
    ///
    /// **Both sides, and that is the half a reader would leave out.** A swap is the one move that
    /// changes both strips at once. Saving only the left leaves the right's stored strip naming the
    /// pane that is no longer there, and the next launch restores two halves of a swap that never
    /// happened — one side from before it, one from after. Nothing on screen says so until a
    /// relaunch, which is why it is pinned here rather than left to the manual pass.
    @Test func swappingThePanesSavesBothStrips() throws {
        let body = try Self.memberBody("func swapPanesAction()", in: Self.source("ContentView.swift"))
        #expect(body.contains("saveBrowseTabs(isLeft: true)"),
                "a swap leaves the saved strip describing the pane that just left")
        #expect(body.contains("saveBrowseTabs(isLeft: false)"),
                "a swap saves only the left strip, so a relaunch restores half a swap")
    }

    // MARK: The seam

    /// The seam's ⇄ / 🔗 capsule is drawn on top of the strip, and it lands on the left pane's ＋.
    @Test func theStripGivesUpTheEdgeTheSeamControlsSitOn() {
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: true, leading: false) == PaneTabSeam.reserve,
                "the left pane's ＋ stays under the seam controls")
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: false, leading: true) == PaneTabSeam.reserve,
                "the right pane's first chip stays under the seam controls")
    }

    /// …and only that edge. The other three would be track given up for nothing.
    @Test func noOtherEdgeGivesUpTrack() {
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: true, leading: true) == 0)
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: false, leading: false) == 0)
    }

    /// Browse and the Organize/Storage rail have no seam — one pane, nothing straddling anything.
    @Test func aSinglePaneWorkspaceKeepsItsWholeStrip() {
        for isLeft in [true, false] {
            for leading in [true, false] {
                #expect(PaneTabSeam.inset(isCompare: false, isLeft: isLeft, leading: leading) == 0,
                        "a single-pane workspace lost strip track to a seam it does not have")
            }
        }
    }

    /// The call-site half: the pane column asks the rule rather than spelling a number.
    @Test func thePaneColumnReservesTheSeamThroughTheRule() throws {
        let tabs = try Self.source("ContentView+PaneTabs.swift")
        let body = try Self.memberBody("func seamInset(isLeft: Bool, leading: Bool)", in: tabs)
        #expect(body.contains("PaneTabSeam.inset("), "the seam reserve is spelled by hand")
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("leadingInset: seamInset(isLeft: isLeft, leading: true)"),
                "the strip is not given the seam reserve")
    }

    /// **The strip slides in** (roadmap Fig. 10). ⌘T opens the folder you are already in, so both
    /// chips say the same thing and nothing else on screen changes — the strip's arrival is the
    /// only feedback there is, and an abrupt one reads as a glitch rather than a result.
    @Test func theStripArrivesWithAnAnimation() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        // **Cut at the member boundary, not at a character budget.** This read
        // `prefix(20_000)`, and a comment added inside `paneColumn` pushed the animation line to
        // +20,020 — so the window stopped 20 characters short and the test reported it as "the
        // strip appears with no transition", naming a regression that was not there. A budget can
        // only ever fail this way (a `contains` that falls outside is loud, never vacuous), but a
        // loud failure that names the wrong cause costs a session all the same.
        let rest = String(content[column.upperBound...])
        let end = try #require(rest.range(of: "\n    func ")?.lowerBound,
                               "no member follows paneColumn — the cut would run to end of file")
        let body = String(rest[..<end])
        #expect(body.contains(".transition(.move(edge: .top)"),
                "the strip appears with no transition — nothing marks the arrival ⌘T is fed back by")
        // Keyed on PRESENCE, not on the tab count: opening a third tab while the strip is already
        // up must not animate the header and the list under it.
        #expect(body.contains("value: paneShowsTabStrip(isLeft: isLeft)"),
                "the strip's animation is keyed on something other than its own presence")
    }

    /// Pinning is wired, and it saves — a pin that did not survive a quit would be a worse
    /// promise than no pin at all.
    @Test func pinningIsWiredAndPersisted() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("onSetPinned: { id, pinned in setTabPinned(pinned, id: id, isLeft: isLeft) }"),
                "the strip's pin action is wired to nothing")
        let body = try Self.memberBody("func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("syncManager.setTabPinned("), "pinning does not reach the manager")
        // **The save is the one door's now.** `setTabPinned` goes through `tabAction` with a `nil`
        // answer — the branch that saves the strip and drives no reload — so a pin still survives a
        // quit. Both halves are checked, here: the routing, and the door's `nil` branch actually
        // saving. Either alone would let a pin stop being persisted with this test green.
        #expect(body.contains("tabAction(isLeft: isLeft)"),
                "a pin no longer goes through the one door, so it saves nothing and moves no focus")
        #expect(body.contains("return nil"),
                "a pin claims the pane moved — the one door would then write a provider and drive a reload for a chip that only changed its own state")
        let door = Self.codeOnly(try Self.memberBody("private func tabAction(isLeft: Bool",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
        let noMove = try #require(door.range(of: "guard let arrived = verb() else {"),
                                  "the one door no longer distinguishes a verb that moved the pane")
        let after = String(door[noMove.upperBound...].prefix(200))
        #expect(after.contains("saveBrowseTabs(isLeft: isLeft)"),
                "the one door's “the pane did not move” branch no longer saves the strip — a pin, an unpin and a reorder all stop surviving a quit")
        // Pinning moves no pane, so it must not pay for a reload.
        #expect(!Self.codeOnly(body).contains("refreshForTabSwitch"),
                "pinning reloads the tree for nothing")
    }

    /// **The File menu, read off the running app rather than out of the source.**
    ///
    /// The test host IS the app, so `NSApp.mainMenu` is the menu AppKit built from the `.commands`
    /// declarations — which makes this the one check that sees what the group replacements actually
    /// produced. Two of them are invisible to a source scan and both would ship silently:
    /// `CommandGroup(replacing: .saveItem)` failing to remove AppKit's own Close (two items
    /// registering ⌘W, one of them dead), and the tab items landing in the wrong group and so in
    /// the wrong place — the roadmap's Fig. 9 puts Close Tab beside New Tab, not below Delete.
    @Test func theFileMenuIsInTheRoadmapsOrder() throws {
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu,
                                "the app has no File menu — this check would be vacuous")
        let titles = file.items.map(\.title).filter { !$0.isEmpty }
        // New Text File… leads from 2026-08-31: ⌘N is the item AppKit's `.newItem` group is named
        // for, and the two "new" items belong together at the top. Everything after them keeps the
        // order Fig. 9 gave it.
        #expect(titles.prefix(5)
                == ["New Text File…", "New Folder…", "New Tab", "Close Tab", "Reopen Closed Tab"],
                "the File menu opens with \(titles.prefix(5)) — Fig. 9 puts the tab items with the new-item pair")

        // AppKit's own Close is gone, and exactly one item claims ⌘W. Two would leave one of them
        // dead, and which one AppKit picks is not something this app decides.
        #expect(!titles.contains("Close"), "the standard File ▸ Close is still there beside Close Tab")
        // **Close All (⌥⌘W) goes with it, deliberately.** It came from the same group, and this app
        // is one window plus three utilities — while ⌥ chords are the one kind that fire through
        // the ⌥-hold reveal, so putting it back by hand would break an invariant `AppChordTests`
        // guards for the whole app. Pinned so the loss reads as a decision rather than an oversight.
        #expect(!titles.contains("Close All"),
                "Close All is back — it registers an ⌥ chord, which fires through the ⌥-hold reveal")
        let closers = file.items.filter { $0.keyEquivalent == "w" }
        #expect(closers.count == 1, "\(closers.count) items register ⌘W")
        #expect(closers.first?.title == "Close Tab")

        // Reopen Closed Tab has no chord on purpose: ⇧⌘T is the Tab Bar, and an ⌥ chord is the one
        // kind that can fire through the ⌥-hold reveal.
        let reopen = try #require(file.items.first { $0.title == "Reopen Closed Tab" })
        #expect(reopen.keyEquivalent.isEmpty, "Reopen Closed Tab has acquired a chord")
    }

    /// The View menu's Tab Bar switch, same source: a checkmark item, above the other switches.
    @Test func theViewMenuCarriesTheTabBarSwitch() throws {
        let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu,
                                "the app has no View menu")
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        let tabBar = try #require(titles.firstIndex(of: "Tab Bar"), "View ▸ Tab Bar is gone")
        let hidden = try #require(titles.firstIndex(of: "Hidden Files"))
        #expect(tabBar < hidden, "Tab Bar sits below the other switches")
        #expect(view.items.first { $0.title == "Tab Bar" }?.keyEquivalent == "t")
        // A noun with a tick, never a Show/Hide pair.
        #expect(!titles.contains { $0.hasPrefix("Show Tab") || $0.hasPrefix("Hide Tab") },
                "the tab bar switch became a Show/Hide pair")
    }

    // MARK: The right-click routes

    /// **The pane's own background menu offers New Tab.** It is the only right-click route that
    /// works at ONE tab — the row menu needs a folder under the pointer and the strip's menu needs
    /// a strip, and neither exists in the state every install starts in.
    @Test func thePaneBackgroundMenuOffersANewTab() throws {
        let shared = try Self.memberBody("static func tabActions(at path: String, delegate: FileActionDelegate)",
                                         in: Self.fileExplorer("FileTreeView.swift"))
        #expect(shared.contains("delegate.canOpenInNewTab"), "the item is offered by hosts with no strip")
        #expect(shared.contains("handleNewTab(at: path)"), "New Tab is wired to nothing")
        #expect(shared.contains("delegate.canCloseTab"),
                "Close Tab is offered at one tab, where it would close the window instead")

        // …and both view modes' background menus actually build it.
        for file in ["FileTreeView.swift", "PaneColumnsView.swift"] {
            #expect(try Self.fileExplorer(file).contains("SharedFileMenuItems.tabActions("),
                    "\(file)'s empty-area menu has no tab items")
        }
    }

    /// **Right-clicking the header card offers a new tab.** It is the surface a Mac user reaches
    /// for to act on a pane, and it was the one place with no tab route at all — the row menu needs
    /// a folder under the pointer, the strip's menu needs a strip, and the pane's background menu
    /// needs empty space below the rows, which a full column does not have.
    ///
    /// The bar itself is untouched: no glyph, no `PaneBarItem`, nothing in the customize sheet.
    @Test func theHeaderCardsMenuOffersANewTab() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Dashboard/Sources/Dashboard/DashboardViews.swift")
        let header = try String(contentsOf: url, encoding: .utf8)
        let menu = try Self.memberBody("private func barContextMenu() -> some View {", in: header)
        #expect(menu.contains("Button(\"New Tab\")"), "the header card's menu has no New Tab")
        #expect(menu.contains("Button(\"Close Tab\")"), "the header card's menu has no Close Tab")
        #expect(menu.contains("Customize Pane Bar…"), "the menu lost what it already carried")
        // No chord badges: the pair is registered once in the menu bar, and a `.keyboardShortcut`
        // here would register a second pair — one per pane.
        #expect(!Self.codeOnly(menu).contains("keyboardShortcut"),
                "the header menu registers its own chords, so ⌘T is claimed twice")

        // …and the call site withholds Close Tab at one tab rather than offering to close the window.
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("onCloseTab: syncManager.paneTabs(isLeft: isLeft).count > 1"),
                "the header menu offers Close Tab at one tab, where it would close the window")
    }

    /// Discovery beats tidiness: the row menu's tab item sits above Quick Look, not at the bottom
    /// of the folder branch (roadmap Fig. 11).
    @Test func openInNewTabSitsAheadOfQuickLook() throws {
        let code = try Self.fileExplorer("FileTreeView.swift")
        let tab = try #require(code.range(of: "Label(\"Open in New Tab\""),
                               "the row menu no longer offers Open in New Tab")
        let quickLook = try #require(code.range(of: "Label(\"Quick Look\""))
        #expect(tab.lowerBound < quickLook.lowerBound,
                "Open in New Tab sank below Quick Look — it is the whole discovery story for tabs")
    }

    // MARK: The row menu's entry point

    /// The discovery route. ⌘T opens the folder you are already in, so this is the only entry
    /// point that produces a second tab somewhere else — gated on the delegate's own capability
    /// like the two items beside it, and on the row being a FOLDER, because a tab is a location.
    @Test func theRowMenuOffersOpenInNewTabForFoldersOnly() throws {
        let code = try Self.fileExplorer("FileTreeView.swift")
        let item = try #require(code.range(of: "Label(\"Open in New Tab\""),
                                "the row menu no longer offers Open in New Tab")
        // The gate is the two lines above the label, not a block further up: the item moved out of
        // the folder branch to sit ahead of Quick Look, so it carries its own `isDirectory` test.
        let lead = String(code[..<item.lowerBound].suffix(300))
        #expect(lead.contains("singleNode.isDirectory"), "a FILE can be opened as a tab")
        #expect(lead.contains("delegate.canOpenInNewTab"),
                "Open in New Tab is offered by hosts that have no strip to open a tab in")
        let after = String(code[item.upperBound...].prefix(200))
        #expect(after.contains("handleOpenInNewTab(singleNode)") || lead.contains("handleOpenInNewTab(singleNode)"),
                "Open in New Tab is not wired to the delegate")
    }

    // MARK: Compare — both panes wear the strip

    /// The term that makes Compare readable: **a second tab on either pane draws the strip on
    /// both.** Without it the pane that grew the tab has its header pushed 34pt down and every row
    /// after it names a different folder on the left than on the right.
    @Test func inCompareOnePanesSecondTabDrawsBothStrips() {
        #expect(PaneTabStripVisibility.shows(own: false, sibling: true, isCompare: true, switchIsOn: false),
                "the sibling grew a second tab and this pane drew nothing — the two rows are now offset")
        #expect(PaneTabStripVisibility.shows(own: true, sibling: false, isCompare: true, switchIsOn: false),
                "the pane with the tabs does not draw its own strip")
    }

    /// …and the other direction, which is the one that costs a 34pt row if it goes wrong. Browse and
    /// the single-source rail have no sibling on screen, so the sibling's list must not reach them —
    /// the right pane's list exists in both, it is simply not shown.
    @Test func outsideCompareTheSiblingsTabsDrawNothing() {
        #expect(!PaneTabStripVisibility.shows(own: false, sibling: true, isCompare: false, switchIsOn: false),
                "Browse drew a strip because the hidden right pane has two tabs")
        #expect(!PaneTabStripVisibility.shows(own: false, sibling: false, isCompare: true, switchIsOn: false),
                "a strip is drawn with one tab on each side and the switch off")
        #expect(PaneTabStripVisibility.shows(own: false, sibling: false, isCompare: false, switchIsOn: true),
                "View ▸ Tab Bar no longer shows the strip")
    }

    /// The call-site half: the rule is fed the SIBLING's list and the layout, not just this pane's.
    /// Reading `paneTabs(isLeft: isLeft)` twice would pass every rule test above and still ship the
    /// offset rows.
    @Test func theStripGateAsksBothPanes() throws {
        let rule = try Self.memberBody("func paneShowsTabStrip(isLeft: Bool) -> Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(rule.contains("PaneTabStripVisibility.shows("),
                "the gate is built by hand — the tested rule is unused")
        // Through the one flip, like every other reach for the sibling in this file — the local it
        // binds is read off the member rather than spelled here.
        let sibling = try #require(Self.siblingLocals(in: rule).first,
                                   "the gate flips the side by hand instead of through `PaneSideChoice.sibling`, where a test can drive the polarity")
        #expect(rule.contains("paneTabs(isLeft: \(sibling)).showsStrip"),
                "the gate never asks the sibling pane, so Compare's two rows can sit at different heights")
        #expect(rule.contains("layoutMode == .compare"),
                "the gate does not restrict the sibling term to Compare")
        #expect(rule.contains("tabBarVisible"), "View ▸ Tab Bar no longer shows the strip")
    }

    // MARK: Compare — a linked pane opens the tab too

    /// The mirror lands on the deepest folder the sibling genuinely has. A tab naming a folder that
    /// pane does not carry is a chip that cannot be navigated to, and the two sides are being
    /// compared precisely because they differ.
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

    /// A folder missing halfway down must not be walked past — pruning stops, it does not skip.
    ///
    /// **The fixture is the whole test.** The obvious one — a sibling holding `Photos` and
    /// `Photos/2024/June` — cannot tell the two apart, because skipping `2024` next asks about
    /// `Photos/June`, which is not there either, and a `continue` in place of the `break` returned
    /// the same answer. This sibling *does* have `Photos/June`, so a skipping walk assembles a
    /// path out of two folders that are not parent and child.
    @Test func theMirrorStopsAtTheFirstMissingFolder() {
        let has: Set<String> = ["Photos", "Photos/June"]
        #expect(PaneTabMirror.landing(for: "Photos/2024/June") { has.contains($0) } == "Photos",
                "the walk skipped a missing folder and landed on a path with a hole in it")
    }

    /// Both entry points mirror, and both go through the one predicate.
    @Test func bothWaysOfOpeningATabMirrorOntoTheLinkedPane() throws {
        let code = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        let here = try Self.memberBody("func openNewTabHere(isLeft: Bool)", in: code)
        #expect(here.contains("guard tabsOpenOnBothPanes else { return }"),
                "⌘T and the ＋ do not open a tab on the linked pane")
        // Through the one flip, like the other mirror — see `PaneSideChoice.sibling`. Which local
        // it binds is read off the member rather than spelled here.
        let hereSibling = try #require(Self.siblingLocals(in: here).first,
                                       "the mirrored ⌘T does not take its side through `PaneSideChoice.sibling`, so the flip is back in a `ContentView` extension where no test can drive it")
        #expect(here.contains("openTabHere(isLeft: \(hereSibling), mirrored: true)"),
                "the mirrored ⌘T does not target the other pane")

        let openThere = try Self.memberBody("func openInNewTab(absolutePath: String, isLeft: Bool)", in: code)
        #expect(openThere.contains("mirrorOpenInNewTab(relative, from: isLeft)"),
                "Open in New Tab does not mirror onto the linked pane")

        let mirror = try Self.memberBody("private func mirrorOpenInNewTab(", in: code)
        #expect(mirror.contains("guard tabsOpenOnBothPanes else { return }"),
                "the mirror runs unlinked, or in Browse, where there is no sibling")
        #expect(mirror.contains("PaneTabMirror.landing("),
                "the mirror copies the path outright instead of pruning it")
        #expect(mirror.contains("expandingTildeInPath"),
                "the sibling's root is compared unexpanded, so every mirror prunes to its root")
        // **And this mirror takes its side the same way ⌘T's does.** It did not: `let other =
        // !isLeft` was written out here, and dropping the `!` survived the whole app suite —
        // ⌥/linked Open in New Tab opened both tabs on the pane the user aimed at and none on the
        // sibling. ⌘T's half was pinned above and this one was not, which is the asymmetry that
        // exposed it.
        let mirrorSibling = try #require(Self.siblingLocals(in: mirror).first,
                                         "the mirror flips the side by hand instead of through `PaneSideChoice.sibling` — dropping the `!` is a measured survivor of the whole suite")
        #expect(mirror.contains("tabAction(isLeft: \(mirrorSibling), movesFocus: false)"),
                "the mirror opens its tab on a pane other than the sibling it just resolved")
    }

    // MARK: What the launch sequence may not overwrite

    /// **The save has to refuse during the provider bootstrap.**
    ///
    /// The launch sequence points the pane at its stored folder and *then* reads the stored strip.
    /// That first move fires the persistence `onChange`, and the pane at that instant still holds
    /// the freshly-initialised one-tab list — so a save landing in between overwrites the user's
    /// whole strip with a single tab, and the restore reads back what it just destroyed. Whether
    /// the window opens at all comes down to when SwiftUI runs a view update across the `await`
    /// between the two steps, which is not a thing to leave to timing.
    @Test func theStripIsNotSavedWhileTheProvidersAreStillBootstrapping() throws {
        let rule = try Self.memberBody("func saveBrowseTabs(isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(rule.contains("!isBootstrappingProviders"),
                "a save during launch can overwrite the stored strip before the restore reads it")
        // **And it must not refuse the right pane.** `guard isLeft` sat here until the right strip
        // was persisted, and putting it back is a one-word change that kills right-pane persistence
        // outright while every store test stays green — they call the store directly and never
        // reach this. Negative, so it goes through `codeOnly`.
        #expect(!Self.codeOnly(rule).contains("guard isLeft"),
                "the save refuses the right pane again, so its strip is never written")
    }

    /// **The save writes the LIVE pane over the active entry, through the rule that can be tested.**
    ///
    /// The active entry in the list is a snapshot from when that tab was last parked (see
    /// `PaneTab`), so a strip written straight off the list saves the tab on screen at the folder it
    /// was opened at — which is what "the active tab lost its columns across a quit" was, while
    /// every parked tab kept theirs. The overlay lived inline in this member, where nothing could
    /// reach it: deleting the block whole passed every test in the repo, including the ones about
    /// the very columns it exists to keep. It is `PaneTabList.replacingActive` now, unit-tested in
    /// `PaneTabsTests`, and this is the half that a value cannot state — that the host calls it, with
    /// the pane's own three values, and hands the store the result rather than the list.
    @Test func theSaveWritesTheLivePaneOverTheActiveEntryThroughTheRule() throws {
        let save = Self.codeOnly(try Self.memberBody("func saveBrowseTabs(isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
        #expect(save.contains("replacingActive("),
                "the save writes the list's own stale active entry — the tab on screen is stored where it was parked")
        // **All three halves of where the pane is**, and the two paths separately: `PaneTabsStore`
        // records the cut between scope and stack as a depth, so an entry rebuilt from the joined
        // path reports a depth of zero and the columns are flattened one layer down.
        // Each through its own narrowing wrapper: the two paths were ternaries written out here,
        // and transposing either stores the SIBLING pane's folder or column stack as this pane's
        // active tab, to be restored onto it at the next launch.
        for value in ["providerId: paneProviderId(isLeft: isLeft)",
                      "relativePath: paneScope(isLeft: isLeft)",
                      "browsePath: paneStack(isLeft: isLeft)"] {
            #expect(save.contains(value), "the save does not hand the rule the pane's own \(value)")
        }
        // …and what goes to disk is the overlaid strip, not the one it was built from: passing the
        // un-overlaid list here would satisfy every presence above and store nothing the overlay
        // produced.
        //
        // **One assertion, not two.** A negative twin naming `list.tabs` sat here and could not
        // fail: there has been no local called `list` in this member since the overlay moved into
        // `Sync`, and the positive above already pins the whole argument — any other value in it,
        // named anything, fails this line.
        #expect(save.contains("PaneTabsStore.save(tabs: saving.tabs"),
                "the overlaid strip is built and then not the one that is saved")
    }

    /// **One body serves both panes, so every side-dependent call inside it has to thread `isLeft`.**
    ///
    /// A single hardcoded side here is the worst failure this feature can have and the quietest: the
    /// app compiles, the package suite is green (it calls `PaneTabsStore` directly and never reaches
    /// these call sites), and nothing is visibly wrong until a relaunch. A save pinned to `true`
    /// makes every right-pane move overwrite the LEFT pane's stored strip — the user loses the tabs
    /// they were actually using. A `setPaneTabs`/`applyTab` pinned to `true` installs the right
    /// pane's restored tabs onto the left pane at launch.
    ///
    /// Pinned both ways round: the threading is asserted positively, and the literals are asserted
    /// absent — either alone can be satisfied while the other is broken.
    @Test func theSaveAndRestoreThreadTheirSideRatherThanHardcodingIt() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let save = Self.codeOnly(try Self.memberBody("func saveBrowseTabs(isLeft: Bool)", in: source))
        let restore = Self.codeOnly(try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                                        in: source))

        #expect(save.contains("PaneTabsStore.save(") && save.contains("isLeft: isLeft"),
                "the save does not pass its own side to the store")
        #expect(restore.contains("PaneTabsStore.load(isLeft: isLeft)"),
                "the restore reads a fixed pane's stored strip")
        #expect(restore.contains("setPaneTabs(restored, isLeft: isLeft)"),
                "the restored strip is installed on a fixed pane")
        #expect(restore.contains("applyTab(restored.active, isLeft: isLeft"),
                "the restored tab is applied to a fixed pane")

        for (name, body) in [("saveBrowseTabs", save), ("restoreBrowseTabs", restore)] {
            #expect(!body.contains("isLeft: true") && !body.contains("isLeft: false"),
                    "\(name) hardcodes a side, so one pane acts on the other's state")
        }
    }

    /// **The source is part of where a tab is**, and it is the half that moves without either path
    /// moving: switching source at the root leaves the history default, the column stack empty and
    /// the relative path `""`, so neither path `onChange` fires. Left unwatched, the stored entry
    /// keeps naming the old source — and because the restore writes the tab's provider over
    /// `selectedLeftProviderId`, the next launch actively undoes the switch.
    @Test func theSavedStripFollowsTheSourceAndNotOnlyThePath() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let modifier = try Self.typeBody("struct BrowseTabPersistence: ViewModifier {", in: source)
        #expect(modifier.contains("onChange(of: leftProviderId)"),
                "a source switch at the root is never saved, so the next launch reopens the old one")
        #expect(modifier.contains("onChange(of: syncManager.leftRelativePath)"),
                "the scope is no longer watched")
        #expect(modifier.contains("onChange(of: syncManager.leftBrowsePath)"),
                "the column stack is no longer watched")

        // **The same three for the right pane**, which is persisted too. Watching only the left
        // would leave the right pane's strip written by the tab verbs but never by navigation — so
        // it would come back at the folder its tabs were opened at rather than where they were
        // left, which is the exact bug this rule was written for on the left.
        #expect(modifier.contains("onChange(of: rightProviderId)"),
                "a right-pane source switch at the root is never saved")
        #expect(modifier.contains("onChange(of: syncManager.rightRelativePath)"),
                "the right pane's scope is not watched")
        #expect(modifier.contains("onChange(of: syncManager.rightBrowsePath)"),
                "the right pane's column stack is not watched")

        // …and the call site actually feeds it. A modifier watching a value nobody passes is the
        // shape this repo has shipped before.
        let callSite = try Self.source("ContentView.swift")
        #expect(callSite.contains("leftProviderId: leftProviderId"),
                "BrowseTabPersistence is built without the source it watches")
        #expect(callSite.contains("rightProviderId: rightProviderId"),
                "BrowseTabPersistence is built without the right pane's source")
        // **And its callback saves the side that moved.** The modifier reports which pane changed;
        // a call site that ignores that and saves a fixed side puts every right-pane move into the
        // left pane's stored strip. Six correct `onChange`s above cannot save you from one wrong
        // closure here, which is why the wiring is checked as well as the watching.
        #expect(Self.codeOnly(callSite).contains("saveBrowseTabs(isLeft: $0)"),
                "the persistence callback ignores which pane moved and saves a fixed side")
    }

    // MARK: The scan a tab switch does not run

    /// **A tab switch inside one source at one scope reloads nothing and rescans nothing.**
    ///
    /// The trees walk one root at one focus and the differences are about one pair of focused
    /// folders, so a switch that changes neither leaves both correct. Refreshing is the Refresh
    /// button's job — and drilling through columns, which moves the same column stack a tab
    /// carries, has never rescanned either.
    ///
    /// The two halves must ask **one** rule: the manager decides from it whether to drop the trees
    /// and the comparison, the host decides from it whether to run the scan. Two copies would let a
    /// switch invalidate without reloading, leaving a pane with no tree and no scan until the user
    /// pressed Refresh — strictly worse than the rescan this removes.
    @Test func theScanIsGatedOnTheSameRuleTheInvalidationUses() throws {
        let host = try Self.memberBody("private func tabAction(isLeft: Bool, movesFocus: Bool = true, _ verb: () -> PaneTab?)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(host.contains("PaneTabArrival.needsReload("),
                "the host rescans on every tab switch, or decides with its own copy of the rule")
        let gate = try #require(host.range(of: "PaneTabArrival.needsReload("))
        let refresh = try #require(host.range(of: "refreshForTabSwitch(movedPane:"),
                                   "the reload is gone entirely — a source switch would never load")
        #expect(gate.lowerBound < refresh.lowerBound, "the gate does not guard the reload")

        // Captured BEFORE the verb runs, because the verb moves the pane — read afterwards, the
        // "from" focus IS the arriving tab's focus and the rule says "no reload" for every switch,
        // including the source changes that genuinely need one.
        //
        // **Asserted as an ORDER, not as a presence.** Checking only that the line exists passed
        // with the read moved below `verb()` — the mutation this test is for.
        let read = try #require(host.range(of: "let fromFocus = paneScope(isLeft: isLeft)"),
                                "the pane's focus before the switch is never captured")
        let verb = try #require(host.range(of: "verb() else {"), "the verb call is gone")
        #expect(read.upperBound < verb.lowerBound,
                "the focus is read after the pane has already moved, so the rule always says no")
    }

    /// **The prune must also fire when a pane finishes loading**, not only when its tree changes.
    ///
    /// `pruneBrowsePath` refuses while a tree is loading, because progressive loading publishes a
    /// shallow root-children-only tree first and pruning against that cuts a valid stack to its
    /// first component. But the deep tree is published *before* `await applyFilters()` and the flag
    /// is cleared *after* it, so the update carrying the final tree can arrive while the flag is
    /// still up — the republish handler skips, and the tree does not change again to re-fire it. A
    /// folder deleted externally would keep its dead stack, which is the whole thing the prune is
    /// for. The falling edge closes it without depending on which side of an `await` a SwiftUI
    /// update lands on.
    @Test func theStackIsAlsoPrunedWhenAPaneFinishesLoading() throws {
        let body = try Self.typeBody("struct ColumnStackPruning: ViewModifier {",
                                     in: Self.source("ContentView+PaneTabs.swift"))
        for flag in ["isLoadingLeftTree", "isLoadingRightTree"] {
            let handler = try #require(body.range(of: "onChange(of: syncManager.\(flag))"),
                                       "nothing prunes \(flag)'s pane when it settles")
            // **Sliced to this handler's own closure, not a fixed window.** A `prefix(200)` here
            // reached into the NEXT handler and found its guard, so deleting this one's passed —
            // the mutation that made the point.
            let rest = body[handler.upperBound...]
            let end = rest.range(of: "\n            .onChange") ?? rest.range(of: "\n    }")
            let own = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
            #expect(own.contains("guard !isLoading else { return }"),
                    "the \(flag) handler prunes on the RISING edge too, against a tree still loading")
            #expect(own.contains("prune(isLeft:"), "the \(flag) handler does not prune")
        }
        // The republish trigger is still there — the falling edge is an addition, not a swap.
        #expect(body.contains("onChange(of: syncManager.leftPaneTree)"),
                "a republish no longer prunes, so a deleted folder keeps its stack until a reload")
        #expect(body.contains("onChange(of: syncManager.rightPaneTree)"))
        // And the modifier is actually installed.
        #expect(try Self.source("ContentView.swift").contains("ColumnStackPruning("),
                "the pruning modifier is defined and never applied")
    }

    // MARK: Log coverage

    /// **Every verb that changes the strip writes a line**, because he audits `~/sync-cloud.log`
    /// and the app's house style logs far smaller things than these ("User toggled hidden files",
    /// "User changed sort option").
    ///
    /// Named one by one rather than scanned as a family: a blanket "every func in this file logs"
    /// passes the moment a verb is renamed out of the pattern, which is the blind spot this repo
    /// has hit before. The positive control is `theScanCanActuallyFail` above plus the deliberate
    /// omission asserted underneath.
    @Test func everyVerbThatChangesTheStripIsLogged() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let verbs = [
            "private func openTabHere(isLeft: Bool, mirrored: Bool = false)",
            "func openInNewTab(absolutePath: String, isLeft: Bool)",
            "private func mirrorOpenInNewTab(",
            "func selectTab(id: UUID, isLeft: Bool)",
            "func cycleTab(forward: Bool, isLeft: Bool)",
            "func closeTab(id: UUID, isLeft: Bool)",
            "func closeOtherTabs(keeping id: UUID, isLeft: Bool)",
            "func duplicateTab(id: UUID, isLeft: Bool)",
            "func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
            "func moveTab(id: UUID, to index: Int, isLeft: Bool)",
            "func reopenClosedTab(isLeft: Bool)",
            "func copyTabPath(id: UUID, isLeft: Bool)",
        ]
        for verb in verbs {
            let body = try Self.memberBody(verb, in: source)
            #expect(body.contains("Logger.shared."),
                    "“\(verb)” changes the strip and writes nothing to the log")
        }
    }

    /// The two that are deliberately quieter, and the two that are deliberately louder — a level
    /// this file picked on purpose is worth pinning, because "make it consistent" would otherwise
    /// flatten them on the next pass.
    @Test func cyclingIsQuietAndClosingIsNot() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        for quiet in ["func selectTab(id: UUID, isLeft: Bool)",
                      "func cycleTab(forward: Bool, isLeft: Bool)",
                      "func moveTab(id: UUID, to index: Int, isLeft: Bool)"] {
            let body = try Self.memberBody(quiet, in: source)
            #expect(body.contains("Logger.shared.debug"),
                    "“\(quiet)” logs at info — holding ⌃⇥ then buries the lines worth reading")
        }
        for loud in ["func closeTab(id: UUID, isLeft: Bool)",
                     "func closeOtherTabs(keeping id: UUID, isLeft: Bool)"] {
            let body = try Self.memberBody(loud, in: source)
            #expect(body.contains("Logger.shared.info"),
                    "“\(loud)” throws tabs away at debug level")
        }
    }

    /// **A line that names no tab cannot be read back.** Selecting, cycling and closing all wrote
    /// sentences that were true of any tab in any pane: "User selected a browse tab", and a close
    /// that carried only the chip's TITLE — which is the leaf path component. ⌘T deliberately opens
    /// the folder you are already in, so same-named chips are the expected first sight of the strip,
    /// and two closes of two different tabs read identically in his log today. In Compare none of
    /// the three said which pane had moved.
    ///
    /// Named verb by verb rather than scanned as a family, like the level check below it: a blanket
    /// rule passes the moment a verb is renamed out of the pattern.
    ///
    /// **All seven, not the three this started with.** The commit that added the side and the tab
    /// claimed "every verb now names the side and the tab" and left four verbs writing sentences
    /// true of any tab in any pane — "User duplicated a browse tab", "User pinned a browse tab",
    /// "User reordered a browse tab", and a reopen that named a path but no pane. Every one of them
    /// is a verb the user aimed at ONE strip, and in Compare the log could not say which.
    /// (`closeOtherTabs` is deliberately not here: its line is about a COUNT, which is the one
    /// thing about that gesture that cannot be recovered afterwards.)
    ///
    /// **`copyTabPath` is the eighth, and it was excluded for a reason that had already expired.**
    /// It wrote "User copied a tab's path: <absolute path>" — no side, and a path is not the chip:
    /// ⌘T opens the folder you are already in by design, so two strips holding same-titled chips at
    /// the same path is the ordinary state, not a corner. It sat outside this set because it is the
    /// one strip verb that moves no pane and so never went through `tabAction`; `becf9cbd` gave it
    /// `noteWorkingIn`, which put `isLeft` in its hands, and with that the exclusion was only
    /// habit. Its line keeps the absolute path on the end as well — that is what actually went onto
    /// the pasteboard, and `tabLogDescription` carries the relative one the chip is named for.
    @Test func theTabLinesNameTheSideTheTabAndItsPath() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        for verb in ["func selectTab(id: UUID, isLeft: Bool)",
                     "func cycleTab(forward: Bool, isLeft: Bool)",
                     "func closeTab(id: UUID, isLeft: Bool)",
                     "func duplicateTab(id: UUID, isLeft: Bool)",
                     "func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                     "func moveTab(id: UUID, to index: Int, isLeft: Bool)",
                     "func reopenClosedTab(isLeft: Bool)",
                     "func copyTabPath(id: UUID, isLeft: Bool)"] {
            let body = Self.codeOnly(try Self.memberBody(verb, in: source))
            #expect(body.contains("tabLogDescription("),
                    "“\(verb)” writes a line that names no particular tab")
            // **Every call, not the member.** This asked whether the side appeared ANYWHERE in the
            // member, and `closeTab` holds two log calls — the last-tab branch that closes the
            // WINDOW, and the ordinary close. The first satisfied the check for both, so stripping
            // the side from every ordinary ⌘W line was green. Through `PaneSideChoice.name`, whose
            // polarity `theSideChoiceReadsItsArgument` drives: the ternary this replaced could be
            // swapped to `isLeft ? "right" : "left"` and every line would name the wrong pane with
            // this scan still passing.
            let calls = Self.logCalls(in: body)
            #expect(!calls.isEmpty, "“\(verb)” writes no line at all")
            for call in calls {
                #expect(call.contains("PaneSideChoice.name(isLeft)"),
                        "“\(verb)” writes a line that does not say which pane it happened in — in Compare it is true of any tab in either strip: \(call.prefix(120))")
            }
        }
        // …and the description carries BOTH halves, which is the point: the title alone is the leaf
        // component ⌘T makes ambiguous by design, and a path alone is not what the chip says.
        let describe = try Self.memberBody("private func tabLogDescription(id: UUID, isLeft: Bool) -> String",
                                           in: source)
        #expect(describe.contains("paneTabItems(isLeft: isLeft)"),
                "the line names the tab by something other than the chip the user is looking at")
        #expect(describe.contains("combinedRelativePath"),
                "the line carries the leaf component only, which two tabs can share")
        // The ACTIVE entry is a stale snapshot, so describing it from the list would name the folder
        // that tab was parked at — the exact class of bug this log exists to catch.
        #expect(describe.contains("index == list.selectedIndex"),
                "the active tab is described from its parked snapshot rather than from the live pane")

        // Copy Path carries one thing more than the family does, and the loop above cannot see it:
        // the ABSOLUTE path, which is what went onto the pasteboard. `tabLogDescription` carries
        // the RELATIVE path — the thing the chip is named for — so a line built only from it would
        // no longer say what the user now has in their clipboard. Read from the log call onward
        // rather than over the member, where `item.fullPath` appears anyway on the `setString`.
        let copy = Self.codeOnly(try Self.memberBody("func copyTabPath(id: UUID, isLeft: Bool)",
                                                     in: source))
        let logCall = try #require(copy.range(of: "Logger.shared.info("),
                                   "Copy Path no longer writes its line at info")
        #expect(copy[logCall.upperBound...].contains("item.fullPath"),
                "Copy Path's line dropped the absolute path it put on the pasteboard — the relative path in `tabLogDescription` is not what was copied")
    }

    /// **Each line is taken from the side of its verb that can still answer**, and only one of the
    /// three faces the same way.
    ///
    /// Selecting and closing name the tab BEFORE the verb runs: a parked tab is described by its
    /// own snapshot, and after the switch that snapshot is the live pane's — after a close it is
    /// gone entirely. Cycling names it AFTER, and has to: *which* tab ⌃⇥ lands on is the verb's
    /// answer, and working it out here would be a second copy of `selectNext`'s wrap for the log to
    /// disagree with.
    ///
    /// Unscanned until now, on all three: the family test above asserts only that
    /// `tabLogDescription(` appears somewhere in the member. Moving `let closing = …` down into the
    /// closure below `syncManager.closeTab(…)` was a real surviving mutation — the id is gone by
    /// then, the line degrades to the bare `“a tab”` fallback, and every test in this repo passed.
    @Test func eachTabLineIsNamedFromTheSideOfItsVerbThatCanAnswer() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        // (member, the verb's own call, whether the name is taken before it)
        let verbs = [("func selectTab(id: UUID, isLeft: Bool)", "syncManager.switchTab(to: id", true),
                     ("func closeTab(id: UUID, isLeft: Bool)", "syncManager.closeTab(id: id", true),
                     ("func cycleTab(forward: Bool, isLeft: Bool)", "syncManager.cycleTab(forward: forward", false)]
        for (member, call, namedFirst) in verbs {
            let body = Self.codeOnly(try Self.memberBody(member, in: source))
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

    /// **Clicking the chip you are already on is a no-op, and must say so by saying nothing.**
    ///
    /// `PaneTabStrip` fires `onSelect(item.id)` from EVERY chip including the active one, and
    /// `FileSyncManager.switchTab` answers `nil` for exactly that case — so the line was written
    /// unconditionally for the most ordinary gesture in a tab strip, into the log he audits.
    /// `cycleTab` beside it already declines to claim a move it did not make, for a strictly rarer
    /// case (a one-tab pane), and `closeOtherTabs` skips its line at zero.
    ///
    /// The guard has to be on the INDEX rather than on moving the log below the verb: the name is
    /// taken while the tab is still parked (`eachTabLineIsNamedFromTheSideOfItsVerbThatCanAnswer`),
    /// so the two constraints pull opposite ways and only the index settles it.
    @Test func selectingTheChipYouAreAlreadyOnWritesNoLine() throws {
        let body = Self.codeOnly(try Self.memberBody("func selectTab(id: UUID, isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
        // Asked the way `switchTab` asks it — both halves. An id that is not in this strip does not
        // move the pane either, which is the other `nil` that verb returns.
        #expect(body.contains("list.index(of: id)"),
                "the no-op test does not ask where in the strip the clicked chip is")
        #expect(body.contains("target != nil && target != list.selectedIndex"),
                "the test the line is guarded on is no longer the one `switchTab` refuses on, so either a re-click logs again or a real switch goes unlogged")
        let gate = try #require(body.range(of: "if moves {"),
                                "the selection line is unconditional again — clicking the active chip logs a switch that did not happen")
        let log = try #require(body.range(of: "Logger.shared.debug("))
        let verb = try #require(body.range(of: "syncManager.switchTab(to: id"))
        // **Order first, then nesting.** A log line ABOVE the `if` is caught by the emptiness check
        // below — `textBetween` answers nil for it, which fails — but it fails saying the line is
        // "not inside the guard", which describes a line in the wrong branch rather than one that
        // is not in the branch at all. The distinction is the whole diagnosis when it breaks, and
        // it costs one comparison. Necessary and not sufficient, exactly as in
        // `closeOtherTabsSaysNothingWhenThereWasNothingToClose`: `if moves { }` with the log
        // unconditionally after it satisfies this and still logs every re-click, which is what the
        // emptiness check is for.
        #expect(gate.upperBound < log.lowerBound,
                "the line is written before the guard even opens, so it is not guarded at all and every re-click logs a switch that did not happen")
        #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                "the line is not inside the guard — an empty branch with the log after it reads the same way round and logs every re-click")
        #expect(log.upperBound < verb.lowerBound,
                "the line is written after the switch it announces")
    }

    /// **Close Other Tabs says nothing when it closed nothing.**
    ///
    /// The count came from `closableOthers`, which excludes pinned tabs — and the line was written
    /// *before* the verb ran, so an ⌥-click on the ✕ of a strip whose every other tab is pinned
    /// logged "User closed 0 other browse tabs, keeping 1 pinned": a sentence about something that
    /// did not happen, in the log he audits. The verb still has to run, because "leave me with this
    /// one" also makes the kept tab live.
    @Test func closeOtherTabsSaysNothingWhenThereWasNothingToClose() throws {
        let body = Self.codeOnly(try Self.memberBody("func closeOtherTabs(keeping id: UUID, isLeft: Bool)",
                                                     in: Self.source("ContentView+PaneTabs.swift")))
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
        // **Nesting, not order.** `gate.upperBound < log.lowerBound` proves only that the `if`
        // opens before the line — `if closing > 0 { }` with the log unconditionally after it holds
        // every comparison here and writes "User closed 0 other browse tabs, keeping 1 pinned"
        // again, verbatim. The line has to be the FIRST thing inside the branch.
        #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                "the line is not inside the `if closing > 0` branch — an ⌥-click with nothing to close still logs a close that did not happen")
    }

    /// **A mirrored ⌘T must not log the same sentence as the one that caused it.** Both panes open
    /// a tab at their own folder, so without a distinct line the log shows one keystroke firing
    /// twice in the same second — which reads as a bug in the very log used to rule bugs out.
    @Test func theMirroredNewTabSaysItIsTheMirror() throws {
        let body = try Self.memberBody("private func openTabHere(isLeft: Bool, mirrored: Bool = false)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("mirrored"), "the log line cannot tell a mirrored ⌘T from a real one")
        #expect(body.contains("Linked panes:"),
                "the mirrored line does not say the link is why it happened")
        #expect(try Self.memberBody("func openNewTabHere(isLeft: Bool)",
                                    in: Self.source("ContentView+PaneTabs.swift"))
                    .contains("mirrored: true"),
                "the mirror is opened without marking itself as one")
    }

    /// Reopen logs from *inside* the verb, so a press that brings nothing back writes no line
    /// claiming a tab did.
    ///
    /// **The item is disabled when there is nothing to reopen**, which this comment used to claim
    /// the opposite of: `shortcutReopenClosedTab` returns nil on a pane whose `canReopen` is false
    /// and `ReopenClosedTabCommand` is `.disabled(reopen == nil)`. The guard inside the verb is the
    /// defensive reading rather than the routine one — and it is still the only thing between an
    /// empty stack and a line asserting a reopen, which is what is pinned here.
    @Test func reopenOnlyClaimsATabWhenOneComesBack() throws {
        let body = try Self.memberBody("func reopenClosedTab(isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
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

    /// **Two Google Drive accounts both land on `My Drive`, and the mark cannot tell them apart.**
    ///
    /// This is the shipped strip: `My Drive · My Drive · iCloud`, with the two Drive chips carrying
    /// the same title AND the same brand mark. `Item.markImageName`'s doc says the mark is what
    /// separates two chips reading "Documents" — true across brands, and no help at all in the
    /// commonest collision there is, two accounts of one brand.
    @Test func twoSourcesLandingOnTheSameFolderNameAreQualifiedByTheirSource() {
        let items = PaneTabChips.items(
            list(["My Drive", "My Drive"], selected: 0,
                 providers: ["gdrive-personal", "gdrive-hpe"]),
            liveProviderId: "gdrive-personal", livePath: "My Drive", drawsColumns: true,
            source: { id in self.drive(id == "gdrive-personal" ? "Google Drive (Personal)"
                                                              : "Google Drive (HPE)") })
        #expect(items[0].title == "My Drive — Google Drive (Personal)")
        #expect(items[1].title == "My Drive — Google Drive (HPE)")
    }

    /// **A strip with no collision is left exactly as it was.**
    ///
    /// The control, and the reason the rule is "qualify where it separates" rather than "qualify
    /// always". Width is the strip's scarcest resource — the ladder folds chips away when it runs
    /// out — so a chip that grew "— iCloud Drive" for no reason costs a chip somewhere else.
    @Test func chipsThatAlreadyReadDifferentlyAreUntouched() {
        let items = PaneTabChips.items(list(["Finance", "Photos"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "Finance",
                                       drawsColumns: true, source: { _ in self.iCloud })
        #expect(items.map(\.title) == ["Finance", "Photos"])
    }

    /// One source, two folders sharing a leaf name: the parent is the smallest thing that separates
    /// them, and the source name would not (it is the same source).
    @Test func twoFoldersOnOneSourceSharingALeafNameAreQualifiedByTheirParent() {
        let items = PaneTabChips.items(
            list(["2026/Statements", "2025/Statements"], selected: 0),
            liveProviderId: "iCloud", livePath: "2026/Statements",
            drawsColumns: true, source: { _ in self.iCloud })
        #expect(items.map(\.title) == ["Statements — 2026", "Statements — 2025"])
    }

    /// **A duplicated tab is not a collision, and must not grow two identical suffixes.**
    ///
    /// Same source, same path — the two chips genuinely ARE the same folder, so neither qualifier
    /// separates them and both are left alone. Without the "only where it separates" test this reads
    /// `Statements — 2026 · Statements — 2026`: wider, folded sooner, and no more informative.
    @Test func aDuplicatedTabIsLeftAloneBecauseNothingSeparatesIt() {
        let items = PaneTabChips.items(
            list(["2026/Statements", "2026/Statements"], selected: 0),
            liveProviderId: "iCloud", livePath: "2026/Statements",
            drawsColumns: true, source: { _ in self.iCloud })
        #expect(items.map(\.title) == ["Statements", "Statements"])
    }

    /// A root chip already wears its source's name, so qualifying it with that same name would read
    /// `iCloud Drive — iCloud Drive`. The parent qualifier has nothing to offer at a root either, so
    /// the pair is left alone — which is honest: two tabs at one source's root are the same folder.
    @Test func rootChipsOnOneSourceAreNotQualifiedWithTheNameTheyAlreadyWear() {
        let items = PaneTabChips.items(list(["", ""], selected: 0),
                                       liveProviderId: "iCloud", livePath: "",
                                       drawsColumns: true, source: { _ in self.iCloud })
        #expect(items.map(\.title) == ["iCloud Drive", "iCloud Drive"])
    }

    /// **One setting, every way of walking into a folder.** The mirror predicate is the same
    /// expression `applyColumnNavigation` uses; two copies would let a link mean one thing for a
    /// drill and another for a tab, and nothing on screen would say which.
    @Test func theMirrorObeysTheSameLinkTestAsAMirroredDrill() throws {
        let predicate = "layoutMode == .compare\n            && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))"
        #expect(try Self.source("ContentView+PaneTabs.swift").contains(predicate),
                "the tab mirror invented its own link test")
        #expect(try Self.source("ContentView.swift").contains(predicate),
                "the mirrored drill's link test moved — the two have drifted apart")
    }
}
