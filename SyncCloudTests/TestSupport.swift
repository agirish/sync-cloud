import Testing
import Foundation

/// Polls a main-actor condition until it holds or the timeout expires, recording a labeled failure
/// on timeout. The app target's counterpart to `Modules/Sync/Tests/Sync/TestSupport.swift`'s helper,
/// and for the same reason: a fixed `Task.sleep` long enough to be reliable is also long enough to
/// be slow, and one short enough to be quick flakes the moment a parallel suite congests the main
/// actor. 13cfb93 removed the last of those from the Sync suites after proving they lose the race
/// on a loaded CI runner; always wait for the observable effect, never a guessed duration.
///
/// Reports its timeout at the CALL SITE; keep the forwarded `sourceLocation` in step with the Sync
/// copy. Without it every caller's failure anchors here instead of naming a test file.
///
/// **Bounded by POLLS as well as by seconds**, and the seconds are the weaker of the two: what this
/// waits for arrives on main-actor turns, and a congested run has fewer of them per second, not
/// more. The Sync copy carries the measurements; the short version is that a poll's nominal cost is
/// its 10 ms sleep and the worst rate measured under load was 223 ms, so the deadline shrinks — in
/// the only unit that matters — exactly when the wait needs it most. Keep the floor in step with
/// the other two copies (Sync's, and Dashboard's `WaitSupport.swift`) along with everything else here.
@MainActor
func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    var polls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // The poll count IS the diagnosis: a handful means starved, hundreds means disproved.
    #expect(condition(), "\(what.rawValue) — still false after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// The fewest polls `waitUntil` will make before it may give up, however little of its deadline is
/// left. Same number, and the same reason, as `LayoutPumpWait.pumpFloor` in the FileExplorer test
/// target and `pollFloor` in `ShortcutRevealTrackerTests`.
let waitPollFloor = 50

// MARK: - Reading the app target's own source

/// Every Swift file in `MacApp/`, concatenated — **the haystack for a source scan whose subject is
/// a call site rather than a file.**
///
/// `MacApp/` is in no SPM package, so a good deal of it is only reachable from a test as text; the
/// suites that do that have each named one file. Naming a file pins two things at once and only one
/// of them is the check's business: that the call reads what it should, and that it happens to live
/// in `ContentView.swift`. Nobody chose the second — moving `func paneColumn(isLeft:)` into a file
/// of its own would fail seven assertions across four tests with nothing whatsoever wrong — and a
/// test that fails for a reason it is not about teaches the next reader to edit tests to make moves
/// possible.
///
/// Reading the directory keeps every assertion's substance and drops only the locality. It is also
/// strictly stronger for a COUNT: a second copy of a rule now fails wherever in `MacApp/` it is
/// written, which is exactly the case (a copy in a second file) that has been missed before.
///
/// **Two kinds of check must keep naming their file**: a positive control, which needs a text known
/// to contain something in order to prove the reader works at all; and any `!contains` whose string
/// another file legitimately says — over the whole directory that assertion could only ever fail.
///
/// No per-file length guard, deliberately: adding a twenty-line enum to `MacApp/` should not fail a
/// suite with "implausibly short". The non-vacuity this needs is on the result, which is asserted.
func macAppSources() throws -> String {
    let directory = macAppDirectory()
    let urls = try #require(try? FileManager.default.contentsOfDirectory(
                                at: directory, includingPropertiesForKeys: nil),
                            "cannot list MacApp/ — every check below would be vacuous")
    let names = urls.filter { $0.pathExtension == "swift" }.map(\.lastPathComponent).sorted()
    try #require(names.count > 10,
                 "MacApp/ listed \(names.count) Swift file(s) — the reader is broken, not the app")
    var joined = ""
    for name in names {
        let text = try #require(
            try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
            "cannot read MacApp/\(name) — the scans below would be reading a partial app")
        joined += text + "\n"
    }
    try #require(joined.count > 10_000,
                 "MacApp/ read as \(joined.count) characters — the scans below would be near-vacuous")
    return joined
}

/// `MacApp/`, located from this file rather than from a working directory — the test bundle does
/// not promise one.
func macAppDirectory() -> URL {
    URL(fileURLWithPath: #filePath)          // …/SyncCloudTests/TestSupport.swift
        .deletingLastPathComponent()         // …/SyncCloudTests
        .deletingLastPathComponent()         // repo root
        .appendingPathComponent("MacApp")
}

/// The text between two positions found by **separate** `range(of:)` searches — `nil` when they
/// come back out of order, rather than a trap.
///
/// `body[first.upperBound..<second.lowerBound]` is how a scan asks "what sits between these two
/// lines", and it is only valid while the two searches happen to land in the expected order —
/// which is exactly what the surrounding assertions are there to doubt. When the order does not
/// hold, `Range` traps: `Fatal error: Range requires lowerBound <= upperBound`. That is
/// `_assertionFailure`, inside `#expect`'s own expression, so it takes down the **whole test
/// host** — and with it every remaining test in the run. Two crash reports on 2026-08-16
/// (`SyncCloud-2026-08-16-185034{,.000}.ips`) are that trap, from
/// `theLostFolderLineDoesNotClaimARestoreThatWasAbandoned` while the regression it guards was
/// still live: the assertion did its job and the run died reporting infrastructure instead.
///
/// **`#expect` records and continues**, which is the half that makes this a hazard rather than a
/// typo. An ordering `#expect` on the line above does not stop the slice on the line below from
/// running with the order it just disproved; only `#require` would, and these tests deliberately
/// keep going so their other assertions still report.
///
/// So the ordering becomes part of the answer. Compare against `== true` at the call site and a
/// `nil` **fails** the expectation — no crash, and no vacuous pass either:
///
/// ```swift
/// #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound)?.contains("return") == true, "…")
/// ```
///
/// Prefer searching from after the first match — `content[x.upperBound...].range(of:)`, or
/// `range(of:_:range:)` — wherever the second thing genuinely *is* "the next one after the first",
/// since that makes the order structural and needs no helper. This exists for the other case: two
/// independent searches whose relative order is itself under test.
///
/// The guard below is pinned by `TextBetweenTests`, and needs to be: every call site passes its
/// positions in the right order while the code it scans is correct, so deleting the guard leaves
/// the whole target green. That suite is the only thing standing between a "simplification" back
/// to `String(source[from..<to])` and five crashing scans.
func textBetween(_ source: String, from: String.Index, to: String.Index) -> String? {
    guard from <= to else { return nil }
    return String(source[from..<to])
}

/// Source with whole-line `//` comments removed — what a source scan should be asking its
/// questions of, since prose is not code and has answered several of them wrongly.
func sourceCodeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// One declaration's body, bounded by its **closing brace** rather than by a character count —
/// **and read out of comment-stripped source, which is the half that was missing.**
///
/// Three suites in this target had a copy of this, in three different states: two with no
/// uniqueness guard at all, and one whose guard counted occurrences over `codeOnly` while
/// `range(of:)` still searched the RAW text. That last combination is worth naming, because it
/// looks exactly like the guard it isn't: a decoy inside a doc comment above the real declaration
/// is invisible to the count (so `occurrences == 1` passes) and is still the first thing
/// `range(of:)` finds (so the slice is the decoy's). The guard was added to stop a first-match
/// read; against a commented decoy it stopped nothing.
///
/// Stripping first settles both at once — the search, the count and the slice now see the same
/// text, so the guard means what it says. It also makes every `!contains` below stronger for free:
/// a body cannot answer "absent" because the phrase it was asked about only appeared in that
/// member's own prose, which is precisely how `paneSelectionNodes`' two negatives came to be
/// answered by `paneActionBar`'s doc comment.
///
/// **One member, deliberately.** The three copies had already drifted apart; teaching one of them
/// this and leaving the others reading raw text is how the next reader inherits the old answer.
/// `OrganizeScopeCallSiteTests` keeps its own — it is in the FileExplorer module and cannot see
/// this one — and carries the same fix.
func declarationBody(of declaration: String, in source: String) throws -> String {
    let code = sourceCodeOnly(source)
    let occurrences = code.components(separatedBy: declaration).count - 1
    // **Two failures, two messages.** A single `occurrences == 1` check reports the far commoner
    // one — the member was renamed, so it occurs 0× — as "range(of:) would silently read the
    // first", which describes the opposite problem and sends the reader looking for a duplicate
    // that isn't there. Absence first, then ambiguity.
    try #require(occurrences > 0,
                 "\(declaration) is gone — the scan below would be vacuous")
    try #require(occurrences == 1,
                 "\(declaration) occurs \(occurrences)× in code — range(of:) would silently read the first, so every check below would be about the wrong member")
    // Cannot fail after the count above: both read `code`, and one match was just counted. The
    // message says so, because a `#require` whose message names an impossible cause is how a
    // harness bug gets read as a code bug.
    let start = try #require(code.range(of: declaration),
                             "counted \(declaration) once but could not find it — the reader is broken, not the app")
    let rest = code[start.upperBound...]
    let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
    return String(rest[..<end.lowerBound])
}

/// A throwaway `UserDefaults` suite, so a test can pin a defaults-driven decision without writing
/// into the app's real domain — which, when the test host IS the app, is the user's live settings.
/// Mirrors `Modules/Settings/Tests/Settings`' helper of the same name. Always `defer { wipe() }`.
struct TestDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(_ function: String = #function) {
        self.suiteName = "SyncCloudTests-\(function)-\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suiteName)!
    }

    func wipe() {
        wipeDefaultsSuite(suiteName)
    }
}

// MARK: - Scratch defaults suites

/// Removes a throwaway defaults suite *and* its backing plist.
///
/// `removePersistentDomain(forName:)` only empties the domain: cfprefsd still leaves an empty
/// `~/Library/Preferences/<suite>.plist` behind, and neither `removeSuite(named:)` nor
/// `CFPreferencesAppSynchronize` reclaims it either — all four combinations were measured on
/// 2026-07-26 and every one left the file on disk. Because each scratch suite is named with a
/// fresh UUID, that is one stray file per suite per run: 26,047 had accumulated across the six
/// test targets before this was caught, at which point `defaults domains` — which enumerates the
/// whole directory — took minutes. Unlinking the file is the only thing that actually reclaims it.
///
/// Mirrored verbatim in every test target, since they are separate SPM packages with no shared
/// test-support module; keep the copies in step.
func wipeDefaultsSuite(_ name: String) {
    // Recorded here rather than at the call sites because this is the one funnel every cleanup
    // path — `defer`, `TestDefaults.wipe()`, `ScratchDefaults.deinit` — already goes through.
    // Recording only in `ScratchDefaults` missed the 46 `defer` sites, which build their suite
    // with a plain `UserDefaults(suiteName:)`, and Sync's leftovers grew 58 -> 89 -> 135 over
    // three runs because nothing was there to re-delete what cfprefsd had resurrected.
    scratchDefaultsLedger.record(name)
    UserDefaults.standard.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(atPath: path)
}

/// Finishes the cleanup that the previous test run could not.
///
/// `wipeDefaultsSuite` reclaims the file for the great majority of suites, but cfprefsd is a
/// separate daemon and may write a suite's plist back out *after* the test process has exited.
/// That race is not winnable from inside the process: an `atexit` sweep that unlinked all 34 of a
/// Dashboard run's suites still lost it for the two whose defaults object was held past the test
/// by an undo registration. So every suite handed to `wipeDefaultsSuite` is recorded, and the next
/// run deletes whatever the last one left behind, which keeps the directory bounded at about one
/// run's stragglers instead of growing without limit. The gap this cannot close is a run that dies
/// before its cleanup runs at all: those suites are never recorded, so they are never swept.
let scratchDefaultsLedger = ScratchDefaultsLedger()

final class ScratchDefaultsLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var didSweepPreviousRun = false

    private let ledgerPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Caches/SyncCloudTestScratchSuites.ledger")
    private let preferencesDirectory = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences")

    /// Records `name`, sweeping the previous run's leftovers on the first call of this process.
    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        if !didSweepPreviousRun {
            didSweepPreviousRun = true
            sweepPreviousRun()
        }
        guard let line = "\(name)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: ledgerPath) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: URL(fileURLWithPath: ledgerPath))
        }
    }

    private func sweepPreviousRun() {
        sweepStaleScratchPlists()
        guard let recorded = try? String(contentsOfFile: ledgerPath, encoding: .utf8) else { return }
        for name in recorded.split(separator: "\n") {
            try? FileManager.default.removeItem(atPath: "\(preferencesDirectory)/\(name).plist")
        }
        try? FileManager.default.removeItem(atPath: ledgerPath)
    }

    /// Deletes scratch plists the ledger can never account for, matching by SHAPE rather than name.
    ///
    /// A name only reaches the ledger when the test owning it gets to its cleanup. Most creation
    /// sites are a bare `UserDefaults(suiteName:)` paired with a `defer`, so a run that is KILLED
    /// — a cancelled CI job, an interrupted `swift test`, a mutation experiment stopped by hand —
    /// leaves suites that were never recorded and that no later run can name. That is not a
    /// theoretical gap: 3,551 had accumulated by 2026-08-03, and a cold `defaults domains`, which
    /// enumerates this directory, had gone from ~0.1s to 2.38s. Matching by shape closes it for
    /// every creation site at once, recorded or not.
    ///
    /// The age floor is what makes this safe to run while other sessions are testing — this Mac
    /// routinely has several worktrees running suites at once, and their live suites are minutes
    /// old at most. An hour is far past any test's lifetime, and still bounds the directory at
    /// about one hour of stragglers rather than letting it grow without limit.
    /// Internal, not private, so its two dangerous edges can be tested directly: a stale scratch
    /// plist really is deleted, and a real domain with a lowercase UUID really is not. Going
    /// through `record`'s once-per-process trigger instead would make those tests depend on
    /// which one ran first, and pass vacuously in whichever order lost.
    func sweepStaleScratchPlists() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: preferencesDirectory) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where Self.isScratchSuitePlist(name) {
            let path = "\(preferencesDirectory)/\(name)"
            guard let modified = try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    /// `<prefix><separator><UUID>.plist`, with the UUID in the UPPERCASE form `UUID().uuidString`
    /// emits — which is what every scratch suite name here ends in. Both separators are in use:
    /// `ScratchDefaults` joins with `-`, a few call sites with `.`.
    ///
    /// The uppercase requirement is the safety margin, not a detail: real preference domains that
    /// carry a UUID write it lowercase (`com.openai.chat.RemoteFeatureFlags.164320f2-…`), so they
    /// cannot match. Loosen this to case-insensitive and the sweep starts eating real domains.
    /// Scratch suites belonging to OTHER projects that share this machine's preferences
    /// directory. `pdfutils` is a separate project of the owner's; its test suites leak into the
    /// same place and are tracked separately THERE. A SyncCloud test run quietly deleting them
    /// would be destructive to someone else's investigation of their own leak, and invisible from
    /// this repo. Ownership is not inferable from the shape — only from the prefix — so this list
    /// is the only thing keeping the sweep inside its own house, and it must grow whenever another
    /// project starts sharing the directory.
    private static let foreignSuitePrefixes = ["pdfutils.", "PDFExportCoordinatorTests"]

    static func isScratchSuitePlist(_ name: String) -> Bool {
        guard name.hasSuffix(".plist") else { return false }
        guard !foreignSuitePrefixes.contains(where: name.hasPrefix) else { return false }
        let stem = name.dropLast(".plist".count)
        // A prefix character, a separator, then the 36-character UUID.
        guard stem.count > 37 else { return false }
        let separator = stem[stem.index(stem.endIndex, offsetBy: -37)]
        guard separator == "-" || separator == "." else { return false }
        let groups = stem.suffix(36).split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy { $0.isHexDigit && !$0.isLowercase } }
    }
}

/// A `UserDefaults` on a throwaway suite that cleans itself up — domain *and* plist — once its last
/// reference goes away. Prefer it to a bare `UserDefaults(suiteName:)`: teardown rides on the
/// object's lifetime rather than on a `defer` that a test added later can forget.
final class ScratchDefaults: UserDefaults {
    let scratchSuiteName: String

    /// - Parameter prefix: names the owning test in `~/Library/Preferences` while the suite is
    ///   alive; a fresh UUID is appended so parallel tests never share a domain.
    init(_ prefix: String) {
        self.scratchSuiteName = "\(prefix)-\(UUID().uuidString)"
        super.init(suiteName: scratchSuiteName)!   // a fresh UUID is never a reserved domain name
        scratchDefaultsLedger.record(scratchSuiteName)
    }

    deinit { wipeDefaultsSuite(scratchSuiteName) }
}
