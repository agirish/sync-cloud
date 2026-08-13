import Testing
import Foundation
import Sync
@testable import SyncCloud

/// Accepting a person offer twice used to race two sweeps with last-write-wins.
///
/// The gather walks every surveyed document — 10,171 on the real tree — behind a 4.9 MB corpus
/// read, so a second ⌘↩ arrives while the first is still going. Nothing held the first task, so
/// nothing cancelled it, and whichever finished last wrote the slot: accept Aditi, change your
/// mind, accept Girish, and the answer on screen could be Aditi's under Girish's name.
///
/// Two decisions guard that, and they are opposite ends of the same window. ``shouldStart`` is
/// asked when the second accept arrives; ``awaits`` is asked when a sweep finishes and wants to
/// write. The sweep's own cancellation is tested in `PersonFilesTests` — this is the slot half,
/// which is where the wrong answer actually reached the screen.
///
/// **Two claims here are deliberately uncovered, and saying so beats pretending.**
///
/// `acceptPersonScope` itself cannot be driven: it needs a whole `ContentView` with a live
/// `FileSyncManager`, and SwiftUI state is not reachable from a unit test. So the *composition* —
/// that the `.failed` slot is written when the profile is missing rather than the accept returning
/// silently, and that `Task.isCancelled` is consulted alongside `awaits` — rests on the pieces
/// below plus review, not on a test. What is covered is every decision the composition makes.
@Suite struct PersonGatherSupersedeTests {

    private static let aditi = Person(id: "aditi", displayName: "Aditi",
                                      fullNames: ["Aditi Abhishek"])
    private static let girish = Person(id: "girish", displayName: "Girish",
                                       fullNames: ["Girish Krishnamurthy"])
    private static let answer = PersonFileSet(personId: "aditi", herFolders: [], elsewhere: [])

    private typealias Scope = ContentView.PersonScope

    // MARK: Starting

    @Test func repeatingTheSameAcceptMidSweepDoesNotRestartIt() {
        // The one case that must NOT start: it is the same question, and restarting throws away
        // a sweep already partway through the corpus.
        let running = Scope(person: Self.aditi, phase: .gathering)
        #expect(!Scope.shouldStart(Self.aditi, given: running))
    }

    @Test func everyOtherAcceptStarts() {
        // Each of these is a different question from what the slot holds, so each must start —
        // and they are listed separately because a `shouldStart` that answered `false` more
        // broadly would leave ⌘↩ doing nothing at all, which is the bug this feature is fixing.
        #expect(Scope.shouldStart(Self.aditi, given: nil),
                "an accept with an empty slot did not start a gather")
        #expect(Scope.shouldStart(Self.girish, given: Scope(person: Self.aditi, phase: .gathering)),
                "switching person mid-sweep did not start the new gather")
        #expect(Scope.shouldStart(Self.aditi, given: Scope(person: Self.aditi,
                                                          phase: .ready(Self.answer))),
                "re-asking after the answer landed did not re-gather")
        #expect(Scope.shouldStart(Self.aditi, given: Scope(person: Self.aditi,
                                                          phase: .failed("no survey"))),
                "retrying after a failure did not start a gather — the failure would be permanent")
    }

    // MARK: Writing the answer

    @Test func aSupersededSweepMayNotWriteItsAnswer() {
        // **The race, stated.** Aditi's sweep finishes after Girish's accept has taken the slot.
        // Cancellation usually stops it first, but a sweep that had already left the loop when
        // the cancel landed still reaches this check — and without it, Aditi's files appear
        // under Girish's name.
        let slot = Scope(person: Self.girish, phase: .gathering)
        #expect(!Scope.awaits(Self.aditi, in: slot))
    }

    @Test func aClearedSlotTakesNoAnswer() {
        // Esc or the ✕ during the sweep: the answer arriving afterwards must not re-open the
        // view the user just dismissed.
        #expect(!Scope.awaits(Self.aditi, in: nil))
    }

    @Test func aSlotThatAlreadyHasAnAnswerTakesNoOther() {
        // Belt to the cancellation's braces: two sweeps for the SAME person (possible only if
        // a cancel is dropped) must not overwrite each other. `.gathering` is the only phase
        // that is waiting for anything.
        let done = Scope(person: Self.aditi, phase: .ready(Self.answer))
        #expect(!Scope.awaits(Self.aditi, in: done))
    }

    @Test func theSweepThatOwnsTheSlotDoesWrite() {
        // Non-vacuity: without this, a broken `awaits` returning false always would pass every
        // assertion above and no gather would ever paint an answer.
        let mine = Scope(person: Self.aditi, phase: .gathering)
        #expect(Scope.awaits(Self.aditi, in: mine))
    }

    // MARK: The off-actor half — corpus read + sweep
    //
    // The two decisions above are pure and were the only thing covered. What actually runs between
    // them had NO test: whether a missing corpus is distinguishable from an answer, and whether a
    // cancel during the read is honoured. Both are what the slot's `.failed` and the supersede
    // path are built on, so a silent change in either would go straight past the suite above.

    /// A corpus of `documents` files, deliberately **below `PersonFiles.gather`'s 256-document
    /// cancellation stride**. That is what makes the cancellation test below test what it claims:
    /// with a larger corpus the sweep's own periodic check would throw, and removing the checks
    /// that bracket the corpus read — the ones this file is here to cover — would fail nothing.
    private static let corpusDocuments = 100

    /// Runs `body` against a throwaway profile directory, and **removes it however that ends**.
    ///
    /// A scoped helper rather than one that hands the URL back, because the `defer` has to be
    /// registered where the directory is created. The version this replaces created the tree and
    /// then encoded a corpus into it: a throw from that write — a full disk, a sandbox denial —
    /// left the caller without the URL it was going to clean up, so the tree stayed under
    /// `NSTemporaryDirectory()` for good. Small, and this machine has already had to sweep 26,047
    /// of another leak's leftovers; the fix is to make the cleanup impossible to be handed past.
    private static func withProfileDirectory<T>(
        withCorpus: Bool, _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("t")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if withCorpus {
            let corpus = FilingCorpus(profileId: "t", salt: "s", documents: Dictionary(
                uniqueKeysWithValues: (0..<corpusDocuments).map {
                    ("Family/Aditi/doc-\($0).pdf",
                     FilingCorpusDocument(size: 1, modified: 0, anchors: [], idHashes: []))
                }))
            try JSONEncoder().encode(corpus)
                .write(to: profile.appendingPathComponent("filing-corpus.json"))
        }
        return try await body(root)
    }

    private static func folderProfile() -> FolderProfile {
        FolderProfile(profileId: "t", root: "/root", folders: [
            "Family/Aditi": FolderProfileEntry(
                path: "Family/Aditi", role: nil, naming: nil, anchors: [], acceptsNewFiles: true,
                fileCount: 1, subfolderCount: 0, axes: ["person": "Aditi"]),
        ], personTokens: [])
    }

    private static var registry: PersonRegistry {
        PersonRegistry(people: [Person(id: "aditi", displayName: "Aditi",
                                       fullNames: ["Aditi Abhishek"])])
    }

    // MARK: The scope is cleared by every workspace switch, not only the bar's

    /// **`workspaceSelection` is the bar; `selectedWorkspace` is the workspace.**
    ///
    /// The clear lived in the binding's setter, which only the bar, the ⌘1–⌘N chords and ⌘K route
    /// through. Every programmatic switch wrote `selectedWorkspace` directly and went around it —
    /// `show(_:)` (behind "Find duplicates of this" and the automation preview),
    /// `findFilingSuggestionsAction`, `buildStorageLensAction`, and both duplicate coordinators. So
    /// right-clicking a file for its duplicates while a gather was open landed on Organize with the
    /// gather still holding the lens slot: the list of someone's files sat where the duplicates
    /// list belongs and the click looked dead. `onChange` fires for every writer.
    ///
    /// Source-level because `ContentView`'s state has no seam — the same reason this suite already
    /// gives for `acceptPersonScope`.
    /// Whole-line `//` comments removed, so a scan for what the code does is not answered by the
    /// prose describing it.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `MacApp/ContentView.swift`, failing loudly rather than handing on an empty haystack.
    static func contentView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let content = try #require(try? String(contentsOf: url, encoding: .utf8),
                                   "cannot read ContentView.swift — this scan would be vacuous")
        try #require(content.count > 500, "ContentView.swift is implausibly short")
        return content
    }

    /// Every `.onChange(of: <property>) { … }` body in `source`, comment-stripped and in source
    /// order. Plural because a property can have more than one handler — which is the whole point
    /// of the check below: *which* of them clears the gather decides whether a swap can outrun it.
    static func onChangeBodies(of property: String, in source: String) throws -> [String] {
        let anchor = ".onChange(of: \(property)) {"
        var bodies: [String] = []
        var searchStart = source.startIndex
        while let start = source.range(of: anchor, range: searchStart..<source.endIndex) {
            let rest = source[start.upperBound...]
            // These handlers are two levels in, so their closing brace is the first at eight spaces.
            // Required, not defaulted to the end of the file: a body that ran to EOF would contain
            // every other handler's code and answer yes to anything.
            let end = try #require(rest.range(of: "\n        }"),
                                   "an .onChange(of: \(property)) handler never closes at its own level")
            bodies.append(codeOnly(String(rest[..<end.lowerBound])))
            searchStart = start.upperBound
        }
        return bodies
    }

    @Test func everyWorkspaceSwitchClearsTheGatherNotJustTheBars() throws {
        let content = try Self.contentView()

        // Anchored on the handler, not on its parameter list: the closure binds its new value when
        // something in the body needs it (the workspace breadcrumb does), and a scan that fixes the
        // names `_, _` fails on that rename while the invariant it guards is untouched. What makes
        // the window non-vacuous is this `#require` plus the body assertions below, neither of
        // which cares what the parameters are called.
        let onChange = try #require(content.range(of: ".onChange(of: selectedWorkspace) {"),
                                    "the workspace onChange handler is gone — this scan is vacuous")
        let end = try #require(content[onChange.upperBound...].range(of: "\n        }"))
        // Comments stripped: the window is dominated by the note explaining why the clear moved
        // here, and one reword mentioning `clearPersonScope()` would satisfy this with the call
        // deleted.
        let body = Self.codeOnly(String(content[onChange.upperBound..<end.lowerBound]))
        #expect(body.contains("clearPersonScope()"),
                "the gather is not cleared on every workspace change, so a programmatic switch leaves it holding the slot")

        // And it is not ALSO left in the bar's binding — two clears is two owners, and the binding
        // is the one that cannot see a programmatic write.
        let setter = try #require(content.range(of: "if newWorkspace != previous {"))
        let setterEnd = try #require(content[setter.upperBound...].range(of: "}"))
        #expect(!Self.codeOnly(String(content[setter.upperBound..<setterEnd.lowerBound])).contains("clearPersonScope()"),
                "the bar's setter still clears the scope too")
    }

    /// **A provider switch clears it too — from the handler no early return can skip.**
    ///
    /// The gather is an answer about the whole SOURCE, so it goes stale the moment the pane's
    /// provider changes: the card lists files from a tree the window no longer shows, and its
    /// "Open" joins the old profile root to a relative path and relativizes it against the NEW
    /// provider root, where it cannot match — the button quietly degrades to a Finder reveal.
    ///
    /// `clearLensResultsForProviderSwitch()` is the list that owns "no stale Tidy result outlives
    /// its provider" and it cannot reach this one: that list is the manager's, and the gather takes
    /// the lens slot from `ContentView`'s own `@State`.
    ///
    /// **Which of the two handlers does the clearing is the substance of this test.** Each id has
    /// one handler that returns early — while providers are still being discovered, and again on a
    /// pane swap, whose `pendingSwapProviderChanges` suppression exists so the swap's own
    /// navigation is not reset — and one that runs unconditionally. A swap moves the single Tidy
    /// source onto the other provider exactly as a manual pick does, so a clear behind those
    /// returns would leave the gather standing in the case that looks most like it did not change.
    @Test func everyProviderSwitchClearsTheGatherWhicheverPaneMoved() throws {
        let content = try Self.contentView()
        for id in ["leftProviderId", "rightProviderId"] {
            let handlers = try Self.onChangeBodies(of: id, in: content)
            #expect(!handlers.isEmpty, "\(id) has no onChange handler at all — this scan is vacuous")
            let clearing = handlers.filter { $0.contains("clearPersonScope()") }
            #expect(clearing.count == 1,
                    "\(clearing.count) of \(id)'s \(handlers.count) onChange handler(s) clear the person gather — it must be exactly one: none leaves a gather listing a tree the window no longer shows, two is two owners")
            let body = clearing.first ?? ""
            #expect(!body.contains("pendingSwapProviderChanges"),
                    "\(id)'s clear sits in the handler that suppresses a pane swap, so swapping the panes leaves a gather aimed at the other provider")
            #expect(!body.contains("isBootstrappingProviders"),
                    "\(id)'s clear sits behind the bootstrap guard, so it is skipped for every switch that guard returns on")
        }
    }

    /// **Open opens the rail — and only where opening it means anything.**
    ///
    /// Rewiring the gather's "Open" from a Finder reveal to a pane focus made it a dead click when
    /// the source rail is collapsed: `focusOn` only pushes history, and the Finder fallback does
    /// not fire for a folder that IS under the provider root. The fix asks `contentLayout`, not
    /// `panesHiddenForCurrentTab` — that flag is honoured only by the single-source layout, so
    /// keying on it would write a persisted layout preference in Compare and Browse, where the
    /// layout is resolved before the flag is consulted and nothing visible would change.
    @Test func theGathersOpenExpandsACollapsedRailOnly() throws {
        let content = try Self.contentView()

        let start = try #require(content.range(of: "onOpenFolder: { relative in"),
                                 "the gather's Open handler is gone — this scan is vacuous")
        let rest = content[start.upperBound...]
        let end = try #require(rest.range(of: "\n                   },"))
        let body = Self.codeOnly(String(rest[..<end.lowerBound]))

        #expect(body.contains("if contentLayout == .singleCollapsed { togglePanesForCurrentTab() }"),
                "Open no longer opens a collapsed rail, or keys on a flag two layouts ignore")
        #expect(body.contains("syncManager.focusOn(relativePath: inPane"),
                "Open no longer focuses the pane")
        // And it still falls back to Finder for a folder outside this pane's provider, which is
        // the case no pane can show.
        #expect(body.contains("activateFileViewerSelecting"),
                "a folder outside the provider has no fallback and would be a silent no-op")
    }

    @Test func aMissingCorpusIsNilRatherThanAnEmptyAnswer() async throws {
        // **nil and "nobody has anything" must not look alike.** The slot renders the first as
        // `.failed` ("nothing has been surveyed") and the second as the empty state ("nothing is
        // theirs"), which are different claims — and collapsing them is how the missing-corpus
        // path would silently become a confident "0 hers".
        try await Self.withProfileDirectory(withCorpus: false) { root in
            let missing = try await ContentView.gatherOffMainActor(
                personId: "aditi", profileId: "t", directory: root,
                profile: Self.folderProfile(), registry: Self.registry)
            #expect(missing == nil, "a missing corpus produced an answer instead of nil")
        }

        // …and with a corpus present the same call returns one, or the assertion above passes for
        // the wrong reason (any broken read would also return nil).
        try await Self.withProfileDirectory(withCorpus: true) { present in
            let found = try await ContentView.gatherOffMainActor(
                personId: "aditi", profileId: "t", directory: present,
                profile: Self.folderProfile(), registry: Self.registry)
            #expect(found?.total == Self.corpusDocuments,
                    "the corpus read or the sweep is not reaching the documents")
        }
    }

    @Test func aCancelledGatherThrowsRatherThanReturningAPartialAnswer() async throws {
        // A superseded gather must not come back with half a sweep and let `awaits` decide — the
        // slot's guard is the second line of defence, not the first.
        //
        // The fixture is 100 documents, under the sweep's 256 stride, so `PersonFiles.gather`
        // never reaches a check of its own: the only thing that can throw here is the pair of
        // checks bracketing the corpus read.
        try await Self.withProfileDirectory(withCorpus: true) { root in
            let profile = Self.folderProfile()
            let registry = Self.registry
            let task = Task {
                // Bounded, and the cancel below is unconditional, so this terminates either way: the
                // pass cap turns a broken cancellation into a named failure instead of a hang.
                var passes = 0
                while !Task.isCancelled, passes < 5_000 {
                    passes += 1
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return try await ContentView.gatherOffMainActor(
                    personId: "aditi", profileId: "t", directory: root,
                    profile: profile, registry: registry)
            }
            task.cancel()
            // Awaited INSIDE the scope, so the directory outlives the read it is there for — the
            // helper's `defer` fires only once this closure returns.
            await #expect(throws: CancellationError.self,
                          "a cancelled gather returned an answer instead of stopping") {
                try await task.value
            }
        }
    }
}
