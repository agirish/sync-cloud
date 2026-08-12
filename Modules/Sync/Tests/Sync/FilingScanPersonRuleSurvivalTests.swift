import Foundation
import Testing
@testable import Sync

/// **What phase 2 must not withdraw.**
///
/// The content-reading pass does not patch the homeless entries — it calls `FilingEngine.suggest`
/// again for the whole loose set and replaces the list wholesale. So every argument phase 1 was
/// given has to be given again, and an omitted one is not "unused by the second pass": it is
/// *withdrawn from files the first pass had already answered*.
///
/// `registry`/`identity` were omitted. Without them `automationFacts` attributes nobody, so a
/// `personIs` condition reads false and a `{person}` destination resolves `.unresolved` — the
/// candidate is dropped and the hand-written rule silently stops steering. It needed only one
/// homeless file elsewhere in the scan to fire, with contents-reading on, which is the default.
///
/// These drive the real scan rather than `FilingEngine.suggest` directly, because the defect was
/// in the call site and a test of the engine cannot see a call site.
///
/// **The fixture is built so only attribution can answer.** The first draft filed
/// `Aditi Abhishek - Report.pdf` to `School/Aditi` and passed with the bug reintroduced — ordinary
/// filename-to-folder matching was producing that destination and the rule was never load-bearing.
/// So the document is named by an **alias**: `Mom - vaccination.pdf` shares no token with
/// `Archive/Records` or with `Archive/Muktha`, and the registry is the only thing that connects
/// "Mom" to Muktha. Mutation-checked in both directions.
@Suite @MainActor struct FilingScanPersonRuleSurvivalTests {

    static let household = PersonRegistry(people: [
        Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"], aliases: ["Mom"]),
        Person(id: "divit", displayName: "Divit", fullNames: ["Divit Abhishek"]),
    ])

    static func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A scan holding **two** loose files: one the rule answers, one nothing answers.
    ///
    /// The second is the whole point — it is what leaves the scan with an "unsure" file, which is
    /// what makes phase 2 read contents and re-suggest. With only the answered file there is no
    /// second pass and the bug is invisible, which is how it survived.
    ///
    /// - Parameter destinationTemplate: the rule's destination, so the same fixture exercises both
    ///   the `personIs` condition and the `{person}` token.
    static func makeScan(destinationTemplate: String) throws -> (FileSyncManager, URL) {
        let root = try makeCanonicalTempRoot(prefix: "FilingPersonRule")
        try write(root.appendingPathComponent("Archive/Records/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Archive/Muktha/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Mom - vaccination.pdf"))
        try write(root.appendingPathComponent("Downloads/9829custbill.pdf"))

        let m = FileSyncManager()
        // Contents-reading on (the default) with an extractor that yields tokens, so phase 2 both
        // runs and produces a non-empty `content` — the branch that re-suggests.
        m.filingContentExtractor = { _ in ["utility", "statement"] }
        m.filingPersonRegistry = household
        // Bypass UserDefaults and drive these rules directly — `ensureAutomationRulesLoaded()`
        // otherwise replaces them with the persisted (empty) set at scan start, which is how the
        // first draft of this fixture ended up asserting over a scan with no rules in it at all.
        m.didLoadAutomationRules = true
        m.automationRules = [
            AutomationRule(name: "Mum's paperwork", conditions: [.personIs("muktha")],
                           destinationTemplate: destinationTemplate),
        ]
        return (m, root)
    }

    /// The destination the card would act on, **relative to the provider root** — `best.path` is
    /// absolute and a temp root differs every run, so comparing it whole could only ever be done
    /// against itself.
    static func best(_ m: FileSyncManager, named name: String, root: URL) -> String? {
        guard let s = m.filingSuggestions.first(where: { $0.fileName == name }), let best = s.best
        else { return nil }
        return FilingEngine.relative(best.path, under: root.path)
    }

    /// The vaccination record is answered by the rule in phase 1; the bill sends the scan into
    /// phase 2. The rule's answer has to still be there afterwards.
    @Test func aPersonRuleStillSteersAfterTheContentPassReSuggests() async throws {
        let (m, root) = try Self.makeScan(destinationTemplate: "Archive/Records")
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        // The premise: phase 2 really ran, over both files. Without this the assertion below could
        // pass by the second pass never having happened — a fixture that cannot fail.
        #expect(m.filingSuggestions.count == 2,
                "expected both loose files in the scan, got \(m.filingSuggestions.map(\.fileName))")
        let bill = Self.best(m, named: "9829custbill.pdf", root: root)
        #expect(bill != "Archive/Records", "the fixture's homeless file was itself pulled into the rule")

        let record = Self.best(m, named: "Mom - vaccination.pdf", root: root)
        #expect(record == "Archive/Records",
                "the person rule stopped steering once contents were read — best was \(record ?? "nil")")
    }

    /// The `{person}` destination is the other half: it resolves through the same registry, so it
    /// failed the same way — but as an `.unresolved` path rather than an unmatched condition.
    ///
    /// `Archive/Muktha` is reachable only by resolving the token: the file is named "Mom".
    @Test func aPersonTokenDestinationStillResolvesAfterTheContentPass() async throws {
        let (m, root) = try Self.makeScan(destinationTemplate: "Archive/{person}")
        defer { try? FileManager.default.removeItem(at: root) }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        let record = Self.best(m, named: "Mom - vaccination.pdf", root: root)
        #expect(record == "Archive/Muktha",
                "{person} resolved to nothing after the content pass — best was \(record ?? "nil")")
    }

    /// The negative control, so the two above are known to be measuring attribution rather than
    /// "any rule at all survives": a rule naming the *other* person must not claim the file.
    @Test func theRuleStillRefusesTheOtherPersonsDocument() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingPersonRuleNeg")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(root.appendingPathComponent("Archive/Records/.keep"), bytes: 1)
        try Self.write(root.appendingPathComponent("Downloads/Mom - vaccination.pdf"))
        try Self.write(root.appendingPathComponent("Downloads/9829custbill.pdf"))

        let m = FileSyncManager()
        m.filingContentExtractor = { _ in ["utility", "statement"] }
        m.filingPersonRegistry = Self.household
        m.didLoadAutomationRules = true
        m.automationRules = [
            AutomationRule(name: "Divit's paperwork", conditions: [.personIs("divit")],
                           destinationTemplate: "Archive/Records"),
        ]
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        #expect(Self.best(m, named: "Mom - vaccination.pdf", root: root) != "Archive/Records",
                "a rule about Divit claimed Muktha's document")
    }
}
