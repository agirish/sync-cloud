import Testing
import Foundation
@testable import Sync

/// File Into is a preference, not a fence. With File Into a subfolder of the surveyed tree
/// (`~/Documents/Finance/US` inside `~/Documents`), the survey used to be off: its keys are relative
/// to `~/Documents`, the scan's destinations to File Into, and 1 of 912 folders matched. The scan
/// now walks the surveyed tree, keeps rules on File Into, and lets only File Into's homes into the
/// unseen batch.
@MainActor
@Suite struct FilingRoutingRootTests {

    private struct Tree {
        let root: URL
        var documents: URL { root.appendingPathComponent("Documents") }
        var fileInto: URL { documents.appendingPathComponent("Finance/US") }
        var inbox: URL { documents.appendingPathComponent("TODO") }
    }

    private func makeTree(_ prefix: String) throws -> Tree {
        let t = Tree(root: try makeCanonicalTempRoot(prefix: prefix))
        try writeFilingFile(t.fileInto.appendingPathComponent("Bank Accounts/Bank of America/Checking 5696/2025/eStmt_2025-12-28.pdf"), bytes: 64)
        try writeFilingFile(t.documents.appendingPathComponent("Vehicles/Tesla/Insurance/Policy 2025.pdf"), bytes: 64)
        // The inbox's own folders name the account; it must never be a home for its own files.
        try writeFilingFile(t.inbox.appendingPathComponent("Tesla Insurance Policy 2026.pdf"), bytes: 64)
        try writeFilingFile(t.inbox.appendingPathComponent("Vehicles/Tesla/Insurance/stray.pdf"), bytes: 64)
        return t
    }

    private func manager(surveying t: Tree) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingFolderProfile = FolderProfile(profileId: "p", root: t.documents.path, folders: [:], personTokens: [])
        return m
    }

    @Test func fileIntoInsideTheSurveyWalksTheWholeSurveyedTree() async throws {
        let t = try makeTree("FilingRootWalk")
        defer { try? FileManager.default.removeItem(at: t.root) }
        let m = manager(surveying: t)
        #expect(m.filingRoutingRoot(forFileInto: t.fileInto).path == t.documents.path)
        #expect(m.filingRoutingRoot(forFileInto: t.root.appendingPathComponent("Elsewhere")).lastPathComponent == "Elsewhere",
                "outside the survey, File Into is the walk, as before")

        m.setFilingScansSubfolders(false, for: t.inbox.path)
        await m.findFilingSuggestions(folder: t.inbox, providerRoot: t.fileInto)
        let card = try #require(m.filingSuggestions.first { $0.fileName == "Tesla Insurance Policy 2026.pdf" })
        let paths = card.candidates.map(\.path)
        #expect(paths.contains { $0.hasPrefix(t.documents.path + "/Vehicles/Tesla") },
                "a home outside File Into is reachable now: \(paths)")
        #expect(!paths.contains { $0.hasPrefix(t.inbox.path) }, "the inbox is never a home for its own files: \(paths)")
        #expect(m.filingLastProviderRoot == t.documents.path)
    }

    @Test func onlyHomesInsideFileIntoJoinTheUnseenBatch() async throws {
        let t = try makeTree("FilingRootBatch")
        defer { try? FileManager.default.removeItem(at: t.root) }
        let m = manager(surveying: t)
        await m.findFilingSuggestions(folder: t.inbox, providerRoot: t.fileInto)
        let card = try #require(m.filingSuggestions.first { $0.fileName == "Tesla Insurance Policy 2026.pdf" })
        let best = try #require(card.best)
        #expect(best.path.hasPrefix(t.documents.path + "/Vehicles"), "\(best.path)")
        #expect(!card.isBatchEligible, "a name-derived High outside File Into needs a click")
        // Control: the same card scanned against File Into itself would be eligible when High.
        let plain = card.replacingCandidates(card.candidates)
        #expect(plain.preferredRoot == t.fileInto.path, "rebuilding a card keeps File Into")
        if best.confidence == .high, !best.fromContent, !best.fromAI {
            var unfenced = card
            unfenced.preferredRoot = nil
            #expect(unfenced.isBatchEligible, "the narrowing, not something else, kept it out")
        }
    }

    @Test func rulesStayScopedToAndResolvedAgainstFileInto() throws {
        let t = try makeTree("FilingRootRules")
        defer { try? FileManager.default.removeItem(at: t.root) }
        let m = manager(surveying: t)
        let rule = AutomationRule(name: "Policies", conditions: [.nameMatches("*Policy*")],
                                  destinationTemplate: "Insurance/{year}")
        let taught = AutomationRule(name: "Taught in Ask Claude", conditions: [.nameMatches("*Policy*")],
                                    destinationTemplate: "Vehicles/Tesla/Insurance", surveyRoot: t.documents.path)
        let elsewhere = AutomationRule(name: "Another tree", conditions: [.nameMatches("*Policy*")],
                                       destinationTemplate: "Nope", surveyRoot: t.root.appendingPathComponent("Dropbox").path)
        let rules = [rule, taught, elsewhere]
        let s = FilingEngine.suggest(looseFiles: [FileNode(id: t.inbox.path + "/Tesla Insurance Policy 2026.pdf",
                                                           name: "Tesla Insurance Policy 2026.pdf", isDirectory: false,
                                                           fileSize: 8192)],
                                     learned: FilingEngine.LearnedTaxonomy(profiles: [], existingPaths: [t.documents.path]),
                                     providerRoot: t.documents.path, automations: rules,
                                     ruleRoot: t.fileInto.path)
        let remembered = (s.first?.candidates ?? []).filter(\.remembered).map(\.path)
        #expect(remembered.contains(t.fileInto.path + "/Insurance/2026"),
                "a File Into rule resolves under File Into, not the walked root: \(remembered)")
        #expect(remembered.contains(t.documents.path + "/Vehicles/Tesla/Insurance"),
                "a rule taught against the survey root resolves there: \(remembered)")
        #expect(!remembered.contains { $0.hasSuffix("/Nope") }, "a rule from another tree stays inert")
        _ = m
    }

    @Test func pruningDropsOnlyTheNamedSubtree() {
        func d(_ p: String, _ c: [FileNode] = []) -> FileNode {
            FileNode(id: p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c)
        }
        let tree = [d("/r/A", [d("/r/A/TODO", [d("/r/A/TODO/x")]), d("/r/A/TODOS")]), d("/r/B")]
        let pruned = FileSyncManager.pruning("/r/A/TODO", from: tree)
        #expect(pruned.map(\.id) == ["/r/A", "/r/B"])
        #expect(pruned[0].children?.map(\.id) == ["/r/A/TODOS"], "a sibling sharing the prefix stays")
    }

    @Test func verdictKeysCarryTheWalkedRootOnlyWhenItIsWider() {
        let m = FileSyncManager()
        #expect(m.filingVerdictArtifacts("abc") == "abc", "an ordinary scan keeps its cached answers")
        m.filingRoutedRoot = "/Users/x/Documents"
        #expect(m.filingVerdictArtifacts("abc") == "abc|root=/Users/x/Documents")
    }

    /// A scan of File Into itself (or of the survey root) keeps every home: the scanned folder is
    /// the destination tree, not a source to keep homes out of.
    @Test func scanningFileIntoItselfKeepsItsHomes() async throws {
        let t = try makeTree("FilingRootSelf")
        defer { try? FileManager.default.removeItem(at: t.root) }
        try writeFilingFile(t.fileInto.appendingPathComponent("Checking statement 5696 2026.pdf"), bytes: 64)
        let m = manager(surveying: t)
        await m.findFilingSuggestions(folder: t.fileInto, providerRoot: t.fileInto)
        let card = try #require(m.filingSuggestions.first { $0.fileName == "Checking statement 5696 2026.pdf" })
        #expect(!card.candidates.isEmpty, "the homes inside File Into stay offered")
    }

    @Test func fileIntoReachedThroughALinkIsSpelledLikeTheSurvey() throws {
        let t = try makeTree("FilingRootLink")
        defer { try? FileManager.default.removeItem(at: t.root) }
        let link = t.root.appendingPathComponent("CloudDocs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.documents)
        let m = manager(surveying: t)
        let routing = m.filingRouting(forFileInto: link.appendingPathComponent("Finance/US"))
        #expect(routing.root.path == t.documents.path)
        #expect(routing.fileInto.path == t.fileInto.path, "File Into in the survey's spelling: \(routing.fileInto.path)")
        let same = m.filingRouting(forFileInto: link)
        #expect(same.root.path == same.fileInto.path, "the survey root through a link is not a wider walk")
    }

    @Test func aRuleOfferedAfterFilingIsRelativeToFileIntoOrAbsolute() {
        let m = FileSyncManager()
        m.filingLastFileInto = "/D/Finance/US"
        m.filingRoutedRoot = "/D"
        #expect(m.ruleDestination(forFiledFolder: "/D/Finance/US/Schwab/2026", scannedRoot: "/D") == "Schwab/2026")
        #expect(m.ruleDestination(forFiledFolder: "/D/Vehicles/Tesla", scannedRoot: "/D") == "/D/Vehicles/Tesla",
                "outside File Into the rule names the folder itself, never a path the next scan re-roots")
    }

    @Test func theModelsFolderMenuLeadsWithFileInto() {
        let all: Set<String> = ["A", "B", "Finance", "Finance/US", "Finance/US/Bank", "Finance/US/Bank/Checking 5696"]
        let menu = FileSyncManager.preferringSubtree("Finance/US", in: ["A", "B", "Finance"], all: all)
        #expect(menu == ["Finance/US", "Finance/US/Bank", "Finance/US/Bank/Checking 5696"], "\(menu)")
    }
}
