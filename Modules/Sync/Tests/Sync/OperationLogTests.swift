import Foundation
import Testing
@testable import Sync

/// The start and finish lines of a bulk sync and Verify All. A run that passes its guards writes
/// both whatever comes of it, so an all-failed or cancelled run still ends in the log, under the
/// run ID its Sync History records carry.
@Suite struct OperationLogTests {
    let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    @Test func theStartLineNamesTheRunTheCountTheSizeAndBothSides() {
        #expect(BulkRunLog.start(runId: id, isMove: false, items: 3, bytes: 2048, from: "/L", to: "/R")
                == "Bulk sync 00000000-0000-0000-0000-0000000000AB started: 3 item(s), 2 KB, /L → /R")
        #expect(BulkRunLog.start(runId: id, isMove: true, items: 1, bytes: nil, from: "/L", to: "/R")
                .hasPrefix("Bulk move 00000000-0000-0000-0000-0000000000AB started: 1 item(s), /L"))
    }

    @Test func theFinishLineCountsEveryRowTheRunWasOffered() {
        #expect(BulkRunLog.finish(runId: id, isMove: false,
                                  counts: .init(done: 0, failed: 5, held: 1, skipped: 2, canceled: 3),
                                  elapsed: "1.20 s")
                == "Bulk sync 00000000-0000-0000-0000-0000000000AB finished (1.20 s): 0 copied, 5 failed, "
                   + "1 held for a decision, 2 skipped, 3 not reached (canceled)")
        #expect(BulkRunLog.finish(runId: id, isMove: true, counts: .init(done: 4), elapsed: "9.0 ms")
                == "Bulk move 00000000-0000-0000-0000-0000000000AB finished (9.0 ms): 4 moved")
    }

    @Test func aRunWithEveryRowHeldStillSaysSo() {
        #expect(BulkRunLog.allHeld(isMove: false, held: 2) == "Bulk sync: nothing to copy — 2 item(s) held for a decision")
    }

    @Test func verifyAllsFinishLineCountsACancelsUnreachedPairs() {
        #expect(VerifyAllLog.finish(identical: 2, differed: 1, skipped: 0, of: 5, canceled: true, elapsed: "3.00 s")
                == "Verify All canceled (3.00 s): 2 identical, 1 differed, 0 couldn’t be verified, 2 not reached of 5 pair(s)")
        #expect(VerifyAllLog.finish(identical: 3, differed: 0, skipped: 1, of: 4, canceled: false, elapsed: "1.0 ms")
                == "Verify All finished (1.0 ms): 3 identical, 0 differed, 1 couldn’t be verified of 4 pair(s)")
    }

    @Test func aNameListKeepsEveryNameSortedAtMostTwoHundredALine() {
        #expect(LogNames.lines("X", []) == [])
        #expect(LogNames.lines("X", ["b", "a"]) == ["X: a, b"])
        let many = (1...401).map { String(format: "n%03d", $0) }
        let lines = LogNames.lines("X", many.reversed())
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("X 1–200 of 401: n001, n002"))
        #expect(lines[2] == "X 401–401 of 401: n401")
    }

    /// A system error gives its domain, code and message, and its underlying error, and never the
    /// userInfo's paths; the app's own Swift errors keep their description, which is their reason.
    @Test func anErrorIsWrittenByItsDomainNotItsUserInfo() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let cocoa = CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: "/Users/someone/Secret/plan.json",
                                                             NSUnderlyingErrorKey: underlying])
        let text = LogError.describe(cocoa)
        #expect(text.hasPrefix("NSCocoaErrorDomain 512: "))
        #expect(text.hasSuffix("(underlying NSPOSIXErrorDomain 28)"))
        #expect(!text.contains("/Users/someone"), "the userInfo's path reached the line: \(text)")
        struct Refusal: Error, CustomStringConvertible { var description: String { "schema 3, not 2" } }
        #expect(LogError.describe(Refusal()) == "schema 3, not 2")
    }

    /// A run's failures group by kind, never by description, which names the file: two disk-full
    /// failures on different files are one group naming both; a different code is its own group.
    @Test func failuresGroupByTheirKindAndKeepEveryName() {
        let full = CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/d/a.txt"])
        let full2 = CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/d/b.txt"])
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/d/c.txt"])
        let lines = GroupedFailureLog.lines("Bulk sync", [("/d/b.txt", full2), ("/d/a.txt", full), ("/d/c.txt", denied)])
        let heads = lines.filter { $0.contains("item(s) failed") }
        #expect(heads.count == 2, "\(lines)")
        #expect(lines.contains("Bulk sync: failed (\(LogError.groupReason(full))): /d/a.txt, /d/b.txt"), "\(lines)")
        #expect(lines.contains { $0.hasSuffix(": /d/c.txt") })
    }

    /// The app's own `SyncError`s all bridge to one domain and code; their titles keep them apart.
    @Test func syncErrorsGroupByTitle() {
        let a = SyncError(title: "Copy Failed", message: "x", path: nil, reason: nil, isRetryable: false)
        let b = SyncError(title: "Move Failed", message: "x", path: nil, reason: nil, isRetryable: false)
        #expect(LogError.groupKey(a) != LogError.groupKey(b))
    }

    @Test func longNamesSplitByBytesAsWellAsCount() {
        let long = (1...10).map { _ in String(repeating: "x", count: 3_000) + UUID().uuidString }
        let lines = LogNames.lines("X", long)
        #expect(lines.count >= 2, "10 names of 3 KB in one line")
        #expect(lines.allSatisfy { $0.utf8.count < LogNames.bytesPerLine + 4_000 })
        #expect(Set(long).allSatisfy { name in lines.contains { $0.contains(name) } }, "a name was dropped")
    }

    /// The first warnings of a scan get their lines; every file past them is named at the end.
    @Test func aScansWarningBudgetNamesEveryFilePastIt() {
        let budget = FilingWarningBudget()
        let admitted = (1...25).filter { budget.admit("f\($0).jpg") }
        #expect(admitted.count == FilingWarningBudget.allowed)
        let closing = budget.overflowLines()
        #expect(closing.count == 1)
        #expect((21...25).allSatisfy { n in closing[0].contains("f\(n).jpg") }, "\(closing)")
    }
}
