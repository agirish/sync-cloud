import Foundation
import Testing
@testable import Sync

/// The verdict cache serves answers the resolver sanitized.
///
/// The staleness check asks whether a verdict still resolves where it did, so it compares against
/// the recorded resolution (`resolvedRelativePath`), not the model's raw string. Those differ for
/// every sanitized answer (a trailing file name stripped, new segments trimmed to an existing
/// parent, an echoed provider root dropped); comparing the raw string would miss every time and pay
/// for the answer again on each refine. `relativePath` stays the served answer, because the entry
/// rebuilds the verdict from it.
@Suite struct FilingVerdictCacheSanitizedPathTests {

    static let root = "/root"
    static let existing: Set<String> = ["Immigration", "Immigration/OCI", "Immigration/OCI/Son"]
    static let now = Date(timeIntervalSince1970: 1_786_000_000)

    /// Force-unwrapped: the initializer fails only for an unknown mtime or size, both literals
    /// here, so a nil is a broken fixture and should trap.
    static func key(_ name: String) -> FilingVerdictKey {
        FilingVerdictKey(filePath: "\(root)/TODO/\(name)", modificationDate: now, size: 1_000,
                         model: "m", promptVersion: 1, excludedRelativePaths: [], artifacts: "a")!
    }

    /// A verdict ending in the document's own name, which the resolver strips, is recorded and then
    /// served.
    @Test func aVerdictWhoseTrailingSegmentIsAFileNameIsServedBack() throws {
        var cache = FilingVerdictCache()
        let k = Self.key("eOCI.pdf")
        let verdict = FilingVerdict(relativePath: "Immigration/OCI/Son/eOCI.pdf", confidence: .high,
                                    reason: "the OCI card", proposesNewFolder: false)

        // The premise: the resolution differs from the raw string, so this answer really is
        // sanitized.
        let resolved = try #require(FilingEngine.destination(from: verdict, providerRoot: Self.root,
                                                             existingRelative: Self.existing))
        let resolvedRelative = FilingEngine.relative(resolved.path, under: Self.root)
        #expect(resolvedRelative != verdict.relativePath,
                "the fixture's path is not sanitized, so it cannot exercise the defect")

        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: Self.existing, now: Self.now)
        let hit = cache.verdict(for: k, providerRoot: Self.root, existingRelative: Self.existing)
        #expect(hit != nil, "a sanitized verdict was recorded and then never servable")
        // And what is served is the answer that was cached, not the trimmed comparand.
        #expect(hit?.relativePath == "Immigration/OCI/Son/eOCI.pdf")
        #expect(hit?.confidence == .high)
    }

    /// The staleness check still works: a verdict recorded while its parent existed, looked up after
    /// the parent is gone, resolves somewhere else and must miss.
    @Test func aVerdictThatNowResolvesElsewhereStillMisses() {
        var cache = FilingVerdictCache()
        let k = Self.key("passport.pdf")
        let verdict = FilingVerdict(relativePath: "Documents/Family/Son", confidence: .high,
                                    reason: "family", proposesNewFolder: false)
        let before: Set<String> = ["Documents", "Documents/Family"]
        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: before, now: Self.now)
        #expect(cache.verdict(for: k, providerRoot: Self.root, existingRelative: before) != nil,
                "the fixture never hit even before the folder was removed")

        // `Family` deleted since: the same verdict now trims to `Documents` — a different folder.
        let after: Set<String> = ["Documents"]
        #expect(cache.verdict(for: k, providerRoot: Self.root, existingRelative: after) == nil,
                "a verdict that now resolves to a different folder was served anyway")
    }

    /// An ordinary verbatim answer round-trips.
    @Test func anUnsanitizedVerdictStillRoundTrips() {
        var cache = FilingVerdictCache()
        let k = Self.key("card.pdf")
        let verdict = FilingVerdict(relativePath: "Immigration/OCI", confidence: .medium,
                                    reason: "oci", proposesNewFolder: false)
        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: Self.existing, now: Self.now)
        #expect(cache.verdict(for: k, providerRoot: Self.root, existingRelative: Self.existing)?.relativePath
                == "Immigration/OCI")
    }

    /// A resolution that got better is still a hit. A verdict for `Documents/Family/Son` recorded
    /// before `Son` existed stores the trimmed `Documents/Family`; once the user creates `Son` the
    /// resolution becomes the model's own answer, which must be served, not re-billed as stale.
    @Test func aVerdictWhoseFolderHasSinceBeenCreatedIsStillServed() throws {
        var cache = FilingVerdictCache()
        let k = Self.key("card.pdf")
        let verdict = FilingVerdict(relativePath: "Documents/Family/Son", confidence: .high,
                                    reason: "family", proposesNewFolder: false)
        let before: Set<String> = ["Documents", "Documents/Family"]
        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: before, now: Self.now)

        // The premise: recorded against a TRIMMED resolution, not the raw answer.
        let recorded = try #require(cache.entries[k]?.resolvedRelativePath)
        #expect(recorded == "Documents/Family", "the fixture did not record a trimmed resolution")

        let after: Set<String> = ["Documents", "Documents/Family", "Documents/Family/Son"]
        #expect(cache.verdict(for: k, providerRoot: Self.root, existingRelative: after)?.relativePath
                == "Documents/Family/Son",
                "the answer improved toward the verdict's own path and was thrown away")
    }

    /// An entry with no `resolvedRelativePath` still decodes and is checked against its raw answer:
    /// neither discarded nor serving a stale answer.
    @Test func aLegacyEntryWithNoRecordedResolutionStillDecodesAndBehaves() throws {
        // Written by hand with no `resolvedRelativePath` key.
        let k = Self.key("card.pdf")
        let keyJSON = try #require(String(data: try JSONEncoder().encode(k), encoding: .utf8))
        let legacy = """
        {"key":\(keyJSON),"relativePath":"Immigration/OCI","confidence":"medium",
        "reason":"oci","newSegmentCount":0,"cachedAt":0,"proposesNewFolder":false}
        """
        let entry = try JSONDecoder().decode(FilingVerdictCacheEntry.self, from: Data(legacy.utf8))
        #expect(entry.resolvedRelativePath == nil, "a legacy entry invented a resolution")
        #expect(entry.verdict.relativePath == "Immigration/OCI")

        let cache = FilingVerdictCache(entries: [k: entry])
        #expect(cache.verdict(for: k, providerRoot: Self.root,
                              existingRelative: Self.existing)?.relativePath == "Immigration/OCI",
                "a legacy entry that used to be servable stopped being servable")
    }
}
