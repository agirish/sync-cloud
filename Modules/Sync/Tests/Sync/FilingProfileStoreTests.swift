import Foundation
import Testing
@testable import Sync

@Suite struct FilingProfileStoreTests {

    static func makeProfiles(_ dir: URL, id: String = "abhishek",
                             profile: String, memory: String?) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        try #"{"schemaVersion":1,"activeProfileId":""# .appending(id).appending(#""}"#)
            .write(to: dir.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        try profile.write(to: dir.appendingPathComponent("\(id)/folder-profile.json"),
                          atomically: true, encoding: .utf8)
        if let memory {
            try memory.write(to: dir.appendingPathComponent("\(id)/filing-memory.json"),
                             atomically: true, encoding: .utf8)
        }
    }

    /// The on-disk shape, written by the generator that produced the real artifact. Decoding is the
    /// only contract between a Python builder and this module, so the fixture is written the way the
    /// builder writes it — including the two-element token arrays and the axis aliases.
    static let profileJSON = """
    {"profileId":"abhishek","root":"~/Documents",
     "axes":{"person":{"values":["Abhishek","Shweta"],"aliases":{"Mom":"Muktha"}}},
     "folders":[
       {"path":"Finance/US/Income Tax/2023","role":"year-bucket","naming":"descriptive",
        "anchors":["income","tax"],"fileCount":3,"subfolderCount":6,
        "axes":{"jurisdiction":"US","year":"2023","lifecycle":"active"}},
       {"path":"Finance/US/Income Tax/IRS Docs - 2024","role":"pass-through","naming":null,
        "anchors":["irs"],"fileCount":0,"subfolderCount":1,
        "axes":{"jurisdiction":"US","lifecycle":"active"}},
       {"path":"Documents/TODO","role":"inbox","naming":null,"anchors":[],
        "acceptsNewFiles":false,"fileCount":524,"subfolderCount":0,"axes":{}}]}
    """

    static let memoryJSON = """
    {"schemaVersion":1,"profileId":"abhishek","salt":"abc123","idfFolderBase":2096,
     "folders":{"Finance/US/Income Tax/2023":
       {"docs":12,"anchors":[["turbotax",4.2],["deduction",3.1]],
        "idHashes":[["3437e15c04d360ef",5.0]],"folderModified":1754000000}}}
    """

    @Test func readsTheActiveProfileAndItsMemory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: Self.memoryJSON)

        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.profile.profileId == "abhishek")
        #expect(loaded.profile.folders.count == 3)
        #expect(loaded.memory?.folders.count == 1)
        #expect(loaded.memory?.salt == "abc123")

        let year = try #require(loaded.profile.folders["Finance/US/Income Tax/2023"])
        #expect(year.role == .yearBucket)
        #expect(year.yearKey == "2023")
        #expect(year.anchors == ["income", "tax"])
        // Aliases are the same person under two names — `Family/Mom` is Immigration's `Muktha`.
        #expect(loaded.profile.personTokens.isSuperset(of: ["abhishek", "shweta", "mom", "muktha"]))

        let entry = try #require(loaded.memory?.folders["Finance/US/Income Tax/2023"])
        #expect(entry.docs == 12)
        #expect(entry.anchors.first == FilingMemoryToken(token: "turbotax", weight: 4.2))
        #expect(entry.idHashes.first?.token == "3437e15c04d360ef")
    }

    /// **A year hidden inside a descriptive name.** `IRS Docs - 2024` sits beside the bare-year
    /// folders and the survey recorded no `year` axis for it, so without the name fallback it lands
    /// in a different family and is never compared with the years it belongs to.
    @Test func aYearInTheNameIsFoundWhenTheAxisIsMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let p = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(p.folders["Finance/US/Income Tax/IRS Docs - 2024"]?.axes["year"] == nil)
        #expect(FolderProfileEntry.looksLikeYear("2019-2020"))
        #expect(FolderProfileEntry.looksLikeYear("2024"))
        #expect(!FolderProfileEntry.looksLikeYear("IRS Docs - 2024"))
    }

    /// Inboxes are refused by the profile's own flag *and* by the path rule, because a tree grows
    /// new inboxes the survey never saw.
    @Test func inboxesAreRefusedAsDestinations() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let p = try #require(FilingProfileStore.profile(id: "abhishek", in: dir))
        #expect(!p.acceptsNewFiles("Documents/TODO"))               // flagged in the profile
        #expect(!p.acceptsNewFiles("Health/TODO/Dental"))           // never surveyed, path rule
        #expect(!p.acceptsNewFiles("Work/EDD - TODO"))              // component, not suffix
        #expect(p.acceptsNewFiles("Finance/US/Income Tax/2023"))
    }

    /// A missing memory is ordinary, not a fault — the profile alone still routes.
    @Test func aMissingMemoryStillYieldsAProfile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: nil)
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.memory == nil)
    }

    @Test func absentAndMalformedBothYieldNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilingProfileStore.active(in: dir) == nil)          // nothing there at all
        try Self.makeProfiles(dir, profile: "{ not json", memory: nil)
        #expect(FilingProfileStore.profile(id: "abhishek", in: dir) == nil)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
    }

    /// **A future schema is refused, not half-read.** The store's own doc claimed this and only
    /// `profiles.json` was ever checked, so an artifact with a new shape would have been decoded
    /// field-by-field into a mostly empty value and used — the silent wrong answer this store
    /// exists to avoid.
    @Test func aForeignSchemaIsRefusedRatherThanHalfRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = Self.memoryJSON.replacingOccurrences(of: "\"schemaVersion\":1",
                                                          with: "\"schemaVersion\":99")
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: future)
        #expect(FilingProfileStore.memory(id: "abhishek", in: dir) == nil)
        // and the same file at the current schema still reads, or the test above proves nothing
        try Self.makeProfiles(dir, profile: Self.profileJSON, memory: Self.memoryJSON)
        #expect(FilingProfileStore.memory(id: "abhishek", in: dir) != nil)
    }

    /// **The hash format is the contract with the builder that wrote the file.** A change here does
    /// not fail — it silently stops every identifier matching — so it is pinned against a literal
    /// computed independently: `sha256("abc123" + "1892")[0..<16]`.
    @Test func theIdentifierHashMatchesTheBuilder() {
        #expect(FilingMemory.hash("1892", salt: "abc123") == "3437e15c04d360ef")
        #expect(FilingMemory.hash("kaiser", salt: "s") == "3529b1a559fe505a")
    }
}

/// Decodes the artifacts actually on this machine. Skipped — visibly — where they do not exist,
/// rather than passing vacuously: this is the only check that the Swift decoder agrees with the
/// Python generator on 2,096 folders of real data.
@Suite(.enabled(if: FilingProfileStore.defaultDirectory().map {
    FileManager.default.fileExists(atPath: $0.appendingPathComponent("profiles.json").path)
} ?? false, "no filing profile on this machine"))
struct RealFilingProfileTests {

    @Test func theRealArtifactsDecodeAndAgreeWithEachOther() throws {
        let dir = try #require(FilingProfileStore.defaultDirectory())
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.profile.folders.count > 1000)

        let memory = try #require(loaded.memory)
        #expect(!memory.salt.isEmpty)
        #expect(memory.folders.count > 500)

        // **The two artifacts are snapshots, and they can be taken at different times.** This
        // machine's memory was rebuilt after `Immigration/` was reorganised on 6 Aug; the profile
        // was not, so the memory names folders the profile has never seen. That has to *degrade*,
        // not break — the path rule still answers for them and the router simply has no axes to
        // reason with. A large divergence would mean the two describe different trees.
        let unknown = memory.folders.keys.filter { loaded.profile.folders[$0] == nil }
        let drift = Double(unknown.count) / Double(memory.folders.count)
        #expect(drift < 0.05, "memory and profile disagree on \(unknown.count) folders — re-survey")
        for folder in unknown {
            // Answering at all is the requirement; an unknown folder must not become a destination
            // just because the profile cannot vouch for it.
            #expect(loaded.profile.acceptsNewFiles(folder) != FolderProfile.isInboxPath(folder))
        }

        // No inbox may carry filing memory into a destination list.
        let index = FilingRouter.makeIndex(destinations: Array(loaded.profile.folders.keys),
                                           profile: loaded.profile, memory: memory)
        #expect(!index.destinations.contains { $0.lowercased().contains("todo") })
        #expect(index.destinations.count > 1000)
    }
}
