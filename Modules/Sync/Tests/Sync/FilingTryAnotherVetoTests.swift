import Foundation
import Testing
@testable import Sync

/// **"Try another" is a paid call, and it was the one paid path with no guards at all.**
///
/// The scan and the refine both run their verdicts through `FilingEngine.applyVerdicts`, where the
/// cross-person rule lives. A re-ask resolved its verdict straight through `destination(from:)` and
/// put the result on the card — so the model could answer `Immigration/OCI/Divit` for a document
/// named for Aditi and nothing would stop it. That is the error the rule was written for, on the
/// click most likely to produce it: the user is asking the model to think again about a file it has
/// already been wrong about once.
///
/// The rule is a named member now (`FilingEngine.personVeto`) so it cannot be present on one path
/// and absent on the next. These test the rule directly and pin both call sites.
@Suite struct FilingTryAnotherVetoTests {

    static let root = "/root"

    static let household = PersonRegistry(people: [
        Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
        Person(id: "divit", displayName: "Divit", fullNames: ["Divit Abhishek"]),
    ])

    /// A profile whose person axis says `Immigration/OCI/Divit` is Divit's.
    static func profile() -> FolderProfile {
        let entries = [
            FolderProfileEntry(path: "Immigration/OCI/Divit", role: .destination, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0,
                               axes: ["person": "Divit"]),
            FolderProfileEntry(path: "Immigration/OCI/Aditi", role: .destination, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0,
                               axes: ["person": "Aditi"]),
        ]
        return FolderProfile(profileId: "t", root: "~",
                             folders: Dictionary(entries.map { ($0.path, $0) },
                                                 uniquingKeysWith: { a, _ in a }),
                             personTokens: ["aditi", "divit"])
    }

    // MARK: The rule

    @Test func aDocumentNamedForOnePersonIsRefusedAnothersFolder() throws {
        let veto = try #require(FilingEngine.personVeto(
            fileName: "Aditi OCI.pdf", destination: "\(Self.root)/Immigration/OCI/Divit",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil))
        let reported = try #require(veto.reported, "the refusal carries no report to show the user")
        #expect(reported.namedPerson == "aditi")
        #expect(reported.proposedPerson == "divit")
        #expect(reported.destination == "Immigration/OCI/Divit")
    }

    /// The other direction, so the rule is not simply refusing everything: the person's OWN folder
    /// is allowed, and so is a folder with no person axis at all.
    @Test func theRightPersonsFolderAndAnUnownedFolderAreAllowed() {
        #expect(FilingEngine.personVeto(
            fileName: "Aditi OCI.pdf", destination: "\(Self.root)/Immigration/OCI/Aditi",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil) == nil)
        #expect(FilingEngine.personVeto(
            fileName: "Aditi OCI.pdf", destination: "\(Self.root)/Legal/Immigration",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil) == nil)
    }

    /// A document naming nobody is not protected by this rule and must not be blocked by it.
    @Test func aDocumentNamingNobodyIsNotRefused() {
        #expect(FilingEngine.personVeto(
            fileName: "Scan 2026-08-02.pdf", destination: "\(Self.root)/Immigration/OCI/Divit",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil) == nil)
    }

    /// With no registry the axis falls back to token comparison, which still protects.
    @Test func anUnresolvableAxisKeepsTheTokenProtection() throws {
        let veto = try #require(FilingEngine.personVeto(
            fileName: "Aditi OCI.pdf", destination: "\(Self.root)/Immigration/OCI/Divit",
            providerRoot: Self.root, profile: Self.profile(), registry: nil,
            identity: nil, pageSample: nil))
        #expect(veto.reported == nil, "a token-only refusal has no names to report")
    }

    // MARK: Both paid paths ask it

    /// The call sites, because a rule extracted for sharing is one revert from being unused — and
    /// this one was already unused on a path that could spend money.
    @Test func bothPaidPathsRunTheirVerdictThroughTheVeto() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync")
        for file in ["FilingEngine.swift", "FileSyncManager+Filing.swift"] {
            let source = try #require(try? String(contentsOf: dir.appendingPathComponent(file),
                                                  encoding: .utf8),
                                      "cannot read \(file) — this scan would be vacuous")
            try #require(source.count > 500, "\(file) is implausibly short")
            #expect(source.contains("personVeto("),
                    "\(file) resolves a backend verdict without the cross-person rule")
        }
        // And the refine reaches it through `applyVerdicts`, which is where its own guards live.
        let refine = try #require(try? String(contentsOf: dir.appendingPathComponent("FileSyncManager+FilingRefine.swift"),
                                              encoding: .utf8))
        #expect(refine.contains("FilingEngine.applyVerdicts("),
                "the refine no longer runs its verdicts through the guards")
    }
}
