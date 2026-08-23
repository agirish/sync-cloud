import Foundation
import Testing
@testable import Sync

/// Pins ``AutomationCondition/requiresContent`` — both the answer it gives today and the shape that
/// keeps it answering for the *next* case someone adds.
///
/// The shape matters more than the values here. `requiresContent` is what decides whether the file's
/// text is extracted at all, so a content-reading condition that answers `false` is handed nothing
/// to read: the rule passes `isRunnable`, shows a green pill, and then matches no file, ever — with
/// no error and nothing in the log. A `default: return false` makes that the automatic fate of every
/// case added after it, which is precisely how this switch was written before.
@Suite struct AutomationConditionTotalityTests {

    /// The two hand lists, hoisted so the roll-call below can check them against the enum's own
    /// declaration rather than against themselves.
    private static let readsText: [AutomationCondition] = [
        .contentContains("invoice"),
        .mentionsAll(["tesla"]),
    ]
    private static let doesNot: [AutomationCondition] = [
        .folderNamed("Downloads"),
        .nameMatches("*.pdf"),
        .kindIs(.pdf),
        .largerThanMB(10),
        .untouchedForDays(30),
        // This line's set: `personIs` and `unrecognized` are v4 cases with no counterpart here —
        // the roll-call below reads THIS line's enum, so the lists stay per-line by construction.
    ]

    /// Every case, with the answer it must give. Listed by hand rather than derived, so a change to
    /// an existing answer has to be made here too — the point of a pin.
    @Test func everyConditionAnswersRequiresContentAsSpecified() {
        for condition in Self.readsText {
            #expect(condition.requiresContent, "\(condition.kindKey) must ask for the file's text")
        }
        for condition in Self.doesNot {
            #expect(!condition.requiresContent, "\(condition.kindKey) must not force a text extraction")
        }
        let named = Set((Self.readsText + Self.doesNot).map(\.kindKey))
        #expect(named.count == Self.readsText.count + Self.doesNot.count, "a condition is listed twice above")
    }

    /// The roll-call the comment above always claimed and the old assertion never was: the old
    /// check compared the hand lists against THEMSELVES (no duplicates), so a tenth case added to
    /// the enum left this suite green while `requiresContent`'s answer for it went unpinned. The
    /// declared set comes from the enum's own body; the listed set comes from the values via
    /// `Mirror`, not `kindKey`, because `kindKey` for `.unrecognized` returns the carried payload
    /// name rather than the case.
    ///
    /// Mutation-verified 2026-08-22: un-listing `.personIs` fails this naming both sets.
    @Test func theHandListsNameEveryDeclaredCase() throws {
        let source = try Self.automationsSource()
        let body = try #require(
            Self.body(ofFirst: "public enum AutomationCondition: Sendable, Equatable, Codable, Hashable {",
                      in: source),
            "the AutomationCondition declaration moved or was respelled — update this anchor")
        // Declarations only: switch arms inside the enum's computed properties are spelled
        // `case .name`, so the leading-dot filter separates them.
        let declared = Set(body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") && !$0.hasPrefix("case .") }
            .compactMap { line in
                line.dropFirst("case ".count)
                    .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            }
            .map(String.init)
            .filter { !$0.isEmpty })
        try #require(declared.count > 5,
                     "only \(declared.count) case declarations parsed — the parser is broken, not the enum")

        let listed = Set((Self.readsText + Self.doesNot).map { condition in
            Mirror(reflecting: condition).children.first?.label ?? String(describing: condition)
        })
        #expect(listed == declared,
                "the hand lists and the enum disagree — a case with no pinned requiresContent answer ships silent: declared \(declared.sorted()), listed \(listed.sorted())")
    }

    /// The switch must stay total: no `default:`, so adding a case is a build error rather than a
    /// silent `false`.
    @Test func requiresContentSwitchHasNoDefaultBranch() throws {
        let source = try Self.automationsSource()
        let body = try #require(Self.body(ofFirst: "public var requiresContent: Bool {", in: source),
                                "Could not find requiresContent in Automations.swift — the scan found nothing to check, which is not the same as finding nothing wrong.")
        // Prove the slice is the CONDITION's property and not ``AutomationRule/requiresContent``,
        // which is a one-line `contains` over the array and has no switch to be total about.
        #expect(body.contains(".contentContains"),
                "Found a requiresContent body, but not the condition's — the anchor above needs fixing.")
        let complaint = "requiresContent switches on a `default:` again. A new condition that reads "
            + "text will answer false, never be given a snippet, and match nothing — silently. Name "
            + "the cases instead:\n\(body)"
        #expect(!body.contains("default:"), Comment(rawValue: complaint))
    }

    // MARK: Scanning

    private static func automationsSource() throws -> String {
        // Tests/Sync/<this file> -> package root is three levels up.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Sync
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/Sync/Automations.swift"),
            encoding: .utf8)
    }

    /// The text between `header`'s opening brace and its matching close, or nil when the header
    /// isn't there. Brace counting rather than a line range so the slice can't quietly run past the
    /// property into whatever follows it.
    private static func body(ofFirst header: String, in source: String) -> String? {
        guard let headerRange = source.range(of: header) else { return nil }
        var depth = 1
        var index = headerRange.upperBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[headerRange.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
