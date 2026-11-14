import Foundation
import Testing
@testable import Sync

/// "Try another" is a paid call and needs the cross-person rule like the scan and the refine:
/// otherwise the model could answer `Immigration/OCI/Son` for a document named for Daughter, on the
/// click most likely to produce that, a re-ask about a file it already got wrong. The rule is one
/// member, `FilingEngine.personVeto`, so no paid path can lack it. These test the rule;
/// `FilingTryAnotherVetoDrivenTests` drives its call sites.
@Suite struct FilingTryAnotherVetoTests {

    static let root = "/root"

    static let household = PersonRegistry(people: [
        Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
    ])

    /// A profile whose person axis says `Immigration/OCI/Son` is Son's.
    static func profile() -> FolderProfile {
        let entries = [
            FolderProfileEntry(path: "Immigration/OCI/Son", role: .destination, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0,
                               axes: ["person": "Son"]),
            FolderProfileEntry(path: "Immigration/OCI/Daughter", role: .destination, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0,
                               axes: ["person": "Daughter"]),
        ]
        return FolderProfile(profileId: "t", root: "~",
                             folders: Dictionary(entries.map { ($0.path, $0) },
                                                 uniquingKeysWith: { a, _ in a }),
                             personTokens: ["daughter", "son"])
    }

    // MARK: The rule

    @Test func aDocumentNamedForOnePersonIsRefusedAnothersFolder() throws {
        let veto = try #require(FilingEngine.personVeto(
            fileName: "Daughter OCI.pdf", destination: "\(Self.root)/Immigration/OCI/Son",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil))
        let reported = try #require(veto.reported, "the refusal carries no report to show the user")
        #expect(reported.namedPerson == "daughter")
        #expect(reported.proposedPerson == "son")
        #expect(reported.destination == "Immigration/OCI/Son")
    }

    /// `Daughter OCI.pdf` into a new folder inside one Son owns is still refused. A profile lists
    /// only folders that exist, so an exact lookup would miss every new-folder destination; the
    /// rule must resolve the owning ancestor. Nothing else catches this: the content-blind guard
    /// doesn't apply to a PDF with text, and the shortlist guard is skipped for new segments.
    @Test func aNewFolderInsideAnothersPersonFolderIsStillRefused() throws {
        // Not a key in the profile; its parent is.
        let destination = "\(Self.root)/Immigration/OCI/Son/Application"
        #expect(Self.profile().folders["Immigration/OCI/Son/Application"] == nil,
                "the fixture stopped exercising a new folder — this test would pass on the old lookup")

        let veto = try #require(FilingEngine.personVeto(
            fileName: "Daughter OCI.pdf", destination: destination,
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil))
        let reported = try #require(veto.reported)
        #expect(reported.namedPerson == "daughter")
        #expect(reported.proposedPerson == "son")
        // Reported as the destination the user was offered, not the ancestor the person came from:
        // the sentence is about where the file was going.
        #expect(reported.destination == "Immigration/OCI/Son/Application")
    }

    /// Depth is not a loophole: several new segments deep still resolves to the owning ancestor.
    @Test func aDeeplyNewPathStillResolvesToTheOwningAncestor() throws {
        let veto = try #require(FilingEngine.personVeto(
            fileName: "Daughter OCI.pdf",
            destination: "\(Self.root)/Immigration/OCI/Son/Application/2026/Scans",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil))
        #expect(veto.reported?.proposedPerson == "son")
    }

    /// The other direction, so the rule doesn't refuse everything. Each row is allowed:
    /// - the nearest owner wins: a new folder under Daughter's is hers, though Son's sits beside it;
    /// - a new folder with no owning ancestor: the rule refuses a contradiction, and there is none;
    /// - the person's own folder, and a folder with no person axis;
    /// - a document naming nobody, which the rule doesn't protect and must not block.
    @Test(arguments: [
        ("Daughter OCI.pdf", "Immigration/OCI/Daughter/Application"),
        ("Daughter OCI.pdf", "Immigration/Passports/New"),
        ("Daughter OCI.pdf", "Immigration/OCI/Daughter"),
        ("Daughter OCI.pdf", "Legal/Immigration"),
        ("Scan 2026-08-02.pdf", "Immigration/OCI/Son"),
    ])
    func aFolderTheRuleHasNoQuarrelWithIsAllowed(fileName: String, destination: String) {
        #expect(FilingEngine.personVeto(
            fileName: fileName, destination: "\(Self.root)/\(destination)",
            providerRoot: Self.root, profile: Self.profile(), registry: Self.household,
            identity: nil, pageSample: nil) == nil)
    }

    /// With no registry the axis falls back to token comparison, which still protects.
    @Test func anUnresolvableAxisKeepsTheTokenProtection() throws {
        let veto = try #require(FilingEngine.personVeto(
            fileName: "Daughter OCI.pdf", destination: "\(Self.root)/Immigration/OCI/Son",
            providerRoot: Self.root, profile: Self.profile(), registry: nil,
            identity: nil, pageSample: nil))
        #expect(veto.reported == nil, "a token-only refusal has no names to report")
    }
}
