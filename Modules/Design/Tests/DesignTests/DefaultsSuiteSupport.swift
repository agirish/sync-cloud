import Foundation

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
