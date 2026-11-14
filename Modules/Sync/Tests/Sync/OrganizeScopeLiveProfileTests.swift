import Testing
import Foundation
@testable import Sync

/// The scope predicate, dry-run against the live folder profile and the real tree, since the live
/// profile propagates axes down whole subtrees as fixtures don't. Pins shape, not counts (the tree
/// is his live `~/Documents`): monotonicity, partition, and each answer's non-vacuity. Skips when the
/// profile is absent. Machine-pinned: under Rosetta on the CI runner it runs about ten times slower
/// and starves the timing-sensitive suites beside it into false reds.
@Suite(.enabled(if: LiveProfile.isAvailable,
                "no live folder profile on this machine — dry run skipped"),
       .machinePinned(.liveProfile))
struct OrganizeScopeLiveProfileTests {

    // MARK: The tree the profile describes

    /// Absolute paths of every folder in the live profile.
    static let absoluteFolders: [String] = {
        guard let profile = LiveProfile.profile else { return [] }
        let root = (profile.root as NSString).expandingTildeInPath
        return profile.folders.keys.map {
            $0 == "." ? root : (root as NSString).appendingPathComponent($0)
        }
    }()

    static var root: String {
        ((LiveProfile.profile?.root ?? "") as NSString).expandingTildeInPath
    }

    // MARK: Non-vacuity — the dry run has to be looking at something

    @Test func theLiveProfileIsTheRealOneAndIsLarge() throws {
        let profile = try #require(LiveProfile.profile)
        // The known shape of his corpus. A profile shrunk to a handful of folders would make every
        // assertion below pass for the wrong reason.
        #expect(profile.folders.count > 1_000)
        #expect(Self.absoluteFolders.count == profile.folders.count)
        #expect(Self.root.hasPrefix("/"))
    }

    // MARK: Scoping partitions the tree, and never silently empties it

    @Test func everyTopLevelScopeClaimsSomeFoldersAndNotAllOfThem() throws {
        let profile = try #require(LiveProfile.profile)
        let root = Self.root
        let all = Self.absoluteFolders

        // The real top-level areas: Finance, Immigration, Family, …
        let topLevel = Set(profile.folders.keys
            .filter { $0 != "." && !$0.contains("/") })
        #expect(topLevel.count > 3, "a real tree has several top-level areas")

        var covered = Set<String>()
        for area in topLevel.sorted() {
            let path = (root as NSString).appendingPathComponent(area)
            let scope = try #require(OrganizeScope(path: path, providerRoot: root),
                                     "a top-level folder must resolve to a scope")
            let inside = all.filter { scope.contains($0) }

            // Claims itself at minimum, never zero: a scope that matched nothing is the failure
            // this dry run exists to catch.
            #expect(!inside.isEmpty, "\(area) claimed no folders at all")
            #expect(inside.contains(path))
            // And never everything: the root is not a scope, so no subtree may claim the tree.
            #expect(inside.count < all.count, "\(area) claimed the entire tree")
            covered.formUnion(inside)
        }

        // Top-level scopes partition the tree: together they cover everything except the root
        // itself. A gap would mean some folder is reachable from no scope at all.
        let uncovered = Set(all).subtracting(covered)
        #expect(uncovered == [root],
                "only the profile root should sit outside every top-level scope, got \(uncovered.count)")
    }

    @Test func nestingIsMonotonic() throws {
        // A deeper scope can never claim more than its parent. Pure containment algebra, run over
        // the real path shapes: spaces, ampersands, accents and the `NN. Mon YYYY` folders that
        // fixtures never reproduce.
        let root = Self.root
        let all = Self.absoluteFolders
        let deep = all
            .filter { $0.split(separator: "/").count >= 4 }
            .sorted()
            .prefix(40)

        for path in deep {
            guard let scope = OrganizeScope(path: path, providerRoot: root) else { continue }
            let parentPath = (path as NSString).deletingLastPathComponent
            guard let parent = OrganizeScope(path: parentPath, providerRoot: root) else { continue }
            let mine = all.filter { scope.contains($0) }
            let theirs = all.filter { parent.contains($0) }
            #expect(mine.count <= theirs.count)
            #expect(mine.allSatisfy { parent.contains($0) },
                    "\(path) claims a folder its parent does not")
        }
    }

    @Test func noScopeClaimsASiblingSharingAPrefix() throws {
        // The `Legal` / `LegalArchive` hazard, common in the real tree (`HDFC` beside `HDFC Credit`).
        // Sorted with an early break: paths sharing a string prefix are contiguous in sorted order.
        let root = Self.root
        let all = Self.absoluteFolders.sorted()
        var checked = 0
        for (i, a) in all.enumerated() {
            guard let scope = OrganizeScope(path: a, providerRoot: root) else { continue }
            for b in all[(i + 1)...] {
                guard b.hasPrefix(a) else { break }
                guard !b.hasPrefix(a + "/") else { continue }
                #expect(!scope.contains(b), "\(a) must not claim \(b)")
                checked += 1
            }
        }
        // Asserted, not printed: a loop whose body never runs passes just as green. If his tree
        // ever loses every such pair, this fails rather than quietly testing nothing.
        #expect(checked > 0,
                "no string-prefix sibling pairs in the live tree — this test proved nothing")
    }

    // MARK: Restructure against the real detector

    @Test func restructureFindingsResolveAgainstRealScopes() throws {
        let profile = try #require(LiveProfile.profile)
        let findings = StructureDivergence.findings(in: profile)
        let root = Self.root

        // The detector finds a small number of families on this corpus; if it returns none, the
        // rest of this test is vacuous and must say so rather than pass.
        try #require(!findings.isEmpty,
                     "the live profile produced no structure findings — nothing to scope")

        for finding in findings {
            let familyPath = finding.family == "."
                ? root : (root as NSString).appendingPathComponent(finding.family)

            // Scoped to the family: inside.
            if let own = OrganizeScope(path: familyPath, providerRoot: root) {
                #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: profile.root,
                                                     scope: own) == .inside)
            }

            // Scoped to a child of the family: the finding is about the folder above, so it is
            // surfaced, never dropped. This keeps Restructure honest at a leaf, and the live
            // profile is where real leaves live.
            let child = profile.folders.keys.first {
                $0 != finding.family && $0.hasPrefix(finding.family + "/")
            }
            if let child, let childScope = OrganizeScope(
                path: (root as NSString).appendingPathComponent(child), providerRoot: root) {
                #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: profile.root,
                                                     scope: childScope) == .aboutAncestor,
                        "finding \(finding.family) under child scope \(child)")
            }
        }
    }

    @Test func aScopeInAnUnrelatedAreaHidesTheFindingsOfAnother() throws {
        // The discriminating half: scoping somewhere unrelated must actually remove findings.
        // Without it, the assertions above would pass against a predicate that answered
        // `.inside`/`.aboutAncestor` for everything.
        let profile = try #require(LiveProfile.profile)
        let findings = StructureDivergence.findings(in: profile)
        try #require(findings.count >= 1)
        let root = Self.root

        // A top-level area that owns no finding.
        let familyRoots = Set(findings.map { $0.family.split(separator: "/").first.map(String.init) ?? "." })
        let unrelated = profile.folders.keys
            .filter { $0 != "." && !$0.contains("/") && !familyRoots.contains($0) }
            .sorted()
            .first
        let area = try #require(unrelated, "every top-level area owns a finding — cannot discriminate")
        let scope = try #require(OrganizeScope(
            path: (root as NSString).appendingPathComponent(area), providerRoot: root))

        let visible = findings.filter {
            OrganizeScopeFilter.relation(of: $0, profileRoot: profile.root, scope: scope) != .outside
        }
        // Everything still visible under an unrelated scope must be an ancestor finding (a family
        // at or above the root), never an `inside` one.
        #expect(visible.allSatisfy {
            OrganizeScopeFilter.relation(of: $0, profileRoot: profile.root, scope: scope) == .aboutAncestor
        })
        #expect(visible.count < findings.count,
                "scoping to \(area) hid nothing — the predicate is not discriminating")
    }
}

/// The live profile, loaded once.
enum LiveProfile {

    static let profile: FolderProfile? = {
        guard let dir = FilingProfileStore.defaultDirectory(),
              let id = FilingProfileStore.activeProfileId(in: dir) else { return nil }
        return FilingProfileStore.profile(id: id, in: dir)
    }()

    static var isAvailable: Bool { (profile?.folders.count ?? 0) > 0 }
}
