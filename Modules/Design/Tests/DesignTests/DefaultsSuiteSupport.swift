import Foundation

// MARK: - Scratch defaults suites

/// Removes a throwaway defaults suite *and* its backing plist.
///
/// `removePersistentDomain(forName:)`, `removeSuite(named:)` and `CFPreferencesAppSynchronize`
/// all leave an empty `~/Library/Preferences/<suite>.plist` behind, one per UUID-named suite per
/// run, until `defaults domains` takes minutes. Only unlinking the file reclaims it.
///
/// The unlink holds only once cfprefsd lets go of the domain: it keeps its own copy and writes it
/// back on its own schedule (about every 10 s), even after the process exits. So its cache for the
/// suite is flushed first, through the SPI the `defaults` tool calls, looked up rather than linked;
/// an OS without it falls back to the ledger below.
///
/// Mirrored verbatim in every test target, since they are separate SPM packages with no shared
/// test-support module; keep the copies in step.
func wipeDefaultsSuite(_ name: String) {
    // Recorded here, not at the call sites, because every cleanup path (`defer` and
    // `ScratchDefaults.deinit`) goes through this one funnel, including suites built with a plain
    // `UserDefaults(suiteName:)`.
    scratchDefaultsLedger.record(name)
    UserDefaults.standard.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    flushPreferencesCache?(name as CFString, kCFPreferencesCurrentUser)
    let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(atPath: path)
}

/// `_CFPreferencesFlushCachesForIdentifier(domain, user)`; nil on an OS that no longer exports it.
private let flushPreferencesCache =
    dlsym(dlopen(nil, RTLD_NOW), "_CFPreferencesFlushCachesForIdentifier")
        .map { unsafeBitCast($0, to: (@convention(c) (CFString, CFString) -> Void).self) }

/// Finishes the cleanup that the previous test run could not.
///
/// cfprefsd may write a suite's plist back after the test process has exited, a race no sweep
/// inside the process can win (even `atexit`). So every suite handed to `wipeDefaultsSuite` is
/// recorded, and the next run deletes what the last one left, keeping the directory at about one
/// run's stragglers. A run killed before its cleanup records nothing; see
/// `sweepStaleScratchPlists`.
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
            // **The throwing forms only**: `seekToEndOfFile()` and `write(_:)` raise an
            // Objective-C exception on failure, which no Swift `catch` stops, and would take the
            // whole test process down. A lost ledger line costs the next sweep only that name.
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
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

    /// Deletes scratch plists the ledger can't account for, matching by shape rather than name.
    /// A name reaches the ledger only when its test gets to cleanup, so a killed run (a cancelled
    /// CI job, an interrupted `swift test`) leaves suites no later run can name.
    ///
    /// The one-hour age floor makes this safe while other worktrees are testing: their live suites
    /// are minutes old at most. Internal so tests can pin both dangerous edges directly (a stale
    /// scratch plist is deleted, a real lowercase-UUID domain is not); going through `record`'s
    /// once-per-process trigger would make them depend on test order.
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

    /// Scratch suites of other projects sharing this preferences directory, such as the owner's
    /// `pdfutils`, which tracks its own leaks. Only the prefix tells them apart, so this list keeps
    /// the sweep to SyncCloud's own suites; add to it when another project shares the directory.
    private static let foreignSuitePrefixes = ["pdfutils.", "PDFExportCoordinatorTests"]

    /// `<prefix><separator><UUID>.plist`, the UUID in the uppercase form `UUID().uuidString`
    /// emits. `ScratchDefaults` joins with `-`, a few call sites with `.`.
    ///
    /// **Never loosen this to case-insensitive**: real domains that carry a UUID write it lowercase
    /// (`com.openai.chat.RemoteFeatureFlags.164320f2-…`), and the sweep would start deleting them.
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
///
/// The lifetime also outlasts work the test started: a manager whose task is still running holds
/// the suite, so its last write lands before the wipe instead of recreating the plist after it, a
/// race a `defer` loses.
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
