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

    /// Every case, with the answer it must give. Listed by hand rather than derived, so a change to
    /// an existing answer has to be made here too — the point of a pin.
    @Test func everyConditionAnswersRequiresContentAsSpecified() {
        let readsText: [AutomationCondition] = [
            .contentContains("invoice"),
            .mentionsAll(["tesla"]),
        ]
        let doesNot: [AutomationCondition] = [
            .folderNamed("Downloads"),
            .nameMatches("*.pdf"),
            .kindIs(.pdf),
            .largerThanMB(10),
            .untouchedForDays(30),
            // A judgement, not an oversight: see the note on `requiresContent`. A person is almost
            // always named in the filename, and forcing a text extraction per person rule would
            // spend seconds a scan to catch the minority case.
            .personIs("aditi"),
            // Never `isComplete`, so in production this is never asked — but it still has to answer.
            .unrecognized(name: "fromAFutureBuild", payload: Data("{}".utf8)),
        ]
        for condition in readsText {
            #expect(condition.requiresContent, "\(condition.kindKey) must ask for the file's text")
        }
        for condition in doesNot {
            #expect(!condition.requiresContent, "\(condition.kindKey) must not force a text extraction")
        }
        // The two lists together must name every case, or this pin is only checking the ones it
        // happens to know. `kindKey` is written case by case in the same file, so it is the closest
        // thing to a roll-call the type offers.
        let named = Set((readsText + doesNot).map(\.kindKey))
        #expect(named.count == readsText.count + doesNot.count, "a condition is listed twice above")
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
