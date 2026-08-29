import Foundation
import Testing
@testable import Sync

/// **The §5.9 measurement** (proposal O18) — the yield of the duplicated-taxonomy detector on the
/// reference tree, and the share threshold swept across it.
///
/// The roadmap's standing order for this detector is that **no number goes anywhere until a scan
/// has run**: its yield cannot be derived from `folder-profile.json` the way the other seven
/// detectors' were, because its evidence is document *content*. This suite is that scan, run
/// through the production path — `DuplicateFinder.findGroups` over a real walk of the profile's
/// root, fed the persisted content-hash and content-fingerprint indexes the app itself uses, then
/// `StructureDuplicatedTaxonomy.findings` over the groups that come back.
///
/// It **prints** rather than asserting a yield. A count off one machine's tree is a measurement,
/// not an invariant, and pinning it here would fail the moment he files a document. What the
/// pinned fixture next door asserts is the *rule*; this is where the number to write down comes
/// from, and the line it prints is the evidence for the note in ROADMAP_V5 §5.9.
///
/// Machine-pinned on `liveProfile`: it needs his profile, his tree and his indexes. On CI that
/// gate is closed by design, and the report line says so rather than the suite vanishing.
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
            if let path = record["path"] as? String, let hex = record["hex"] as? String {
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

        // **The reachability gate, and it is the one that actually bites.** `~/Documents` is
        // TCC-protected: a `swift test` process whose responsible app has not been granted Full
        // Disk Access gets "Operation not permitted" and the walker returns an EMPTY tree with
        // `stalled == false` — indistinguishable, downstream, from a tree with no duplicates in
        // it. The first version of this suite printed "0 findings" at every threshold on exactly
        // that basis, which is the false zero §5.9's standing order exists to keep out of the
        // roadmap. So the tree is checked for content before a single number is computed.
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

        // The sweep: the open question §5.9 carries is whether the share of the smaller folder
        // should be a half or a third. Both, plus the ends, so the shape of the curve is visible
        // rather than two points to choose between.
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

        // The one thing that is not a matter of how the tree looks today: a lower share threshold
        // can only admit more pairs, never fewer. A sweep that violated this would mean the
        // filter is not the monotone rule it is written as, and every number above would be
        // uninterpretable.
        let loose = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile,
                                                          minimumShare: 0.2).count
        let tight = StructureDuplicatedTaxonomy.findings(groups: groups, in: profile,
                                                         minimumShare: 1.0).count
        #expect(loose >= tight, "the share filter is monotone by construction")
    }
}

private extension FileManager {
    /// The root's own entries, or empty when the process may not look — the distinction the
    /// walker erases, and the one that decides whether a zero below means anything.
    func contents(ofDirectoryReadable path: String) -> [String] {
        (try? contentsOfDirectory(atPath: path)) ?? []
    }
}
