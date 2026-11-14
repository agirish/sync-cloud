import Foundation
import Testing
@testable import Sync

/// Phase 2 must not withdraw a person rule. The content pass calls `FilingEngine.suggest` again for
/// the whole loose set and replaces the list, so every argument phase 1 got must be passed again;
/// an omitted one is withdrawn from files already answered. Without `registry` and `identity`,
/// `automationFacts` attributes nobody, so `personIs` reads false, `{person}` is `.unresolved`, and
/// the user's rule silently stops steering. Driven through the real scan, since the risk is at the
/// call site. The document is named by an alias, `Mom - vaccination.pdf`, sharing no token with
/// either folder, so only the registry can connect it to Granny.
@Suite @MainActor struct FilingScanPersonRuleSurvivalTests {

    static let household = PersonRegistry(people: [
        Person(id: "granny", displayName: "Granny", fullNames: ["Granny Elder"], aliases: ["Mom"]),
        Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
    ])

    /// Counts the content extractor's calls, so "the content pass ran" is observed. A suggestion
    /// count only says both files were scanned; if the second file ever got a confident home, phase
    /// 2 would be skipped and these tests would pass vacuously.
    typealias Reads = LockedBox<[String]>


    /// A scan holding two loose files: one the rule answers, one nothing answers. The second leaves
    /// an "unsure" file, which makes phase 2 read contents and re-suggest; without it there is no
    /// second pass to test.
    ///
    /// - Parameter destinationTemplate: the rule's destination, so the same fixture exercises both
    ///   the `personIs` condition and the `{person}` token.
    static func makeScan(destinationTemplate: String,
                         conditions: [AutomationCondition] = [.personIs("granny")],
                         reads: Reads = Reads()) throws -> (FileSyncManager, URL, Reads) {
        let root = try makeCanonicalTempRoot(prefix: "FilingPersonRule")
        try writeBytes(root.appendingPathComponent("Archive/Records/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Archive/Granny/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/Mom - vaccination.pdf"))
        try writeBytes(root.appendingPathComponent("Downloads/9829custbill.pdf"))

        let m = FileSyncManager()
        // Contents-reading on (the default) with an extractor that yields tokens, so phase 2 runs
        // and produces a non-empty `content`, the branch that re-suggests.
        m.filingContentExtractor = { path in reads.record(path); return ["utility", "statement"] }
        m.filingPersonRegistry = household
        // Bypass UserDefaults: otherwise `ensureAutomationRulesLoaded()` replaces these rules with
        // the persisted (empty) set at scan start.
        m.didLoadAutomationRules = true
        m.automationRules = [
            AutomationRule(name: "Mum's paperwork", conditions: conditions,
                           destinationTemplate: destinationTemplate),
        ]
        return (m, root, reads)
    }

    /// The destination the card would act on, relative to the provider root: `best.path` is
    /// absolute and the temp root differs every run.
    static func best(_ m: FileSyncManager, named name: String, root: URL) -> String? {
        guard let s = m.filingSuggestions.first(where: { $0.fileName == name }), let best = s.best
        else { return nil }
        return FilingEngine.relative(best.path, under: root.path)
    }

    /// The rule answers the vaccination record in phase 1; the bill sends the scan into phase 2.
    /// The rule's answer must still be there afterwards.
    @Test func aPersonRuleStillSteersAfterTheContentPassReSuggests() async throws {
        let (m, root, reads) = try Self.makeScan(destinationTemplate: "Archive/Records")
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        // Premise: both files were scanned, and the content pass ran and re-suggested.
        #expect(m.filingSuggestions.count == 2,
                "expected both loose files in the scan, got \(m.filingSuggestions.map(\.fileName))")
        #expect(!reads.paths.isEmpty,
                "the content extractor was never called, so phase 2 did not run")
        let bill = Self.best(m, named: "9829custbill.pdf", root: root)
        #expect(bill != "Archive/Records", "the fixture's homeless file was itself pulled into the rule")

        let record = Self.best(m, named: "Mom - vaccination.pdf", root: root)
        #expect(record == "Archive/Records",
                "the person rule stopped steering once contents were read — best was \(record ?? "nil")")
    }

    /// The `{person}` destination resolves through the same registry, so it must survive too.
    /// `Archive/Granny` is reachable only by resolving the token: the file is named "Mom".
    @Test func aPersonTokenDestinationStillResolvesAfterTheContentPass() async throws {
        let (m, root, reads) = try Self.makeScan(destinationTemplate: "Archive/{person}")
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        #expect(!reads.paths.isEmpty, "phase 2 did not run — this fixture cannot see the defect")
        let record = Self.best(m, named: "Mom - vaccination.pdf", root: root)
        #expect(record == "Archive/Granny",
                "{person} resolved to nothing after the content pass — best was \(record ?? "nil")")
    }

    /// Negative control, so the two above measure attribution rather than "any rule survives": a
    /// rule naming the other person must not claim the file.
    @Test func theRuleStillRefusesTheOtherPersonsDocument() async throws {
        let (m, root, _) = try Self.makeScan(destinationTemplate: "Archive/Records",
                                             conditions: [.personIs("son")])
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        // The suggestion must exist for `!=` to mean anything: `best` returns nil for a file the
        // scan never enumerated, and `nil != "Archive/Records"` is true for the wrong reason.
        #expect(m.filingSuggestions.contains { $0.fileName == "Mom - vaccination.pdf" },
                "the scan enumerated no suggestion for the document under test")
        #expect(Self.best(m, named: "Mom - vaccination.pdf", root: root) != "Archive/Records",
                "a rule about Son claimed Granny's document")
    }
}

private extension LockedBox where Value == [String] {
    func record(_ p: String) { withLock { $0.append(p) } }
}
