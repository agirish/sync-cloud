import Foundation
import Testing
@testable import Sync

/// **The class of answers the cache could never serve.**
///
/// The staleness test asks "does this verdict still resolve where it resolved before?" — but it
/// compared the resolution against the model's **raw** string. Those differ by design for every
/// answer the resolver sanitizes: a trailing file name is stripped, undeclared new segments are
/// trimmed to their existing parent, an echoed provider root is dropped. For all of those the
/// comparison failed on the very first lookup, with nothing changed and nothing wrong, so the
/// answer could never be served and was paid for again on every refine — in exactly the case the
/// sanitizer exists for, which `FilingEngine.destination`'s own notes say happens often.
///
/// `resolvedRelativePath` is the comparand now. `relativePath` stays the served answer, because
/// the entry reconstructs the verdict from it.
@Suite struct FilingVerdictCacheSanitizedPathTests {

    static let root = "/root"
    static let existing: Set<String> = ["Immigration", "Immigration/OCI", "Immigration/OCI/Divit"]
    static let now = Date(timeIntervalSince1970: 1_786_000_000)

    static func key(_ name: String) -> FilingVerdictKey {
        FilingVerdictKey(filePath: "\(root)/TODO/\(name)", modificationDate: now, size: 1_000,
                         model: "m", promptVersion: 1, excludedRelativePaths: [], artifacts: "a")
    }

    /// The headline: a verdict naming the document itself at the end of the path — the shape the
    /// resolver strips — is recorded and then served.
    @Test func aVerdictWhoseTrailingSegmentIsAFileNameIsServedBack() throws {
        var cache = FilingVerdictCache()
        let k = Self.key("eOCI.pdf")
        let verdict = FilingVerdict(relativePath: "Immigration/OCI/Divit/eOCI.pdf", confidence: .high,
                                    reason: "the OCI card", proposesNewFolder: false)

        // The premise: this really is a sanitized answer — the resolution differs from the raw
        // string. Without this the test could pass on a path that needed no sanitizing at all.
        let resolved = try #require(FilingEngine.destination(from: verdict, providerRoot: Self.root,
                                                             existingRelative: Self.existing))
        let resolvedRelative = FilingEngine.relative(resolved.path, under: Self.root)
        #expect(resolvedRelative != verdict.relativePath,
                "the fixture's path is not sanitized, so it cannot exercise the defect")

        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: Self.existing, now: Self.now)
        let hit = cache.verdict(for: k, providerRoot: Self.root, existingRelative: Self.existing)
        #expect(hit != nil, "a sanitized verdict was recorded and then never servable")
        // And what is served is the answer that was cached, not the trimmed comparand.
        #expect(hit?.relativePath == "Immigration/OCI/Divit/eOCI.pdf")
        #expect(hit?.confidence == .high)
    }

    /// The guard still guards. A verdict recorded when its parent existed, looked up after that
    /// parent is gone, resolves somewhere else and must miss — this is the case the path check was
    /// added for, and it has to survive the fix.
    @Test func aVerdictThatNowResolvesElsewhereStillMisses() {
        var cache = FilingVerdictCache()
        let k = Self.key("passport.pdf")
        let verdict = FilingVerdict(relativePath: "Documents/Family/Divit", confidence: .high,
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

    /// An ordinary verbatim answer is unaffected — the common path keeps working.
    @Test func anUnsanitizedVerdictStillRoundTrips() {
        var cache = FilingVerdictCache()
        let k = Self.key("card.pdf")
        let verdict = FilingVerdict(relativePath: "Immigration/OCI", confidence: .medium,
                                    reason: "oci", proposesNewFolder: false)
        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: Self.existing, now: Self.now)
        #expect(cache.verdict(for: k, providerRoot: Self.root, existingRelative: Self.existing)?.relativePath
                == "Immigration/OCI")
    }

    /// **A resolution that got BETTER is still a hit.** A verdict for `Documents/Family/Divit`
    /// recorded while `Divit` did not exist is stored with the trimmed resolution
    /// `Documents/Family`; when the user then creates `Divit`, the resolution becomes the model's
    /// own answer. Comparing only against the recorded resolution called that stale and re-billed
    /// it — the exact inverse of what this type promises ("the answer got better, not worse"), and
    /// a direction the first version of the comparand fix silently reversed.
    @Test func aVerdictWhoseFolderHasSinceBeenCreatedIsStillServed() throws {
        var cache = FilingVerdictCache()
        let k = Self.key("card.pdf")
        let verdict = FilingVerdict(relativePath: "Documents/Family/Divit", confidence: .high,
                                    reason: "family", proposesNewFolder: false)
        let before: Set<String> = ["Documents", "Documents/Family"]
        cache.record(verdict, for: k, providerRoot: Self.root, existingRelative: before, now: Self.now)

        // The premise: recorded against a TRIMMED resolution, not the raw answer.
        let recorded = try #require(cache.entries[k]?.resolvedRelativePath)
        #expect(recorded == "Documents/Family", "the fixture did not record a trimmed resolution")

        let after: Set<String> = ["Documents", "Documents/Family", "Documents/Family/Divit"]
        #expect(cache.verdict(for: k, providerRoot: Self.root, existingRelative: after)?.relativePath
                == "Documents/Family/Divit",
                "the answer improved toward the verdict's own path and was thrown away")
    }

    /// **Entries written before the field existed still work**, on the comparand they were written
    /// with. Decoding a legacy record must not discard it, and must not start serving a stale
    /// answer either — it behaves exactly as it did.
    @Test func aLegacyEntryWithNoRecordedResolutionStillDecodesAndBehaves() throws {
        // Written by hand in the OLD shape — no `resolvedRelativePath` key at all.
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
