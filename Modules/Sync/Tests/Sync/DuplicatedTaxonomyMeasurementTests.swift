import Foundation
import Testing
@testable import Sync

/// The duplicated-taxonomy detector's yield on the reference tree, with the share threshold swept
/// across it (`ROADMAP.md` §5.9).
///
/// Its yield can't be derived from `folder-profile.json` as the other detectors' can, because its
/// evidence is document content, so no number is written down until a scan has run. This is that
/// scan, through the production path: `DuplicateFinder.findGroups` over a real walk of the
/// profile's root, fed the app's persisted content-hash and fingerprint indexes, then
/// `StructureDuplicatedTaxonomy.findings` over the groups.
///
/// It prints rather than asserting a yield: one machine's count is a measurement, not an
/// invariant, and would fail the moment he files a document. The fixture next door asserts the
/// rule.
///
/// Machine-pinned on `liveProfile`: it needs his profile, tree and indexes. On CI that gate is
/// closed by design, and the report line says so rather than the suite vanishing.
@Suite(.machinePinned(.liveProfile))
struct DuplicatedTaxonomyMeasurementTests {

    /// The app's own support directory — where the two indexes the scan reads are persisted.
    private static var supportDirectory: URL? {
        FilingProfileStore.defaultDirectory()?.deletingLastPathComponent()
    }

    /// One index file as `path → digest`. Both files share this shape (`{schema, records[]}`),
    /// which is why one loader serves them.
    private static func loadIndex(_ name: String) -> [String: String] {
        guard let directory = supportDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for record in records {
            // A negative marker is not a digest: every textless document carries the same one.
            if let path = record["path"] as? String, let hex = record["hex"] as? String,
               !ContentFingerprint.isNoFingerprintMarker(hex) {
                out[path] = hex
            }
        }
        return out
    }

    /// The measurement. Prints; asserts only what cannot be a matter of how the tree looks today.
    @Test func measureTheYieldAndSweepTheShareThreshold() throws {
        guard let profile = LiveProfile.profile else {
            print("[dup-taxonomy] SKIPPED — no live folder profile")
            return
        }
        let root = (profile.root as NSString).expandingTildeInPath
        let hashes = Self.loadIndex("content-hash-index.json")
        let fingerprints = Self.loadIndex("content-fingerprint-index.json")
        print("[dup-taxonomy] root=\(root) folders=\(profile.folders.count) "
              + "hashes=\(hashes.count) fingerprints=\(fingerprints.count)")
        guard !fingerprints.isEmpty else {
            print("[dup-taxonomy] SKIPPED — no content fingerprints on this machine; the "
                  + "detector's evidence is document text, so there is nothing to measure")
            return
        }

        // The reachability gate. `~/Documents` is TCC-protected: a `swift test` process whose
        // responsible app lacks Full Disk Access gets "Operation not permitted", and the walker
        // returns an empty tree with `stalled == false`, indistinguishable from a tree with no
        // duplicates. That would print a false "0 findings" at every threshold, so the tree is
        // checked for content before any number is computed.
        guard !FileManager.default.contents(ofDirectoryReadable: root).isEmpty else {
            print("[dup-taxonomy] BLOCKED — \(root) is not readable by this process "
                  + "(TCC: Full Disk Access). NOTHING was measured; any zero below would be a "
                  + "permission result, not a tree result. Grant the terminal Full Disk Access "
                  + "in System Settings ▸ Privacy & Security and run this suite again.")
            return
        }

        // A real walk of the real tree, with the same walker the ground-truth suite uses — it
        // reports unexplored directories honestly rather than as empty ones.
        var stalled = false
        let tree = FolderSurveyGroundTruth.walk(URL(fileURLWithPath: root),
                                                deadline: Date().addingTimeInterval(600),
                                                stalled: &stalled)
        guard !stalled else {
            print("[dup-taxonomy] SKIPPED — the walk stalled (display asleep, or iCloud "
                  + "materialising); nothing measured")
            return
        }

        func countNodes(_ nodes: [FileNode]) -> (dirs: Int, files: Int) {
            var d = 0, f = 0
            for node in nodes {
                if node.isDirectory {
                    d += 1
                    let sub = countNodes(node.children ?? [])
                    d += sub.dirs; f += sub.files
                } else { f += 1 }
            }
            return (d, f)
        }
        let counted = countNodes(tree)
        print("[dup-taxonomy] walked top=\(tree.count) dirs=\(counted.dirs) "
              + "files=\(counted.files) displayAwake=\(FolderSurveyGroundTruth.displayIsAwake)")
        // A walk that came back empty over a readable root is still nothing to measure, and the
        // same false zero would follow.
        guard counted.files > 0 else {
            print("[dup-taxonomy] BLOCKED — the walk returned no files from a readable root; "
                  + "nothing measured")
            return
        }

        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: hashes,
                                                options: .init(),
                                                textFingerprints: fingerprints)
        let sameText = groups.filter { $0.matchType == .sameText && !$0.isDirectory }
        print("[dup-taxonomy] groups=\(groups.count) sameText=\(sameText.count)")

        // The sweep: the open question is whether the share of the smaller folder should be a
        // half or a third. Both, plus the ends, so the shape of the curve is visible.
        for share in [0.2, 1.0 / 3.0, 0.5, 0.75, 1.0] {
            let findings = StructureDuplicatedTaxonomy.findings(
                groups: groups, in: profile, minimumShare: share)
            let pairs = findings.compactMap { finding -> String? in
                guard case .duplicatedTaxonomy(let counterpart, let matched)? = finding.detail
                else { return nil }
                return "\(finding.subject) ↔ \(counterpart) (\(matched))"
            }
            print(String(format: "[dup-taxonomy] share>=%.2f → %d finding(s)", share,
                         findings.count))
            for pair in pairs.prefix(12) { print("[dup-taxonomy]     \(pair)") }
            if pairs.count > 12 { print("[dup-taxonomy]     … \(pairs.count - 12) more") }
        }

        // What doesn't depend on the tree: a lower share threshold can only admit more pairs,
        // never fewer. If not, the filter isn't monotone and every number above is meaningless.
        let loose = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile,
                                                          minimumShare: 0.2).count
        let tight = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile,
                                                         minimumShare: 1.0).count
        #expect(loose >= tight, "the share filter is monotone by construction")
    }
}

private extension FileManager {
    /// The root's own entries, or empty when the process may not look: the distinction the walker
    /// erases, and the one that decides whether a zero means anything.
    func contents(ofDirectoryReadable path: String) -> [String] {
        (try? contentsOfDirectory(atPath: path)) ?? []
    }
}
