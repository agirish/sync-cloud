import Foundation
import Testing
@testable import Sync

/// §5.6's "say it the month it happens", as the rule that decides (proposal O15).
///
/// Every date here is injected. The one thing this feature must never do is behave differently in
/// December than in the January it was written in, and a rule reading `Date()` could not be asked.
@Suite struct RestructureNudgeTests {

    private static func backlog(_ subject: String, scaffold: [String] = ["Claims"])
        -> StructureFinding {
        StructureFinding(kind: .backlog,
                         family: (subject as NSString).deletingLastPathComponent,
                         subject: subject,
                         detail: .backlog(scaffold: scaffold, looseFiles: 3))
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // MARK: What is due

    /// The current year's gap is news; an older one is a standing fact the lens already states.
    @Test func onlyTheCurrentYearIsDue() {
        let findings = [Self.backlog("Health/Dental/2026"),
                        Self.backlog("Health/Dental/2024"),
                        Self.backlog("Work/Benefits/2026")]
        let due = RestructureNudge.due(in: findings, now: Self.date("2026-01-09T10:00:00Z"),
                                       acknowledged: [:])
        #expect(due.map(\.finding.subject) == ["Health/Dental/2026", "Work/Benefits/2026"])
        #expect(due.allSatisfy { $0.year == "2026" })

        // The same tree in the following January: last year's gap has stopped being news and this
        // year's has started.
        let next = RestructureNudge.due(in: findings, now: Self.date("2027-01-09T10:00:00Z"),
                                        acknowledged: [:])
        #expect(next.isEmpty, "nothing in this tree is about 2027 yet")
    }

    /// **It is the year, not the month.** The proposal's name says January; the rule says "this
    /// year", because a gap noticed in March is still this year's gap and a rule that only spoke
    /// in January would be silent for eleven months about a folder that never got made.
    @Test func aGapNoticedInMarchIsStillDue() {
        let due = RestructureNudge.due(in: [Self.backlog("Health/Dental/2026")],
                                       now: Self.date("2026-03-20T10:00:00Z"),
                                       acknowledged: [:])
        #expect(due.count == 1)
    }

    /// Only a backlog with something to create. A backlog whose siblings vouch for no shape has
    /// no verb to offer, and a line with nothing to do is the caution people scroll past.
    @Test func aBacklogWithNothingToCreateIsNotDue() {
        #expect(RestructureNudge.due(in: [Self.backlog("Health/Dental/2026", scaffold: [])],
                                     now: Self.date("2026-02-01T10:00:00Z"),
                                     acknowledged: [:]).isEmpty)
    }

    /// Other kinds never nudge, whatever their subject looks like.
    @Test func onlyBacklogFindingsNudge() {
        let shadow = StructureFinding(
            kind: .shadowAxis, family: "Finance", subject: "Finance/2026",
            detail: .shadowAxis(target: "2026", targetExists: true))
        #expect(RestructureNudge.due(in: [shadow], now: Self.date("2026-01-09T10:00:00Z"),
                                     acknowledged: [:]).isEmpty)
    }

    /// A fiscal span is a deliberate two-year folder, and "the month it happens" is not a thing
    /// about it — `looksLikeYear` accepts the span, so the rule takes bare years only.
    @Test func aFiscalSpanIsNotAYear() {
        #expect(RestructureNudge.year(of: "Finance/IN/SBI/2025-2026") == nil)
        #expect(RestructureNudge.year(of: "Health/Dental/2026") == "2026")
        #expect(RestructureNudge.year(of: "Health/Dental/Claims") == nil)
        #expect(RestructureNudge.due(in: [Self.backlog("Finance/IN/SBI/2025-2026")],
                                     now: Self.date("2026-01-09T10:00:00Z"),
                                     acknowledged: [:]).isEmpty)
    }

    // MARK: Acknowledgement, and why it carries a year

    /// **Dismissing silences this year and not the next one.** A flag would have made the first
    /// dismissal permanent, which is the opposite of a feature whose whole argument is that the
    /// gap recurs.
    @Test func anAcknowledgementIsForOneYearOnly() {
        let finding = Self.backlog("Health/Dental/2026")
        let key = RestructureKey(kind: .backlog, path: "Health/Dental/2026")

        #expect(RestructureNudge.due(in: [finding], now: Self.date("2026-01-09T10:00:00Z"),
                                     acknowledged: [key: "2026"]).isEmpty,
                "dismissed for 2026")
        #expect(RestructureNudge.due(in: [finding], now: Self.date("2026-01-09T10:00:00Z"),
                                     acknowledged: [key: "2025"]).count == 1,
                "a dismissal from last year does not carry forward")

        // And next year's own folder is a fresh nudge under a fresh key.
        #expect(RestructureNudge.due(in: [Self.backlog("Health/Dental/2027")],
                                     now: Self.date("2027-01-05T10:00:00Z"),
                                     acknowledged: [key: "2026"]).count == 1)
    }

    /// One acknowledgement does not silence a different family's gap in the same year.
    @Test func anAcknowledgementIsPerFinding() {
        let due = RestructureNudge.due(
            in: [Self.backlog("Health/Dental/2026"), Self.backlog("Work/Benefits/2026")],
            now: Self.date("2026-01-09T10:00:00Z"),
            acknowledged: [RestructureKey(kind: .backlog, path: "Health/Dental/2026"): "2026"])
        #expect(due.map(\.finding.subject) == ["Work/Benefits/2026"])
    }

    // MARK: The sentence

    /// One, two, and more than two — the third form counts rather than listing, because a
    /// sentence naming nine families is a list wearing a sentence's punctuation.
    @Test func theSentenceNamesTwoAndThenCounts() throws {
        func sentence(_ subjects: [String]) -> String? {
            RestructureNudge.sentence(for: RestructureNudge.due(
                in: subjects.map { Self.backlog($0) }, now: Self.date("2026-01-09T10:00:00Z"),
                acknowledged: [:]))
        }
        #expect(sentence(["Health/Dental/2026"])
                    == "2026 has files but no folders yet in Health/Dental.")
        #expect(sentence(["Health/Dental/2026", "Work/Benefits/2026"])
                    == "2026 has files but no folders yet in Health/Dental and Work/Benefits.")
        let many = try #require(sentence(["Health/Dental/2026", "Work/Benefits/2026",
                                          "Finance/US/2026", "Travel/2026"]))
        #expect(many.contains("Health/Dental, Work/Benefits and 2 more"))
        #expect(RestructureNudge.sentence(for: []) == nil, "nothing due says nothing")
    }
}
