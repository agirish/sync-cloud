import Testing
import Foundation
@testable import Sync

/// The scope predicate, dry-run against the **live** folder profile and the real tree.
///
/// ## Why fixtures were not enough
///
/// This exact feature has already shipped a version where **12 green tests passed while a real
/// profile dry run returned zero findings**. The cause was structural, not a typo: the live profile
/// propagates axes down the whole subtree, while a synthetic fixture puts each value only on the
/// folder that owns it, so no fixture could reach the state that broke. A scope predicate has the
/// same exposure — it is entirely about how real paths nest — so it gets the same treatment.
///
/// These assertions are deliberately about **shape rather than exact counts**: the tree is the
/// user's live `~/Documents` and he edits it while work is in progress, so pinning "126 folders"
/// would make this a tripwire for his filing rather than for this code. What is pinned is what
/// cannot drift without the predicate being wrong — monotonicity, partition, and the
/// non-vacuity of each answer.
///
/// Skips (rather than fails) when the profile is absent, so a fresh checkout on another machine is
/// not red for a reason that has nothing to do with the change.
/// ## Why this is machine-pinned as well as gated on the profile existing
///
/// **`.enabled(if:)` alone was not enough, and CI proved it within the hour.** The self-hosted
/// runner runs as the same user on this same Mac, so the profile is right there and the whole suite
/// ran — under Rosetta, where `nestingIsMonotonic` took **10.8s against 1.05s natively**.
/// swift-testing runs suites in parallel, so that cost was not paid alone: it starved the
/// timing-sensitive tests beside it and took `ScanSupersedenceTests` and `DifferenceResolutionTests`
/// red on a commit that touched neither. A wall-clock budget of 2.0s came back at 9.2s, and two
/// `ParkGate`s reported `releasedByTimeout`.
///
/// A starved wait looks exactly like a slow one, which is what made it read as a flake at first
/// glance. It was not: the previous commit was green and the only new load was this suite.
///
/// So it carries `.machinePinned(.liveProfile)` too, and CI's `SYNCCLOUD_SKIP_MACHINE_PINNED` names
/// that reason. Locally — the only place these assertions mean anything — it still runs in full.
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
        // The known shape of his corpus. A profile that had shrunk to a handful of folders would
        // make every assertion below pass for the wrong reason.
        #expect(profile.folders.count > 1_000)
        #expect(Self.absoluteFolders.count == profile.folders.count)
        #expect(Self.root.hasPrefix("/"))
    }

    // MARK: Scoping partitions the tree, and never silently empties it

    @Test func everyTopLevelScopeClaimsSomeFoldersAndNotAllOfThem() throws {
        let profile = try #require(LiveProfile.profile)
        let root = Self.root
        let all = Self.absoluteFolders

        // The real top-level areas — Finance, Immigration, Family, …
        let topLevel = Set(profile.folders.keys
            .filter { $0 != "." && !$0.contains("/") })
        #expect(topLevel.count > 3, "a real tree has several top-level areas")

        var covered = Set<String>()
        for area in topLevel.sorted() {
            let path = (root as NSString).appendingPathComponent(area)
            let scope = try #require(OrganizeScope(path: path, providerRoot: root),
                                     "a top-level folder must resolve to a scope")
            let inside = all.filter { scope.contains($0) }

            // Claims itself at minimum — never zero. A scope that matched nothing is the failure
            // mode this whole dry run exists to catch.
            #expect(!inside.isEmpty, "\(area) claimed no folders at all")
            #expect(inside.contains(path))
            // And never everything: the root is not a scope, so no subtree may claim the tree.
            #expect(inside.count < all.count, "\(area) claimed the entire tree")
            covered.formUnion(inside)
        }

        // Top-level scopes PARTITION the tree: together they cover everything except the root
        // itself. A gap here would mean some folder is reachable from no scope at all.
        let uncovered = Set(all).subtracting(covered)
        #expect(uncovered == [root],
                "only the profile root should sit outside every top-level scope, got \(uncovered.count)")
    }

    @Test func nestingIsMonotonic() throws {
        // A deeper scope can never claim more than its parent. Pure containment algebra, but run
        // over the real path shapes — the ones with spaces, ampersands, `&`, accents and the
        // `NN. Mon YYYY` folders that fixtures never reproduce.
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
        // The `Legal` / `LegalArchive` hazard, hunted for in the REAL tree rather than posited —
        // and it is emphatically not hypothetical here. **His tree holds 79 such pairs**, almost
        // all of them under `Finance/IN/Accounts/HDFC Bank/Archive`, where a folder named `HDFC`
        // sits beside `HDFC Credit`, `HDFC Demat`, `HDFC Forex` and `HDFC Savings`. A scope built
        // on a bare `hasPrefix` and pointed at `HDFC` would silently swallow all four siblings and
        // every year-folder beneath them.
        //
        // Sorted + early-break rather than the O(n²) sweep this started as: any path sharing a
        // string prefix with `a` is contiguous with it in sorted order, so the scan stops at the
        // first non-match. 58s → milliseconds over the same 3,013 folders, same pairs found.
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
        // **Asserted, not merely printed.** A loop whose body never runs passes just as green as
        // one that proves something, and this is precisely the shape where that goes unnoticed.
        // If his tree ever loses every such pair, this fails and says so rather than quietly
        // becoming a test of nothing.
        #expect(checked > 0,
                "no string-prefix sibling pairs in the live tree — this test proved nothing")
    }

    // MARK: Restructure against the real detector

    @Test func restructureFindingsResolveAgainstRealScopes() throws {
        let profile = try #require(LiveProfile.profile)
        let findings = StructureDivergence.findings(in: profile)
        let root = Self.root

        // The detector's own documented result on this corpus is a small number of families; if it
        // returns none, the rest of this test is vacuous and must say so rather than pass quietly.
        try #require(!findings.isEmpty,
                     "the live profile produced no structure findings — nothing to scope")

        for finding in findings {
            let familyPath = finding.family == "."
                ? root : (root as NSString).appendingPathComponent(finding.family)

            // Scoped TO the family: inside.
            if let own = OrganizeScope(path: familyPath, providerRoot: root) {
                #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: profile.root,
                                                     scope: own) == .inside)
            }

            // Scoped to a CHILD of the family: the finding is about the folder above — surfaced,
            // never dropped. This is the case that makes Restructure honest at a leaf, and the
            // live profile is where real leaves live.
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
        // The discriminating half: scoping somewhere unrelated must actually REMOVE findings.
        // Without this the two assertions above would pass against a predicate that answered
        // `.inside`/`.aboutAncestor` for everything.
        let profile = try #require(LiveProfile.profile)
        let findings = StructureDivergence.findings(in: profile)
        try #require(findings.count >= 1)
        let root = Self.root

        // A top-level area that owns NO finding.
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
