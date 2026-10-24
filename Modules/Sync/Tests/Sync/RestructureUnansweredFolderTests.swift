import Foundation
import Testing
@testable import Sync

/// **Restructure's own listings ask a cloud-only folder through the bounded reads (FR21).**
///
/// The plan view (`RestructureTreeView.fromDisk`, `contentsOfDirectory` on the main actor) and the
/// landing's two listings (`visibleFileCount`, `directoryNames`, inside the file queue) read the
/// disk with APIs of their own, so none of them went through `DatalessFolderReads`: a folder whose
/// app has stopped hung the plan sheet, or wedged a landing and every operation queued behind it.
/// Each must come back within the reads' deadline and call the folder UNREADABLE — never empty.
@Suite struct RestructureUnansweredFolderTests {

    /// Runs `body` on a thread of its own and waits at most `bound` for its answer — so a listing
    /// that blocks on the parked provider fails this test instead of hanging the run. nil when it
    /// did not come back in time; the gate's release then lets the thread finish.
    private func answer<T: Sendable>(within bound: Duration = .seconds(5),
                                     _ body: @escaping @Sendable () -> T) async -> T? {
        // `[T]`, not `T?`: T is itself optional for the count, and a nested optional would make
        // "came back with nil" and "never came back" one value.
        let box = LockedBox<[T]>([])
        Thread.detachNewThread { let value = body(); box.withLock { $0 = [value] } }
        let deadline = ContinuousClock.now.advanced(by: bound)
        while ContinuousClock.now < deadline {
            if let value = box.withLock({ $0.first }) { return value }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    /// The landing's "is it still empty?" walk meets the dataless folder below its root: nil
    /// (unknown, so the folder is kept), within the deadline — not a wait on the provider.
    @Test(.parksAThread) func theEmptinessWalkGivesUpOnAFolderThatDoesNotAnswer() async throws {
        let f = UnansweredFolderTests.Fixture(root: "/restructure-count")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        defer { gate.release.signal() }

        let count = await answer { FileSyncManager.visibleFileCount(atPath: f.root + "/home/Cloud", fm: disk) }
        #expect(count != nil, "the walk sat on the provider past the deadline")
        #expect(count == .some(nil), "a folder that did not answer was counted: \(String(describing: count))")
        // The control: a folder with nothing dataless in it still counts.
        #expect(FileSyncManager.visibleFileCount(atPath: f.root + "/home/Notes", fm: disk) == 1)
    }

    /// The unlisted-file veto lists a source folder that does not answer: the folder is skipped
    /// whole and said so, within the deadline — not read as "nothing unlisted" and moved out of.
    @Test(.parksAThread) func theUnlistedFileVetoSkipsAFolderThatDoesNotAnswer() async throws {
        let f = UnansweredFolderTests.Fixture(root: "/restructure-veto")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        defer { gate.release.signal() }

        let actions = [RestructureManifest.Action(action: .moveFile, src: "Cloud/Archive/old.txt",
                                                  dst: "Notes/old.txt")]
        let execution = await answer {
            FileSyncManager.executeRestructureActions(actions, root: f.root + "/home", fm: disk)
        }
        let run = try #require(execution, "the veto's listing sat on the provider past the deadline")
        #expect(run.filesMoved == 0)
        #expect(run.skipped.contains { $0.hasPrefix("Cloud/Archive/ could not be read") },
                "skipped: \(run.skipped)")
        #expect(!disk.fileExists(atPath: f.root + "/home/Notes/old.txt"))
    }

    /// The plan view asks before `contentsOfDirectory`: a folder that does not answer lists as nil —
    /// unknown, which the planner refuses on — while the same folder's real contents are right there.
    @Test(.parksAThread) func thePlanViewListsAFolderThatDoesNotAnswerAsUnknown() async throws {
        let root = try makeCanonicalTempRoot(prefix: "restructure-view")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: archive.appendingPathComponent("a.txt"))
        let gate = ParkGate()
        defer { gate.release.signal() }
        // The real folder, fronted by a disk that calls it dataless and whose provider is parked.
        let disk = UnansweredFolderDisk(inner: MockFileManager(), unanswered: archive.path, gate: gate)

        let view = RestructureTreeView.fromDisk(root: root, fileManager: .default, contentsFrom: disk)

        #expect(view.files("Archive") == nil, "a folder that did not answer was listed")
        // The control: the same view lists the root, which is not dataless.
        #expect(view.childFolders("") == ["Archive"])
    }

    /// A real tree with `unanswered` fronted as a cloud-only folder whose provider is parked, and
    /// the plan view over it. The folder's real contents are on disk, so a plan that read it as
    /// empty is wrong about something that is really there.
    private func viewWithAnUnansweredFolder(_ files: [String], unanswered: String, gate: ParkGate) throws
        -> (root: URL, view: RestructureTreeView) {
        let root = try makeCanonicalTempRoot(prefix: "restructure-destination")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let disk = UnansweredFolderDisk(inner: MockFileManager(),
                                        unanswered: root.appendingPathComponent(unanswered).path, gate: gate)
        return (root, RestructureTreeView.fromDisk(root: root, fileManager: .default, contentsFrom: disk))
    }

    /// **A pair's destination that does not answer is refused, not moved onto as absent.** The
    /// whole-move branch read "no listing" as "nothing of that name stands there" and planned the
    /// source onto a folder that is there — whose apply then skips as drift, or nests.
    @Test(.parksAThread) func aPairMergeOntoADestinationThatDoesNotAnswerIsRefused() async throws {
        let gate = ParkGate()
        defer { gate.release.signal() }
        let (root, view) = try viewWithAnUnansweredFolder(
            ["Work/Badge/badge.pdf", "Work/Acme/Badge/badge.pdf"], unanswered: "Work/Acme/Badge", gate: gate)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/Acme/Badge", kind: .looseBesideContainer,
            in: view, profileId: "p", manifestId: "m", createdAt: "t")

        #expect(result == .failure(.unknownFiles(source: "Work/Acme/Badge")), "\(result)")
    }

    /// **A mapped merge into a standing target that does not answer is refused, not merged into
    /// as empty.** The target's files were read as `[]`, so a source file of a name the target
    /// already holds was planned as no collision.
    @Test(.parksAThread) func aMappedMergeIntoATargetThatDoesNotAnswerIsRefused() async throws {
        let gate = ParkGate()
        defer { gate.release.signal() }
        let (root, view) = try viewWithAnUnansweredFolder(
            ["F/2016/A/shared.pdf", "F/2016/B/shared.pdf"], unanswered: "F/2016/B", gate: gate)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [.init(source: "A", target: "B")]),
            kind: .shape, in: view, profileId: "p", manifestId: "m", createdAt: "t")

        #expect(result == .failure(.unknownFiles(source: "F/2016/B")), "\(result)")
    }

    /// One level down, the same: a subfolder the target already holds, merged into because the
    /// source has one of that name, is read before files are planned into it — not taken as empty,
    /// which planned `claim.pdf` in as no collision onto a `claim.pdf` already there.
    @Test(.parksAThread) func aMergeIntoASubfolderThatDoesNotAnswerIsRefused() async throws {
        let gate = ParkGate()
        defer { gate.release.signal() }
        let (root, view) = try viewWithAnUnansweredFolder(
            ["H/TODO/Dental/Claims/claim.pdf", "H/Dental/Claims/claim.pdf"],
            unanswered: "H/Dental/Claims", gate: gate)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = RestructurePlanner.pairMergeManifest(
            source: "H/TODO/Dental", destination: "H/Dental", kind: .mirroredInbox,
            in: view, profileId: "p", manifestId: "m", createdAt: "t")

        #expect(result == .failure(.unknownFiles(source: "H/Dental/Claims")), "\(result)")
    }
}
