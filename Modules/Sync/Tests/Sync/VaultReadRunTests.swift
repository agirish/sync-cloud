import Foundation
import Testing
@testable import Sync

/// One read's rules, with no model (VT7): when an account's older years need no opening, the one
/// unlabelled number two years print, and the progress and stop line it says.
@Suite struct VaultReadRunTests {
    static func step(_ name: String, account: String? = "acct") -> VaultReadPlan.Step {
        VaultReadPlan.Step(file: URL(fileURLWithPath: "/papers/\(name).pdf"), account: account)
    }

    @Test func twoYearsThatAgreeSettleAnAccount() {
        var run = VaultReadRun(scope: .discover, total: 4, documents: 9)
        run.settle(Self.step("2026"), numbers: ["A1"])
        #expect(!run.passesOver(Self.step("2025")), "one year alone settles nothing")
        run.settle(Self.step("2025"), numbers: ["A2"])
        #expect(!run.passesOver(Self.step("2024")), "two years that differ settle nothing")
        run.settle(Self.step("2024"), numbers: ["A2"])
        #expect(run.passesOver(Self.step("2023")), "the two newest read agree: the older years say the same")
        #expect(!run.passesOver(Self.step("other", account: "other")), "another account is its own")
        #expect(!run.passesOver(Self.step("loose", account: nil)), "a file of no account is always opened")
    }

    @Test func threeEmptyYearsSettleAnAccountTwoDoNot() {
        var run = VaultReadRun(scope: .discover, total: 4, documents: 4)
        run.settle(Self.step("2026"), numbers: [])
        run.settle(Self.step("2025"), numbers: [])
        #expect(!run.passesOver(Self.step("2024")), "a phone bill that stopped labelling its number in 2025 still did in 2024")
        run.settle(Self.step("2024"), numbers: [])
        #expect(run.passesOver(Self.step("2023")))
        // Empty years after a year that gave a number never settle it.
        var later = VaultReadRun(scope: .discover, total: 5, documents: 5)
        later.settle(Self.step("2026"), numbers: ["A1"])
        for year in ["2025", "2024", "2023"] { later.settle(Self.step(year), numbers: []) }
        #expect(!later.passesOver(Self.step("2022")))
        #expect(!later.hasNoNumbers("acct") && run.hasNoNumbers("acct"))
    }

    @Test func aRefreshOpensEveryDocumentItWasAskedTo() {
        var run = VaultReadRun(scope: .refresh(only: nil), total: 3, documents: 3)
        run.settle(Self.step("2026"), numbers: ["A1"])
        run.settle(Self.step("2025"), numbers: ["A1"])
        #expect(!run.passesOver(Self.step("2024")))
    }

    @Test func oneUnlabelledNumberTwoYearsPrintIsTheAccounts() {
        var run = VaultReadRun(scope: .discover, total: 3, documents: 3)
        #expect(run.repeatedBareNumber(["8005550100", "41178"], for: "acct", in: "/papers/2026.pdf") == nil,
                "first year: remembered, not taken")
        let found = run.repeatedBareNumber(["41178", "9"], for: "acct", in: "/papers/2025.pdf")
        #expect(found?.value == "41178" && found?.earlier == "/papers/2026.pdf")
        #expect(run.passesOver(Self.step("2024")), "read far enough")
    }

    @Test func twoUnlabelledNumbersBothYearsPrintAreNotGuessedAt() {
        var run = VaultReadRun(scope: .discover, total: 4, documents: 4)
        _ = run.repeatedBareNumber(["8005550100", "41178"], for: "acct", in: "/papers/2026.pdf")
        #expect(run.repeatedBareNumber(["8005550100", "41178"], for: "acct", in: "/papers/2025.pdf") == nil)
        #expect(!run.passesOver(Self.step("2024")))
        // Another account's numbers are its own; and a later year printing only one of the two
        // gives it, with the first file that printed it as its earlier year.
        #expect(run.repeatedBareNumber(["41178"], for: "other", in: "/papers/o.pdf") == nil)
        let found = run.repeatedBareNumber(["41178", "7"], for: "acct", in: "/papers/2024.pdf")
        #expect(found?.value == "41178" && found?.earlier == "/papers/2026.pdf")
    }

    @Test func theProgressAndTheStopLineSayTheScopeAndCounts() {
        var run = VaultReadRun(scope: .refresh(only: nil), total: 7, documents: 30)
        #expect(run.progress(done: 3) == VaultModel.ReadingProgress(done: 3, total: 7, scope: .refresh(only: nil)))
        #expect(run.tally.documents == 30)
        run.tally.record([["a page"]], ([], []))
        #expect(run.stoppedLine(at: 2) == "Vault: read stopped at 2 of 7 document(s), 1 opened; "
                + "the Vault closed or locked, and what was read is kept")
    }
}
