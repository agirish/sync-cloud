import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// Go to Folder: Finder's ⇧⌘G as a behaviour, not a surface. The ⌘K field takes a typed path and
/// answers with one row, so most of this suite is about the cases where that row is a refusal. An
/// empty list would be the "nothing happened" this family of features exists to remove.
///
/// A path inside another configured, mounted source is a live row that switches the pane to that
/// source and lands on the folder (`.folderInSource`). The other three cases stay refusals, each
/// for a reason the switch doesn't have, and the tests below say which is which.
@Suite struct PalettePathTests {

    static let home = "/Users/x"
    static let documents = "/Users/x/Documents"
    static let dropbox = "/Users/x/Dropbox"

    /// Two sources, one current. `Backup SSD` is the unmounted one the palette carries elsewhere.
    static func providers(currentIsDocuments: Bool = true) -> [PaletteProvider] {
        [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true,
                         isCurrent: currentIsDocuments, root: documents),
         PaletteProvider(id: "dropbox", name: "Dropbox", isMounted: true,
                         isCurrent: !currentIsDocuments, root: dropbox),
         PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: false,
                         isCurrent: false, root: "/Volumes/Backup")]
    }

    static func index(currentIsDocuments: Bool = true) -> PaletteIndex {
        PaletteIndex(providers: providers(currentIsDocuments: currentIsDocuments),
                     providerRoot: documents, folders: ["Legal", "Clients/Legal"],
                     home: home, isScanning: false, hasSurvey: true)
    }

    /// A probe that answers from a set and records what it was asked, because half this feature's
    /// design is about what it must not ask. See
    /// `theDiskIsNeverAskedAboutAPathOutsideTheAimedSource`.
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

    static func row(_ query: String, probe: Probe, currentIsDocuments: Bool = true) -> PaletteRow? {
        PaletteRouter.rows(query: query, index: index(currentIsDocuments: currentIsDocuments),
                           probe: probe.kind)
            .first { $0.id.hasPrefix("path.") }
    }

    // MARK: What counts as a path at all

    /// A leading `/` or `~`, never "contains a slash". `Clients/Legal` is a relative folder name
    /// that `folderRows` already matches from the survey; treated as a path it would resolve
    /// against the process working directory and be refused, replacing a row that works with one
    /// that can't.
    @Test func onlyALeadingSlashOrTildeIsAPath() {
        #expect(PalettePath.looksLikeAPath("/Users/x/Documents/Legal"))
        #expect(PalettePath.looksLikeAPath("~/Documents/Legal"))
        #expect(PalettePath.looksLikeAPath("~"))
        #expect(!PalettePath.looksLikeAPath("Clients/Legal"))
        #expect(!PalettePath.looksLikeAPath("legal"))
        #expect(!PalettePath.looksLikeAPath(""))
    }

    /// A relative name is not a path, and the disk is not asked about it.
    ///
    /// A query with a slash matches no folder at all: `rankedFolders` normalises slashes in the
    /// candidate (`Clients/Legal` → `Clients Legal`) but not in the query. That gap is the name
    /// matcher's, left alone because normalising the query would change how every folder query
    /// ranks. So `~/Documents/Clients/Legal` works and `Clients/Legal` finds nothing.
    @Test func aRelativeNameIsNotAPathAndTheDiskIsNotAskedAboutIt() {
        let probe = Probe()
        let rows = PaletteRouter.rows(query: "Clients/Legal", index: Self.index(), probe: probe.kind)
        #expect(!rows.contains { $0.id.hasPrefix("path.") },
                "a relative folder name was taken for a typed path — it would resolve against the process working directory")
        #expect(probe.asked.isEmpty, "the disk was asked about a query that is not a path")
    }

    // MARK: Resolving the string

    /// Surrounding whitespace is not part of a pasted path. Trimmed once, by `rows`, so the path
    /// rule sees the same query as every other builder.
    @Test func surroundingWhitespaceIsIgnored() throws {
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(Self.row("  ~/Documents/Legal  ", probe: probe))
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"))
    }

    /// A path row outranks the best possible name match, because it states intent rather than
    /// guessing at it.
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

    /// `..` has to collapse before the source is decided. Otherwise `~/Documents/../Dropbox` still
    /// has Documents' root as its prefix, and would be revealed inside it as the relative path
    /// `../Dropbox`.
    @Test func dotDotIsResolvedBeforeAnythingIsDecided() {
        let resolved = PalettePath.absolute("~/Documents/../Dropbox", home: Self.home)
        #expect(resolved == Self.dropbox, "got \(resolved)")
        #expect(PalettePath.owner(of: resolved, in: Self.providers())?.id == "dropbox",
                "the wrong source claimed a path that climbed out of it")
    }

    // MARK: Which source owns it

    /// The innermost source wins. Sources nest (`~/Documents` and `~/Documents/Clients` are both
    /// ordinary to configure), and the outer contains every path the inner does, so the first match
    /// in settings order would hand the path to whichever was added first.
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

    /// A pasted path is usually a file's, since that is what a Finder copy puts on the clipboard.
    /// It goes to the enclosing folder, as ⇧⌘G does, and the row says so rather than landing
    /// somewhere the user didn't type.
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
    /// folder. The host suppresses the provider change's own navigation reset and drives the reload
    /// itself.
    ///
    /// Asserts the three ways this can silently stop working: the row must be runnable (any
    /// `unavailable` makes `PaletteSelection.chosen` refuse it, since that is the field it reads),
    /// it must carry the owning source's id rather than the pane's, and it must carry the typed
    /// path.
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

    /// The row says which source it is about to switch to, and still says which folder. The title
    /// is a verb, so the leaf lives only in the detail, and `PaletteResultsList` middle-truncates a
    /// detail containing a `/` to keep it visible. Anything appended to the path would put the leaf
    /// in the truncator's bite.
    @Test func theSwitchRowNamesTheSourceInItsTitleAndKeepsThePathAsItsDetail() throws {
        let row = try #require(Self.row("~/Dropbox/Clients/Acme/2026", probe: Probe()))
        #expect(row.title == "Open in Dropbox",
                "the row does not say the pane is about to change source — got “\(row.title)”")
        #expect(row.detail == "\(Self.dropbox)/Clients/Acme/2026",
                "the detail is no longer the bare path, so the middle-truncation that keeps the leaf readable no longer applies to it")
        #expect(row.detail?.contains("/") == true,
                "the detail lost its slashes — the list would truncate it at the TAIL and eat the folder name")
    }

    /// The switch names the innermost owner, the rule `PalettePath.owner` applies, asserted through
    /// the route because the route is what the host acts on.
    ///
    /// The pane is aimed at a source that contains neither: `~/Dropbox` nests `~/Dropbox/Clients`
    /// and the pane is on `~/Documents`. Handing the path to the outer source would land on the
    /// right folder only while the two roots stay ancestor and descendant.
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
        let row = try #require(PaletteRouter.rows(query: "~/Dropbox/Clients/Legal", index: index,
                                                  probe: probe.kind)
            .first { $0.id.hasPrefix("path.") })
        #expect(row.route == .folderInSource(providerId: "clients", path: "\(inner)/Legal"),
                "the outer source claimed a path the inner one owns — got \(row.route)")
        #expect(row.title == "Open in Clients")
    }

    /// Still a refusal, and the check in front of the switch: an unmounted source is one the pane
    /// can't be pointed at, so "switch to it" is not an offer to make. Ordered above the switch in
    /// `pathRow`; `theSwitchIsOfferedOnlyForAMountedOwner` drives it from the other side.
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
        let row = try #require(PaletteRouter.rows(query: "/Volumes/Backup/2019", index: index,
                                                  probe: Probe().kind)
            .first { $0.id.hasPrefix("path.") })
        #expect(row.route == .folderInSource(providerId: "ssd", path: "/Volumes/Backup/2019"),
                "a mounted source the pane is not on is not offered as a switch — got \(row.route)")
    }

    // MARK: The root that decides it

    /// Deliverable is decided by `providerRoot`, because that is what the reveal relativizes
    /// against, not by the owning provider's `isCurrent` flag.
    ///
    /// The corner where no listed provider names the aimed root at all. `canDisable` refuses to
    /// switch off the last source, but one that disappears afterwards can still empty
    /// `enabledProviders`, and `resolvedProviderSelection` then returns nil and leaves the panes on
    /// stale ids. The everyday case is `aPathInsideANestedSourceIsStillReachableFromTheOuterPane`
    /// below.
    @Test func aPathUnderTheAimedRootWorksEvenWhenNoListedSourceClaimsIt() throws {
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "dropbox", name: "Dropbox", isMounted: true,
                                        isCurrent: false, root: Self.dropbox)],
            providerRoot: Self.documents, folders: [], home: Self.home,
            isScanning: false, hasSurvey: true)
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(PaletteRouter.rows(query: "~/Documents/Legal", index: index,
                                                  probe: probe.kind)
            .first { $0.id.hasPrefix("path.") })
        #expect(row.isAvailable,
                "a path in the tree the pane is showing was refused with: \(row.unavailable ?? "") — the row and the reveal are asking two different roots")
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"))
    }

    /// The ordinary configuration this rule matters for: `~/Documents` and `~/Documents/Clients`
    /// both as sources. `PalettePath.owner` answers with the innermost (as
    /// `theInnermostSourceClaimsAPathUnderBoth` holds), so with the pane on the outer source, the
    /// owner of a path inside `Clients` is not current. Deciding on `isCurrent` would refuse a
    /// folder the pane on screen can show.
    ///
    /// Two sources pointed at the same folder do this too (`SettingsManager` allows it for a
    /// re-pointed account), and the tie would go to whichever root sorted last.
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
        let row = try #require(PaletteRouter.rows(query: "~/Documents/Clients/Legal", index: index,
                                                  probe: probe.kind)
            .first { $0.id.hasPrefix("path.") })
        #expect(row.isAvailable,
                "a folder inside the tree the pane is showing was refused with: \(row.unavailable ?? "") — a nested source claimed it and the check asked the wrong root")
        #expect(row.route == .folder(path: "\(inner)/Legal"))
    }

    /// A question mark is a claim about existence, and only one of the refusals makes it. Badging
    /// "Backup SSD is not mounted" with one would say the app doesn't know whether the folder is
    /// there, which is wrong and not what the row says in words.
    ///
    /// The cross-source switch row is asserted separately: the same argument applies with more
    /// force, since it is offered without the disk being asked at all.
    @Test func onlyTheRefusalThatIsAboutExistenceWearsAQuestionMark() throws {
        let missing = try #require(Self.row("~/Documents/Nope", probe: Probe()))
        #expect(missing.symbol == "folder.badge.questionmark")
        for query in ["~/Downloads/Taxes", "/Volumes/Backup/2019"] {
            let row = try #require(Self.row(query, probe: Probe()))
            #expect(!row.isAvailable, "\(query) is no longer a refusal — this case moved")
            #expect(row.symbol == "folder",
                    "\(query) is badged as if the app did not know whether the folder exists, when the reason it gives is that it cannot be reached")
        }
        // The switch row: a plain folder glyph. A question mark on a row about to be run would ask
        // the user a question the app won't wait for.
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
        let row = try #require(PaletteRouter.rows(query: "~/Documents/Legal", index: index,
                                                  probe: probe.kind)
            .first { $0.id.hasPrefix("path.") })
        #expect(row.unavailable == "Not available")
        #expect(probe.asked.isEmpty,
                "a child of a root that did not answer was stat'ed — that is the stalled keystroke this ordering exists to avoid")
    }

    // MARK: The stall guard — what must NOT be asked

    /// Every row decided outside the aimed source is reached without touching the disk, and that
    /// ordering is the feature's safety. The probe is a `stat` on the keystroke path, and a `stat`
    /// under an unreachable mount blocks (the hazard `FolderJumpStore.reachable` is built around).
    /// So a path is probed only once it is known to be inside a mounted source the pane is showing.
    ///
    /// Fails, naming the path asked about, if the `probe(typed)` switch moves above any of the
    /// three guards.
    ///
    /// `~/Dropbox/Legal` is a live row and stays on this list: it is offered as a switch without
    /// asking the disk, because a source the pane isn't showing has no `foldersUnavailable` in
    /// front of it the way the aimed root does. The existence check happens on ↩, in
    /// `ContentView.sourceSwitchOutcome`, off the keystroke path; this keeps it there.
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

    /// No probe means no path row, not one taken on faith: a default answering "it is there" would
    /// make the fixture's expected value its own fallback.
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

    /// A refusal and the row it becomes once the path is finished are the same row, so the
    /// highlight doesn't jump as the user types.
    @Test func aRefusalAndItsFixedFormShareOneRow() throws {
        let missing = try #require(Self.row("~/Documents/Legal", probe: Probe()))
        let found = try #require(Self.row("~/Documents/Legal",
                                          probe: Probe(directories: ["\(Self.documents)/Legal"])))
        #expect(missing.id == found.id)
    }
}
