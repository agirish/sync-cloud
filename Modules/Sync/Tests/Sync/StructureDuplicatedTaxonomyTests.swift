import Foundation
import Testing
@testable import Sync

/// §5.9's rule: two folders are duplicated taxonomy when a material share of their contents are
/// `.sameText` partners — never merely when their child names agree, which on this tree is
/// usually a sign of health.
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

    /// The MapR case, in shape: three same-text pairs spanning the two branches, and the smaller
    /// folder's share clears the bar — one finding, counterpart and count on the detail.
    @Test func threeSharedDocumentsAcrossTwoBranchesFire() {
        let profile = Self.profile(["Work/MapR/Forms": 4, "Finance/Tax/2016/Forms": 6])
        let groups = ["1095-C.pdf", "W-2.pdf", "1040.pdf"].map { name in
            Self.sameTextGroup(["Work/MapR/Forms/\(name)", "Finance/Tax/2016/Forms/\(name)"])
        }
        let findings = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile)
        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.kind == .duplicatedTaxonomy)
        #expect(finding.subject == "Finance/Tax/2016/Forms",
                "subject is the lexicographically first of the pair — a stable identity")
        #expect(finding.detail == .duplicatedTaxonomy(counterpart: "Work/MapR/Forms",
                                                      matchedDocuments: 3))
        #expect(finding.id == "duplicatedTaxonomy|Finance/Tax/2016/Forms")
    }

    /// The silences, each for its own reason: too few shared documents (a stray copy is the
    /// Duplicates lens's business), a share below the bar (a large archive absorbs three files
    /// from everywhere), a match that is not `.sameText` (names are not evidence here), and a
    /// stash the profile never recorded (the claim is about two organised branches).
    @Test func theSilencesHoldOneByOne() {
        let profile = Self.profile(["A/Forms": 4, "B/Forms": 40, "C/Forms": 4])

        // Two shared documents: below the floor.
        let two = ["x.pdf", "y.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "C/Forms/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: two, in: profile).isEmpty)

        // Three shared, but the smaller folder holds 40 — 3/4 clears, 3/40 does not… the SMALLER
        // side is A (4 files): 3/4 ≥ 0.5 fires. So aim the guard at the pair where the smaller
        // side is large: B (40) against C (4) with three matches — 3/4 fires; B against a
        // 40-file A' would not. Spell that case:
        let bigProfile = Self.profile(["A/Forms": 40, "B/Forms": 40])
        let three = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "B/Forms/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: three, in: bigProfile).isEmpty,
                "three shared files between two forty-file folders is not a taxonomy claim")

        // Same three pairs, but as name-only matches: names are not evidence here.
        let namesOnly = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "C/Forms/\($0)"], matchType: .nameOnly)
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: namesOnly, in: profile).isEmpty)

        // A folder the profile never recorded — a downloads stash — takes no part.
        let stash = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "Downloads/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: stash, in: profile).isEmpty)
    }

    /// Ancestor and descendant are one branch, not two taxonomies — a stash inside its own
    /// archive is the Duplicates lens's ordinary case.
    @Test func anAncestorDescendantPairIsNotATaxonomyClaim() {
        let profile = Self.profile(["A/Forms": 4, "A/Forms/Old": 4])
        let groups = ["x.pdf", "y.pdf", "z.pdf"].map {
            Self.sameTextGroup(["A/Forms/\($0)", "A/Forms/Old/\($0)"])
        }
        #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: profile).isEmpty)
    }

    /// One folder pairing with TWO counterparts must not mint two findings under one id — the
    /// identity everything downstream keys on is `kind × subject`, and the first spelling gave
    /// both pairs `subject = A`. Each pair takes whichever of its folders is still free; both
    /// are real paths, so reveal and suppression keep working.
    @Test func aFolderPairedWithTwoCounterpartsKeepsUniqueIds() {
        let profile = Self.profile(["Archive/Forms": 6, "Work/MapR/Forms": 4,
                                    "Finance/Tax/Forms": 4])
        var groups: [DuplicateGroup] = []
        for name in ["a.pdf", "b.pdf", "c.pdf"] {
            groups.append(Self.sameTextGroup(["Archive/Forms/\(name)",
                                              "Work/MapR/Forms/\(name)"]))
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

    /// The pair key is a real pair, not a joined string — `|` is legal in a folder name, and a
    /// joined key merged counts across pairs that happened to concatenate alike.
    @Test func aPipeInAFolderNameDoesNotMergePairs(){
        let profile = Self.profile(["A": 4, "B|C": 4, "A|B": 4, "C": 4])
        // Two distinct pairs whose joined spellings would collide: (A, B|C) and (A|B, C).
        var groups: [DuplicateGroup] = []
        for name in ["a.pdf", "b.pdf"] {
            groups.append(Self.sameTextGroup(["A/\(name)", "B|C/\(name)"]))
        }
        groups.append(Self.sameTextGroup(["A|B/z.pdf", "C/z.pdf"]))
        // Neither pair reaches three matches, so a correct keying yields NO findings; the
        // joined-string key summed 2 + 1 into one phantom pair of three.
        #expect(StructureDuplicatedTaxonomy.findings(groups: groups, in: profile).isEmpty)
    }
}

private extension Dictionary where Key == String {
    /// Map values with access to the key — sugar the fixture reads better with.
    func mapValues2<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
