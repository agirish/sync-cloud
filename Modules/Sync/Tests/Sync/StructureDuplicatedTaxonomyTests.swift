import Foundation
import Testing
@testable import Sync

/// The duplicated-taxonomy rule (ROADMAP v5 §5.9): two folders are duplicated taxonomy when a
/// material share of their contents are `.sameText` partners, never merely when their child names
/// agree, which on a real tree is usually a sign of health.
@Suite struct StructureDuplicatedTaxonomyTests {

    private static let root = "/tree"

    private static func profile(_ counts: [String: Int]) -> FolderProfile {
        FolderProfile(profileId: "p", root: root,
                      folders: counts.mapValues2 { path, files in
                          FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                             acceptsNewFiles: nil, fileCount: files,
                                             subfolderCount: 0, axes: [:])
                      },
                      personTokens: [])
    }

    private static func sameTextGroup(_ paths: [String],
                                      matchType: DuplicateMatchType = .sameText)
        -> DuplicateGroup {
        DuplicateGroup(matchType: matchType, name: (paths[0] as NSString).lastPathComponent,
                       isDirectory: false,
                       copies: paths.map {
                           DuplicateCopy(id: root + "/" + $0,
                                         name: ($0 as NSString).lastPathComponent,
                                         isDirectory: false, size: 10, itemCount: 1,
                                         modificationDate: nil, uniqueItemCount: 0,
                                         depth: $0.split(separator: "/").count,
                                         isRecommendedKeeper: false)
                       },
                       reclaimableBytes: 0)
    }

    /// Three same-text pairs spanning two branches, and the smaller folder's share clears the bar:
    /// one finding, with counterpart and count on the detail.
    @Test func threeSharedDocumentsAcrossTwoBranchesFire() {
        let profile = Self.profile(["Work/Acme/Forms": 4, "Finance/Tax/2016/Forms": 6])
        let groups = ["1095-C.pdf", "W-2.pdf", "1040.pdf"].map { name in
            Self.sameTextGroup(["Work/Acme/Forms/\(name)", "Finance/Tax/2016/Forms/\(name)"])
        }
        let findings = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile)
        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.kind == .duplicatedTaxonomy)
        #expect(finding.subject == "Finance/Tax/2016/Forms",
                "subject is the lexicographically first of the pair — a stable identity")
        #expect(finding.detail == .duplicatedTaxonomy(counterpart: "Work/Acme/Forms",
                                                      matchedDocuments: 3))
        #expect(finding.id == "duplicatedTaxonomy|Finance/Tax/2016/Forms")
    }

    /// The silences, each for its own reason: too few shared documents (a stray copy is the
    /// Duplicates lens's business), a share below the bar (a large archive absorbs a few files from
    /// everywhere), a match that isn't `.sameText` (names are not evidence here), and a stash the
    /// profile never recorded (the claim is about two organised branches).
    @Test func theSilencesHoldOneByOne() {
        let profile = Self.profile(["A/Forms": 4, "B/Forms": 40, "C/Forms": 4])

        // Two shared documents: below the floor.
        let two = ["x.pdf", "y.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "C/Forms/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: two, in: profile).isEmpty)

        // Three shared between two forty-file folders: the share is taken on the smaller side, and
        // 3/40 is below the bar.
        let bigProfile = Self.profile(["A/Forms": 40, "B/Forms": 40])
        let three = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "B/Forms/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: three, in: bigProfile).isEmpty,
                "three shared files between two forty-file folders is not a taxonomy claim")

        // A match that isn't `.sameText` is not evidence: the claim is about documents that read
        // alike, and an identical-bytes pair is a different finding. Every other fixture here uses
        // `.sameText`, so without this control the guard's kind test could go unnoticed.
        let identical = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "C/Forms/\($0)"], matchType: .identical)
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: identical, in: profile).isEmpty)

        // A folder the profile never recorded (a downloads stash) takes no part.
        let stash = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "Downloads/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: stash, in: profile).isEmpty)
    }

    /// Ancestor and descendant are one branch, not two taxonomies: a stash inside its own archive
    /// is the Duplicates lens's ordinary case.
    @Test func anAncestorDescendantPairIsNotATaxonomyClaim() {
        let profile = Self.profile(["A/Forms": 4, "A/Forms/Old": 4])
        let groups = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "A/Forms/Old/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: profile).isEmpty)
    }

    /// One folder pairing with two counterparts must not make two findings under one id: the
    /// identity downstream keys on is `kind × subject`. Each pair takes whichever of its folders is
    /// still free; both are real paths, so reveal and suppression keep working.
    @Test func aFolderPairedWithTwoCounterpartsKeepsUniqueIds() {
        let profile = Self.profile(["Archive/Forms": 6, "Work/Acme/Forms": 4,
                                    "Finance/Tax/Forms": 4])
        var groups: [DuplicateGroup] = []
        for name in ["a.pdf", "b.pdf", "c.pdf"] {
            groups.append(Self.sameTextGroup(["Archive/Forms/\(name)",
                                              "Work/Acme/Forms/\(name)"]))
            groups.append(Self.sameTextGroup(["Archive/Forms/x-\(name)",
                                              "Finance/Tax/Forms/x-\(name)"]))
        }
        let findings = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile)
        #expect(findings.count == 2)
        #expect(Set(findings.map(\.id)).count == 2, "two findings, two ids")
        let subjects = Set(findings.map(\.subject))
        #expect(subjects.contains("Archive/Forms"))
        #expect(subjects.count == 2, "the second pair took its OTHER folder as subject")
        for finding in findings {
            #expect(profile.folders[finding.subject] != nil, "every subject is a real folder")
        }
    }

    /// The pair key is a real pair, not a joined string: `|` is legal in a folder name, and a
    /// joined key would merge counts across pairs that concatenate alike.
    @Test func aPipeInAFolderNameDoesNotMergePairs(){
        let profile = Self.profile(["A": 4, "B|C": 4, "A|B": 4, "C": 4])
        // Two distinct pairs whose joined spellings would collide: (A, B|C) and (A|B, C).
        var groups: [DuplicateGroup] = []
        for name in ["a.pdf", "b.pdf"] {
            groups.append(Self.sameTextGroup(["A/\(name)", "B|C/\(name)"]))
        }
        groups.append(Self.sameTextGroup(["A|B/z.pdf", "C/z.pdf"]))
        // Neither pair reaches three matches, so correct keying yields no findings; a joined-string
        // key would sum 2 + 1 into one phantom pair of three.
        #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: profile).isEmpty)
    }

    // MARK: The shapes the reference tree actually holds (proposal O18)

    /// Three shapes the reference tree holds, two of which the rule gets wrong. The rule's yield is
    /// unmeasured (a scan of the live tree needs Full Disk Access), but these shapes
    /// can be read from the persisted content-fingerprint index, and they are what the rule's next
    /// design has to handle. None is a count claim: each is a real structure in its smallest form,
    /// with the rule's current verdict recorded, right or wrong.
    ///
    /// 1. Combined statements in two account folders. A bank issues one PDF covering checking and
    /// savings, correctly filed under both. The rule sees the smaller side wholly shared and fires,
    /// but these are two correct branches sharing a document that belongs to both: the content
    /// version of the name-parallel trap the rule was written to avoid.
    @Test func combinedStatementsInTwoAccountFoldersFireAndShouldNot() {
        let profile = Self.profile(["Bank/Checking 5670/2017": 12, "Bank/Savings 3931/2017": 12])
        let groups = (1...12).map { month in
            Self.sameTextGroup(["Bank/Checking 5670/2017/statement-\(month).pdf",
                                "Bank/Savings 3931/2017/statement-\(month).pdf"])
        }
        let findings = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile)
        #expect(findings.count == 1,
                "the rule as it stands fires here — recorded, not endorsed")
        #expect(findings.first?.detail
                == .duplicatedTaxonomy(counterpart: "Bank/Savings 3931/2017",
                                       matchedDocuments: 12))
        // The share threshold is not the discriminator: this pair clears every value from a fifth
        // to the whole folder, so no tuning of `minimumShare` separates it from a real duplicated
        // taxonomy. Fixing it needs a different rule.
        for share in [0.2, 1.0 / 3.0, 0.5, 1.0] {
            #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: profile,
                                                          minimumShare: share).count == 1,
                    "a false positive that survives every threshold is not a threshold problem")
        }
    }

    /// 2. An inbox staging folder: documents sit in `TODO` and also where they were filed. The rule
    /// fires, but this is one folder mid-filing, and the pair dissolves once the staging copies
    /// are cleared.
    @Test func anInboxStagingFolderFiresWhileItIsStillBeingFiled() {
        let profile = Self.profile(["Cards/Credit 2809/2024": 13, "Cards/TODO": 13])
        let groups = (1...10).map { index in
            Self.sameTextGroup(["Cards/Credit 2809/2024/doc-\(index).pdf",
                                "Cards/TODO/doc-\(index).pdf"])
        }
        let findings = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile)
        #expect(findings.count == 1, "recorded as the rule's current behaviour")
        // The subject is the lexicographically first of the pair, a stable identity, pinned exactly
        // rather than either way by an `||`, which would leave the counterpart and count unchecked.
        #expect(findings.first?.subject == "Cards/Credit 2809/2024")
        #expect(findings.first?.detail
                == .duplicatedTaxonomy(counterpart: "Cards/TODO", matchedDocuments: 10))
    }

    /// 3. A petition packet: pay statements copied from `Work/…/Salary Statements` into an
    /// immigration petition's supporting documents, the whole of the smaller folder. The closest
    /// real case to the rule: the same documents under two genuinely different taxonomies. It is
    /// also arguably correct filing, which is why the card reports rather than acts, and why its
    /// merge is not wired.
    @Test func aPetitionPacketIsTheClosestRealCase() {
        let profile = Self.profile(["Immigration/H-1B/Petition/pay_statements": 4,
                                    "Work/Compensation/Salary Statements/2026": 12])
        let groups = (1...4).map { index in
            Self.sameTextGroup(["Immigration/H-1B/Petition/pay_statements/pay-\(index).pdf",
                                "Work/Compensation/Salary Statements/2026/pay-\(index).pdf"])
        }
        let findings = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile)
        #expect(findings.count == 1)
        #expect(findings.first?.detail
                == .duplicatedTaxonomy(counterpart: "Work/Compensation/Salary Statements/2026",
                                       matchedDocuments: 4))
        // The smaller folder is wholly shared and the larger barely at all, the asymmetry the share
        // rule reads. Checked by asking the rule with the sides swapped, not by arithmetic against
        // the constant: dividing by the larger folder, 4/12 would be under every threshold.
        let reversed = Self.profile(["Immigration/H-1B/Petition/pay_statements": 12,
                                     "Work/Compensation/Salary Statements/2026": 4])
        #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: reversed).count == 1,
                "it is the smaller side either way round, not a fixed one of the two")
        let bothLarge = Self.profile(["Immigration/H-1B/Petition/pay_statements": 40,
                                      "Work/Compensation/Salary Statements/2026": 40])
        #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: bothLarge).isEmpty,
                "four shared documents out of forty is not a duplicated taxonomy")
    }
}

private extension Dictionary where Key == String {
    /// Map values with access to the key.
    func mapValues2<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
