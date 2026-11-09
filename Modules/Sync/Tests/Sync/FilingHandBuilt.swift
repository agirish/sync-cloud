import Foundation
import Testing
@testable import Sync

/// A To File list built by hand, with no folder on disk and no scan (TE335's tests).
///
/// The Refine plan, Undo and Try Another suites are about what the manager does with a list, not
/// about the walk that makes one. Scanning a fixture on disk runs on the main actor, where every
/// `@MainActor` suite queues, and the parking suites' releases queue behind it: a few dozen scans at
/// the start of the package run was enough to turn them red (docs/flaky-tests.md, "Every gate parks
/// at once"). A hand-built list costs microseconds.
enum HandBuiltFiling {

    /// The one manager and the one defaults suite all four hand-built suites use, one at a time: each
    /// costs 0.1 to 2 s to make on the main actor, and four of each at the start of the package run
    /// was part of what pushed the parking suites past their bound.
    @MainActor static let manager = FileSyncManager()
    @MainActor static let defaults = ScratchDefaults("HandBuiltFiling")

    /// How many loose files each fake root was made for, so `build` can be called with the URL alone.
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var byRoot: [String: Int] = [:]
        func set(_ path: String, _ n: Int) { lock.withLock { byRoot[path] = n } }
        func get(_ path: String) -> Int? { lock.withLock { byRoot[path] } }
    }
    private static let counts = Counts()

    /// A source root that exists nowhere, with `files` loose files in its Downloads, remembered.
    static func root(_ name: String, files: Int) -> URL {
        let url = URL(fileURLWithPath: "/HandBuilt-\(name)-\(UUID().uuidString)")
        counts.set(url.path, files)
        return url
    }

    /// The folders the fake source has, as the scan would have cached them.
    static let folders = ["Documents", "Documents/Family", "Archive", "Archive/2026", "Projects", "Projects/Taxes"]

    /// Puts the list on `manager` the way a finished scan leaves it: the files, each with the free
    /// pass's answer (Documents/Family), and the cached source, folders and scan folder.
    @MainActor
    static func build(_ manager: FileSyncManager, root: URL, files: Int? = nil) {
        let n = files ?? (counts.get(root.path) ?? 2)
        let free = FilingDestination(path: root.appendingPathComponent("Documents/Family").path, base: .high,
                                     evidence: .name, reasons: ["free"], newSegments: [])
        manager.filingLastProviderRoot = root.path
        manager.filingLastTaxonomyFolders = folders
        manager.filingLastExistingFolders = Set(folders)
        manager.filingScanFolder = root.appendingPathComponent("Downloads").path
        manager.hasSuggestedFiling = true
        manager.publishFilingSuggestions((0..<n).map { i in
            FilingSuggestion(filePath: root.appendingPathComponent("Downloads/mystery-\(i).pdf").path,
                             fileName: "mystery-\(i).pdf", size: 10,
                             modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                             candidates: [free], providerRoot: root.path)
        })
    }

    /// Whether this suite's manager has been made: `FileSyncManager()` costs 0.1 to 0.7 s on the main
    /// actor, and a few dozen of them at the start of the package run took the parking suites' releases
    /// past their bound. Each of these suites keeps ONE manager, serialized, and resets it per test.
    ///
    /// The defaults too are the suite's one, emptied: a `ScratchDefaults` wipes its domain when it is
    /// released, through cfprefsd and the file system under a process-wide lock, about 0.1 s each, on
    /// the main actor. Two per test, across fifty tests, was most of what these suites cost.
    @MainActor
    static func reset(_ m: FileSyncManager, defaults: ScratchDefaults) {
        if let domain = defaults.persistentDomain(forName: defaults.scratchSuiteName) {
            for key in domain.keys { defaults.removeObject(forKey: key) }
        }
        m.filingContentDefaults = defaults
        m.filingVerdictCacheURL = nil
        m.filingVerdictCache = nil
        m.filingBackendIdentity = nil
        m.filingCloudRefineConfigured = nil
        m.filingClassifier = nil
        m.filingRefineClassifier = nil
        m.filingSnippetExtractor = nil
        m.filingTryAnotherReports = nil
        m.filingCloudSpendConfirmer = { _ in false }
        m.filingRefineShowsBanner = true
        m.filingRefineLeftOutFolders = []
        m.filingRefineUndo = nil
        m.filingLastRefine = nil
        m.filingLastRefineReport = nil
        m.filingOpenRefinePlans = [:]
        m.filingTryAnotherNotes = [:]
        m.filingSessionRejections = [:]
        m.filingNotDownloaded = []
        m.banner = nil
        m.publishFilingSuggestions([])
    }
}

/// The suites built on `HandBuiltFiling`, nested here so they run one after another: `.serialized` on a
/// parent applies to its children, and they share one manager.
@Suite(.serialized) enum HandBuiltRefineSuites {}
