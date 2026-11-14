import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// Go to Folder: Finder's ⇧⌘G in the ⌘K field. A typed path answers with one row, never an empty
/// list: a live row for the current source or another mounted one (`.folderInSource`), otherwise a
/// refusal that says why.
@Suite struct PalettePathTests {

    static let home = "/Users/x"
    static let documents = "/Users/x/Documents"
    static let dropbox = "/Users/x/Dropbox"

    /// Two sources, one current. `Backup SSD` is the unmounted one the palette carries elsewhere.
    static func providers() -> [PaletteProvider] {
        [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                         isCurrent: true, root: documents),
         PaletteProvider(id: "dropbox", name: "Dropbox", isMounted: true,
                         isCurrent: false, root: dropbox),
         PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: false,
                         isCurrent: false, root: "/Volumes/Backup")]
    }

    static func index() -> PaletteIndex {
        PaletteIndex(providers: providers(),
                     providerRoot: documents, folders: ["Legal", "Clients/Legal"],
                     home: home, isScanning: false, hasSurvey: true)
    }

    /// A probe that answers from a set and records what it was asked: half this feature is what it
    /// must not ask (`theDiskIsNeverAskedAboutAPathOutsideTheAimedSource`).
    final class Probe: @unchecked Sendable {
        private let directories: Set<String>
        private let files: Set<String>
        private(set) var asked: [String] = []

        init(directories: Set<String> = [], files: Set<String> = []) {
            self.directories = directories
            self.files = files
        }

        var kind: PalettePathProbe {
            { [self] path in
                asked.append(path)
                if directories.contains(path) { return .directory }
                if files.contains(path) { return .file }
                return .missing
            }
        }
    }

    static func row(_ query: String, probe: Probe, index: PaletteIndex = Self.index()) -> PaletteRow? {
        PaletteRouter.rows(query: query, index: index, probe: probe.kind)
            .first { $0.id.hasPrefix("path.") }
    }

    // MARK: What counts as a path at all

    /// A leading `/` or `~`, never "contains a slash": `Clients/Legal` is a folder name
    /// `folderRows` matches, and as a path it would resolve against the working directory.
    @Test func onlyALeadingSlashOrTildeIsAPath() {
        #expect(PalettePath.looksLikeAPath("/Users/x/Documents/Legal"))
        #expect(PalettePath.looksLikeAPath("~/Documents/Legal"))
        #expect(PalettePath.looksLikeAPath("~"))
        #expect(!PalettePath.looksLikeAPath("Clients/Legal"))
        #expect(!PalettePath.looksLikeAPath("legal"))
        #expect(!PalettePath.looksLikeAPath(""))
    }

    /// A relative name is not a path, and the disk is not asked about it. (`rankedFolders` doesn't
    /// normalise slashes in the query, so `Clients/Legal` matches no folder either.)
    @Test func aRelativeNameIsNotAPathAndTheDiskIsNotAskedAboutIt() {
        let probe = Probe()
        let rows = PaletteRouter.rows(query: "Clients/Legal", index: Self.index(), probe: probe.kind)
        #expect(!rows.contains { $0.id.hasPrefix("path.") },
                "a relative folder name was taken for a typed path — it would resolve against the process working directory")
        #expect(probe.asked.isEmpty, "the disk was asked about a query that is not a path")
    }

    // MARK: Resolving the string

    /// Surrounding whitespace is not part of a pasted path; `rows` trims it once for every builder.
    @Test func surroundingWhitespaceIsIgnored() throws {
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(Self.row("  ~/Documents/Legal  ", probe: probe))
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"))
    }

    /// A path row outranks the best possible name match: it states intent rather than guessing.
    @Test func aPathOutranksEveryNameMatch() {
        #expect(PaletteRouter.pathRowScore > PaletteRouter.score(.exact))
    }

    @Test func aTildeIsExpandedAgainstTheInjectedHome() {
        #expect(PalettePath.absolute("~/Documents/Legal", home: Self.home) == "/Users/x/Documents/Legal")
        #expect(PalettePath.absolute("~", home: Self.home) == Self.home)
    }

    /// A trailing slash arrives from a copied path and from tab-completion habits.
    @Test func aTrailingSlashIsNotPartOfTheName() {
        #expect(PalettePath.absolute("~/Documents/Legal/", home: Self.home) == "/Users/x/Documents/Legal")
        #expect(PalettePath.absolute("/", home: Self.home) == "/", "the volume root lost its only character")
    }

    /// `..` collapses before the source is decided, or `~/Documents/../Dropbox` would be revealed
    /// inside Documents as `../Dropbox`.
    @Test func dotDotIsResolvedBeforeAnythingIsDecided() {
        let resolved = PalettePath.absolute("~/Documents/../Dropbox", home: Self.home)
        #expect(resolved == Self.dropbox, "got \(resolved)")
        #expect(PalettePath.owner(of: resolved, in: Self.providers())?.id == "dropbox",
                "the wrong source claimed a path that climbed out of it")
    }

    // MARK: Which source owns it

    /// The innermost of two nested sources wins; the first match in settings order would hand the
    /// path to whichever was added first.
    @Test func theInnermostSourceClaimsAPathUnderBoth() {
        let nested = [PaletteProvider(id: "outer", name: "Documents", isMounted: true,
                                      isCurrent: true, root: Self.documents),
                      PaletteProvider(id: "inner", name: "Clients", isMounted: true,
                                      isCurrent: false, root: "\(Self.documents)/Clients")]
        #expect(PalettePath.owner(of: "\(Self.documents)/Clients/Legal", in: nested)?.id == "inner")
        #expect(PalettePath.owner(of: "\(Self.documents)/Legal", in: nested)?.id == "outer")
    }

    /// A source with no path configured must never claim anything: an empty root prefixes every
    /// absolute path, the hazard `PathBoundary.relativize` guards by name.
    @Test func aSourceWithNoPathClaimsNothing() {
        let blank = [PaletteProvider(id: "blank", name: "Unset", isMounted: true,
                                     isCurrent: true, root: "")]
        #expect(PalettePath.owner(of: "/anywhere/at/all", in: blank) == nil)
    }

    // MARK: The row it produces

    @Test func aFolderInTheCurrentSourceIsARowThatGoesThere() throws {
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(Self.row("~/Documents/Legal", probe: probe))
        #expect(row.isAvailable, "refused with: \(row.unavailable ?? "")")
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"))
        #expect(row.title == "Legal")
        #expect(row.detail == "\(Self.documents)/Legal")
    }

    /// A pasted file path (what a Finder copy puts on the clipboard) goes to its enclosing folder,
    /// as ⇧⌘G does, and the row says so.
    @Test func aFilePathGoesToItsEnclosingFolderAndSaysSo() throws {
        let probe = Probe(files: ["\(Self.documents)/Legal/invoice.pdf"])
        let row = try #require(Self.row("~/Documents/Legal/invoice.pdf", probe: probe))
        #expect(row.isAvailable, "refused with: \(row.unavailable ?? "")")
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"),
                "a pasted file path went somewhere other than its folder")
        #expect(row.title == "Legal")
        #expect(row.detail == "Enclosing folder of invoice.pdf",
                "the row does not say it is going to the folder rather than the file")
    }

    @Test func aPathWithNothingAtItSaysSoRatherThanOfferingItself() throws {
        let row = try #require(Self.row("~/Documents/Nope", probe: Probe()))
        #expect(row.unavailable == "No folder at that path")
        #expect(PaletteSelection.chosen(at: 0, in: [row]) == nil, "↩ would go nowhere and say nothing")
    }

    /// Still a refusal, for a reason the cross-source row doesn't have: it is about the
    /// configuration, and there is no source to switch to.
    @Test func aPathOutsideEverySourceNamesThatAsTheReason() throws {
        let row = try #require(Self.row("~/Downloads/Taxes", probe: Probe()))
        #expect(row.unavailable == "Not in any source")
        #expect(PaletteSelection.chosen(at: 0, in: [row]) == nil,
                "↩ runs a row that names no destination the app has")
    }

    /// A path in another mounted source is a live row that switches the pane and lands on the
    /// folder: runnable (`PaletteSelection.chosen` refuses any `unavailable`), with the owning
    /// source's id and the typed path.
    @Test func aPathInAnotherSourceSwitchesToThatSource() throws {
        let row = try #require(Self.row("~/Dropbox/Legal", probe: Probe()))
        #expect(row.isAvailable, "refused with: \(row.unavailable ?? "")")
        #expect(row.route == .folderInSource(providerId: "dropbox", path: "\(Self.dropbox)/Legal"),
                "got \(row.route)")
        // ↩ really runs it. `chosen` is the one gate between an offered row and the host.
        #expect(PaletteSelection.chosen(at: 0, in: [row])
                == .folderInSource(providerId: "dropbox", path: "\(Self.dropbox)/Legal"),
                "↩ on the row still goes nowhere")
    }

    /// The title names the source to switch to; the detail stays the bare path, since
    /// `PaletteResultsList` middle-truncates a detail with a `/` and so keeps the leaf visible.
    @Test func theSwitchRowNamesTheSourceInItsTitleAndKeepsThePathAsItsDetail() throws {
        let row = try #require(Self.row("~/Dropbox/Clients/Acme/2026", probe: Probe()))
        #expect(row.title == "Open in Dropbox",
                "the row does not say the pane is about to change source — got “\(row.title)”")
        #expect(row.detail == "\(Self.dropbox)/Clients/Acme/2026",
                "the detail is no longer the bare path, so the middle-truncation that keeps the leaf readable no longer applies to it")
        #expect(row.detail?.contains("/") == true,
                "the detail lost its slashes — the list would truncate it at the TAIL and eat the folder name")
    }

    /// The switch goes to the innermost owner (`PalettePath.owner`), asserted through the route the
    /// host acts on, with the pane on a third source that contains neither.
    @Test func theSwitchGoesToTheInnermostSourceThatOwnsThePath() throws {
        let inner = "\(Self.dropbox)/Clients"
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                                        isCurrent: true, root: Self.documents),
                        PaletteProvider(id: "dropbox", name: "Dropbox", isMounted: true,
                                        isCurrent: false, root: Self.dropbox),
                        PaletteProvider(id: "clients", name: "Clients", isMounted: true,
                                        isCurrent: false, root: inner)],
            providerRoot: Self.documents, folders: [], home: Self.home,
            isScanning: false, hasSurvey: true)
        let probe = Probe()
        let row = try #require(Self.row("~/Dropbox/Clients/Legal", probe: probe, index: index))
        #expect(row.route == .folderInSource(providerId: "clients", path: "\(inner)/Legal"),
                "the outer source claimed a path the inner one owns — got \(row.route)")
        #expect(row.title == "Open in Clients")
    }

    /// An unmounted source is a refusal, checked above the switch in `pathRow`: the pane can't be
    /// pointed at it. `theSwitchIsOfferedOnlyForAMountedOwner` is the other side.
    @Test func aPathInAnUnmountedSourceSaysTheSourceIsNotThere() throws {
        let row = try #require(Self.row("/Volumes/Backup/2019", probe: Probe()))
        #expect(row.unavailable == "Backup SSD is not mounted")
        #expect(PaletteSelection.chosen(at: 0, in: [row]) == nil,
                "↩ would switch the pane to a source that is not there")
    }

    /// The same fixture with the drive awake: the positive control for the test above, which would
    /// otherwise pass if the switch were never offered for any source.
    @Test func theSwitchIsOfferedOnlyForAMountedOwner() throws {
        let awake = [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                                     isCurrent: true, root: Self.documents),
                     PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: true,
                                     isCurrent: false, root: "/Volumes/Backup")]
        let index = PaletteIndex(providers: awake, providerRoot: Self.documents, folders: [],
                                 home: Self.home, isScanning: false, hasSurvey: true)
        let row = try #require(Self.row("/Volumes/Backup/2019", probe: Probe(), index: index))
        #expect(row.route == .folderInSource(providerId: "ssd", path: "/Volumes/Backup/2019"),
                "a mounted source the pane is not on is not offered as a switch — got \(row.route)")
    }

    // MARK: The root that decides it

    /// Deliverable is decided by `providerRoot`, what the reveal relativizes against, not the
    /// owner's `isCurrent`. Here no listed provider names the aimed root (a source that vanished
    /// can leave the panes on stale ids).
    @Test func aPathUnderTheAimedRootWorksEvenWhenNoListedSourceClaimsIt() throws {
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "dropbox", name: "Dropbox", isMounted: true,
                                        isCurrent: false, root: Self.dropbox)],
            providerRoot: Self.documents, folders: [], home: Self.home,
            isScanning: false, hasSurvey: true)
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(Self.row("~/Documents/Legal", probe: probe, index: index))
        #expect(row.isAvailable,
                "a path in the tree the pane is showing was refused with: \(row.unavailable ?? "") — the row and the reveal are asking two different roots")
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"))
    }

    /// The everyday case: `~/Documents` and `~/Documents/Clients` both sources, the pane on the
    /// outer. The owner of a path inside `Clients` is not current, so deciding on `isCurrent` would
    /// refuse a folder the pane can show.
    @Test func aPathInsideANestedSourceIsStillReachableFromTheOuterPane() throws {
        let inner = "\(Self.documents)/Clients"
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "docs", name: "Documents", isMounted: true,
                                        isCurrent: true, root: Self.documents),
                        PaletteProvider(id: "clients", name: "Clients", isMounted: true,
                                        isCurrent: false, root: inner)],
            providerRoot: Self.documents, folders: [], home: Self.home,
            isScanning: false, hasSurvey: true)
        let probe = Probe(directories: ["\(inner)/Legal"])
        let row = try #require(Self.row("~/Documents/Clients/Legal", probe: probe, index: index))
        #expect(row.isAvailable,
                "a folder inside the tree the pane is showing was refused with: \(row.unavailable ?? "") — a nested source claimed it and the check asked the wrong root")
        #expect(row.route == .folder(path: "\(inner)/Legal"))
    }

    /// A question mark claims the app doesn't know whether the folder exists, so only "No folder at
    /// that path" wears one; the other refusals and the switch row get a plain folder.
    @Test func onlyTheRefusalThatIsAboutExistenceWearsAQuestionMark() throws {
        let missing = try #require(Self.row("~/Documents/Nope", probe: Probe()))
        #expect(missing.symbol == "folder.badge.questionmark")
        for query in ["~/Downloads/Taxes", "/Volumes/Backup/2019"] {
            let row = try #require(Self.row(query, probe: Probe()))
            #expect(!row.isAvailable, "\(query) is no longer a refusal — this case moved")
            #expect(row.symbol == "folder",
                    "\(query) is badged as if the app did not know whether the folder exists, when the reason it gives is that it cannot be reached")
        }
        // The switch row too: it is offered without asking the disk.
        let switching = try #require(Self.row("~/Dropbox/Legal", probe: Probe()))
        #expect(switching.isAvailable, "the switch row went back to being a refusal")
        #expect(switching.symbol == "folder")
    }

    /// The aimed root asleep: the same wording every remembered folder carries, and no probe, since
    /// stat'ing a child of a root that didn't answer is the stall the ordering exists to avoid.
    @Test func aPathUnderAnAsleepAimedRootSaysWhatTheOtherFolderRowsSay() throws {
        let index = PaletteIndex(
            providers: Self.providers(), providerRoot: Self.documents, folders: [],
            foldersUnavailable: "Not available", home: Self.home,
            isScanning: false, hasSurvey: true)
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(Self.row("~/Documents/Legal", probe: probe, index: index))
        #expect(row.unavailable == "Not available")
        #expect(probe.asked.isEmpty,
                "a child of a root that did not answer was stat'ed — that is the stalled keystroke this ordering exists to avoid")
    }

    // MARK: The stall guard — what must NOT be asked

    /// **Never** probe outside the aimed source: the probe is a `stat` on the keystroke path, and a
    /// `stat` under an unreachable mount blocks (`FolderJumpStore.reachable`'s hazard). The switch
    /// row (`~/Dropbox/Legal`) is checked on ↩ in `ContentView.sourceSwitchOutcome`, off that path.
    /// Mutation: moving the `probe(typed)` switch above any of the three guards.
    @Test func theDiskIsNeverAskedAboutAPathOutsideTheAimedSource() {
        for query in ["~/Downloads/Taxes", "~/Dropbox/Legal", "/Volumes/Backup/2019"] {
            let probe = Probe()
            _ = Self.row(query, probe: probe)
            #expect(probe.asked.isEmpty,
                    "\(query) was stat'ed outside the aimed source — under a sleeping mount that is a stalled keystroke")
        }
        // …and the case that IS asked, so the assertions above are not passing because nothing runs.
        let live = Probe(directories: ["\(Self.documents)/Legal"])
        _ = Self.row("~/Documents/Legal", probe: live)
        #expect(live.asked == ["\(Self.documents)/Legal"],
                "the one path that should be checked was not, or was checked more than once")
    }

    /// No probe means no path row, not one taken on faith.
    @Test func withoutAProbeThereIsNoPathRowAtAll() {
        let rows = PaletteRouter.rows(query: "~/Documents/Legal", index: Self.index())
        #expect(!rows.contains { $0.id.hasPrefix("path.") },
                "a path row was offered by a caller that cannot say whether the folder is there")
    }

    // MARK: Where it sits

    /// A typed path is the most specific claim a query can make, so it leads, and ↩ lands on it
    /// without an arrow key.
    @Test func aTypedPathLeadsTheListAndIsWhatReturnRuns() throws {
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let rows = PaletteRouter.rows(query: "~/Documents/Legal", index: Self.index(), probe: probe.kind)
        #expect(rows.first?.id.hasPrefix("path.") == true, "the typed path is not the first row")
        let opening = try #require(PaletteSelection.initialIndex(in: rows))
        #expect(rows[opening].route == .folder(path: "\(Self.documents)/Legal"),
                "↩ on a freshly typed path runs something else")
    }

    /// A refusal and the row it becomes once the path is finished share an id, so the highlight
    /// doesn't jump as the user types.
    @Test func aRefusalAndItsFixedFormShareOneRow() throws {
        let missing = try #require(Self.row("~/Documents/Legal", probe: Probe()))
        let found = try #require(Self.row("~/Documents/Legal",
                                          probe: Probe(directories: ["\(Self.documents)/Legal"])))
        #expect(missing.id == found.id)
    }
}
