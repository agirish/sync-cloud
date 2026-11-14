import Testing
import Foundation
import Sync
@testable import SyncCloud

/// Accepting a person offer twice must not race two sweeps with last-write-wins. The gather walks
/// every surveyed document behind a large corpus read, so a second ⌘↩ can arrive mid-sweep: accept
/// Daughter, then Elder, and the screen could show Daughter's files under Elder's name.
///
/// Two decisions guard the slot: ``shouldStart`` when the second accept arrives, ``awaits`` when a
/// sweep finishes and wants to write. The sweep's own cancellation is tested in `PersonFilesTests`.
///
/// Not covered: `acceptPersonScope`'s composition, which needs a whole `ContentView`; every
/// decision it makes is tested below.
@Suite struct PersonGatherSupersedeTests {

    private static let daughter = Person(id: "daughter", displayName: "Daughter",
                                      fullNames: ["Daughter Father"])
    private static let elder = Person(id: "elder", displayName: "Elder",
                                       fullNames: ["Elder Forebear"])
    private static let answer = PersonFileSet(personId: "daughter", ownFolders: [], elsewhere: [])

    private typealias Scope = ContentView.PersonScope

    // MARK: Starting

    @Test func repeatingTheSameAcceptMidSweepDoesNotRestartIt() {
        // The one case that must not start: same question, and restarting throws away a sweep
        // already partway through.
        let running = Scope(person: Self.daughter, phase: .gathering)
        #expect(!Scope.shouldStart(Self.daughter, given: running))
    }

    @Test func everyOtherAcceptStarts() {
        // Each asks a different question from the slot's, so each must start. Listed separately
        // because a `shouldStart` that said `false` too broadly would leave ⌘↩ doing nothing.
        #expect(Scope.shouldStart(Self.daughter, given: nil),
                "an accept with an empty slot did not start a gather")
        #expect(Scope.shouldStart(Self.elder, given: Scope(person: Self.daughter, phase: .gathering)),
                "switching person mid-sweep did not start the new gather")
        #expect(Scope.shouldStart(Self.daughter, given: Scope(person: Self.daughter,
                                                          phase: .ready(Self.answer))),
                "re-asking after the answer landed did not re-gather")
        #expect(Scope.shouldStart(Self.daughter, given: Scope(person: Self.daughter,
                                                          phase: .failed("no survey"))),
                "retrying after a failure did not start a gather — the failure would be permanent")
    }

    // MARK: Writing the answer

    @Test func aSupersededSweepMayNotWriteItsAnswer() {
        // The race: Daughter's sweep finishes after Elder's accept took the slot. A sweep that left
        // its loop before the cancel landed still reaches this check, and without it Daughter's
        // files appear under Elder's name.
        let slot = Scope(person: Self.elder, phase: .gathering)
        #expect(!Scope.awaits(Self.daughter, in: slot))
    }

    @Test func aClearedSlotTakesNoAnswer() {
        // Esc or ✕ during the sweep: a late answer must not re-open the view the user dismissed.
        #expect(!Scope.awaits(Self.daughter, in: nil))
    }

    @Test func aSlotThatAlreadyHasAnAnswerTakesNoOther() {
        // Backs up cancellation: two sweeps for the same person (only if a cancel is dropped) must
        // not overwrite each other. Only `.gathering` waits for an answer.
        let done = Scope(person: Self.daughter, phase: .ready(Self.answer))
        #expect(!Scope.awaits(Self.daughter, in: done))
    }

    @Test func theSweepThatOwnsTheSlotDoesWrite() {
        // Non-vacuity: an `awaits` that always said false would pass every test above.
        let mine = Scope(person: Self.daughter, phase: .gathering)
        #expect(Scope.awaits(Self.daughter, in: mine))
    }

    // MARK: The off-actor half — corpus read + sweep
    //
    // What runs between the two decisions: a missing corpus must be told apart from an answer, and
    // a cancel during the read must be honoured. The slot's `.failed` and the supersede path rest
    // on both.

    /// The fixture's document count, kept below `PersonFiles.gather`'s 256-document cancellation
    /// stride. Above it, the sweep's own check would throw and the cancellation test below could
    /// not see the checks around the corpus read.
    private static let corpusDocuments = 100

    /// Runs `body` against a throwaway profile directory, and removes it however that ends.
    /// Scoped so the `defer` is registered where the directory is created: a throw while writing
    /// the corpus would otherwise leave the tree in the temporary directory for good.
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
                    ("Family/Daughter/doc-\($0).pdf",
                     FilingCorpusDocument(size: 1, modified: 0, anchors: [], idHashes: []))
                }))
            try JSONEncoder().encode(corpus)
                .write(to: profile.appendingPathComponent("filing-corpus.json"))
        }
        return try await body(root)
    }

    private static func folderProfile() -> FolderProfile {
        FolderProfile(profileId: "t", root: "/root", folders: [
            "Family/Daughter": FolderProfileEntry(
                path: "Family/Daughter", role: nil, naming: nil, anchors: [], acceptsNewFiles: true,
                fileCount: 1, subfolderCount: 0, axes: ["person": "Daughter"]),
        ], personTokens: [])
    }

    private static var registry: PersonRegistry {
        PersonRegistry(people: [Person(id: "daughter", displayName: "Daughter",
                                       fullNames: ["Daughter Father"])])
    }

    // MARK: The scope is cleared by every workspace switch, not only the bar's

    /// `source` with whole-line `//` comments removed, so a scan for what the code does isn't
    /// answered by prose describing it. The target's shared stripper, ``sourceCodeOnly(_:)``.
    static func codeOnly(_ source: String) -> String { sourceCodeOnly(source) }

    /// `MacApp/ContentView.swift`, failing loudly rather than handing on an empty haystack.
    static func contentView() throws -> String { try macAppFile("ContentView.swift") }

    /// Every `.onChange(of: <property>) { … }` body in `source`, comment-stripped, in order. A
    /// property can have several handlers, and which one clears the gather decides whether a swap
    /// can skip it.
    static func onChangeBodies(of property: String, in source: String) throws -> [String] {
        let anchor = ".onChange(of: \(property)) {"
        var bodies: [String] = []
        var searchStart = source.startIndex
        while let start = source.range(of: anchor, range: searchStart..<source.endIndex) {
            let rest = source[start.upperBound...]
            // These handlers are two levels in, so their closing brace is the first at eight spaces.
            // Required, not defaulted to EOF: a body that ran to the end would contain every other
            // handler and answer yes to anything.
            let end = try #require(rest.range(of: "\n        }"),
                                   "an .onChange(of: \(property)) handler never closes at its own level")
            bodies.append(codeOnly(String(rest[..<end.lowerBound])))
            searchStart = start.upperBound
        }
        return bodies
    }

    /// The gather clears on every workspace change, not only the bar's: programmatic switches write
    /// `selectedWorkspace` directly, so a clear in the bar binding's setter would leave the gather
    /// holding the lens slot. `onChange` sees every writer. Source-level: no seam.
    @Test func everyWorkspaceSwitchClearsTheGatherNotJustTheBars() throws {
        let content = try Self.contentView()

        // Anchored on the handler, not its parameter list, which changes whenever the body needs
        // the new value. This `#require` and the body checks keep the window non-vacuous.
        let onChange = try #require(content.range(of: ".onChange(of: selectedWorkspace) {"),
                                    "the workspace onChange handler is gone — this scan is vacuous")
        let end = try #require(content[onChange.upperBound...].range(of: "\n        }"))
        // Comments stripped, so a note mentioning `clearPersonScope()` can't satisfy this with the
        // call deleted.
        let body = Self.codeOnly(String(content[onChange.upperBound..<end.lowerBound]))
        #expect(body.contains("clearPersonScope()"),
                "the gather is not cleared on every workspace change, so a programmatic switch leaves it holding the slot")

        // And not also in the bar's binding: two clears is two owners, and the binding can't see a
        // programmatic write.
        let setter = try #require(content.range(of: "if newWorkspace != previous {"))
        let setterEnd = try #require(content[setter.upperBound...].range(of: "}"))
        #expect(!Self.codeOnly(String(content[setter.upperBound..<setterEnd.lowerBound])).contains("clearPersonScope()"),
                "the bar's setter still clears the scope too")
    }

    /// A provider switch clears the gather too, or it lists a tree the window no longer shows. Each
    /// id has one handler that returns early (discovery, a pane swap) and one that always runs; a
    /// swap moves the lens source like a manual pick, so the clear sits in the one that always runs.
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

    /// The gather's "Open" expands a collapsed source rail, and only there. `focusOn` only pushes
    /// history, so with the rail collapsed the click would be dead. It asks `contentLayout`, not
    /// `panesHiddenForCurrentTab`: only the single-source layout honours that flag, so keying on it
    /// would write a persisted layout preference in Compare and Browse and change nothing visible.
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
        // It still falls back to Finder for a folder outside this pane's provider, which no pane
        // can show.
        #expect(body.contains("activateFileViewerSelecting"),
                "a folder outside the provider has no fallback and would be a silent no-op")
    }

    @Test func aMissingCorpusIsNilRatherThanAnEmptyAnswer() async throws {
        // nil and "nobody has anything" must not look alike: the slot shows the first as
        // `.failed` ("nothing has been surveyed") and the second as the empty state ("nothing is
        // theirs"). Collapsed, a missing corpus would read as a confident "0 hers".
        try await Self.withProfileDirectory(withCorpus: false) { root in
            let missing = try await ContentView.gatherOffMainActor(
                personId: "daughter", profileId: "t", directory: root,
                profile: Self.folderProfile(), registry: Self.registry)
            #expect(missing == nil, "a missing corpus produced an answer instead of nil")
        }

        // With a corpus the same call returns an answer, or the check above passes for the wrong
        // reason (any broken read returns nil).
        try await Self.withProfileDirectory(withCorpus: true) { present in
            let found = try await ContentView.gatherOffMainActor(
                personId: "daughter", profileId: "t", directory: present,
                profile: Self.folderProfile(), registry: Self.registry)
            #expect(found?.total == Self.corpusDocuments,
                    "the corpus read or the sweep is not reaching the documents")
        }
    }

    @Test func aCancelledGatherThrowsRatherThanReturningAPartialAnswer() async throws {
        // A superseded gather must throw, not return half a sweep for `awaits` to judge; the slot's
        // guard is the second line of defence. The fixture is under the sweep's 256 stride, so only
        // the checks around the corpus read can throw here.
        try await Self.withProfileDirectory(withCorpus: true) { root in
            let profile = Self.folderProfile()
            let registry = Self.registry
            let task = Task {
                // Bounded, and the cancel below is unconditional: a broken cancellation fails by
                // name instead of hanging.
                var passes = 0
                while !Task.isCancelled, passes < 5_000 {
                    passes += 1
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return try await ContentView.gatherOffMainActor(
                    personId: "daughter", profileId: "t", directory: root,
                    profile: profile, registry: registry)
            }
            task.cancel()
            // Awaited inside the scope, so the directory outlives the read; the helper's `defer`
            // fires when this closure returns.
            await #expect(throws: CancellationError.self,
                          "a cancelled gather returned an answer instead of stopping") {
                try await task.value
            }
        }
    }
}
