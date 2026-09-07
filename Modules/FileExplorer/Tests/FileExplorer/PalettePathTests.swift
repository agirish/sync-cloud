import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// **Go to Folder** — ROADMAP_V4 §3's small item, and §7's last open one.
///
/// Finder's ⇧⌘G as a behaviour rather than a surface: the ⌘K field takes a typed path. The whole
/// feature is one row, so most of this suite is about the cases where that row is a **refusal** —
/// which is the point of it rather than an edge. A path query used to produce an empty list, and an
/// empty list is the "nothing happened" this family of features exists to remove.
///
/// **RD7 (2026-09-06) turned one of the four refusals into a destination**: a path inside another
/// configured, mounted source is now a row that switches the pane to that source and lands on the
/// folder, routed as `.folderInSource`. The other three stay refusals, each for a reason the
/// switched one does not have, and the tests below say which is which.
@Suite struct PalettePathTests {

    static let home = "/Users/x"
    static let documents = "/Users/x/Documents"
    static let dropbox = "/Users/x/Dropbox"

    /// Two sources, one current — the shape the decisions were taken against. `Backup SSD` is the
    /// unmounted one the palette already carries elsewhere.
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

    /// A probe that answers from a set **and counts what it was asked**, because half of this
    /// feature's design is about what it must NOT ask. See `theDiskIsNeverAskedAboutAPathOutsideTheAimedSource`.
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

    /// **A leading `/` or `~`, never "contains a slash".** `Clients/Legal` is a relative folder
    /// *name* that `folderRows` already matches out of the survey; treating it as a path would
    /// resolve it against the process working directory and refuse it — replacing a row that works
    /// with one that cannot.
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
    /// **This test was written asserting something false and the failure is worth keeping.** The
    /// first version also expected `Clients/Legal` to match the survey's own `Clients/Legal` row —
    /// it does not, and nothing here changed that: `rankedFolders` normalises the slashes in the
    /// *candidate* (`Clients/Legal` → `Clients Legal`) and not in the query, so a query containing
    /// a slash matches no folder at all. That is a pre-existing gap in the name matcher rather than
    /// anything Go to Folder introduced, and it is deliberately left alone here — normalising the
    /// query too would change how every folder query ranks, which is not this feature's to decide.
    /// Recorded because the seam is now visible: `~/Documents/Clients/Legal` works and
    /// `Clients/Legal` finds nothing.
    @Test func aRelativeNameIsNotAPathAndTheDiskIsNotAskedAboutIt() {
        let probe = Probe()
        let rows = PaletteRouter.rows(query: "Clients/Legal", index: Self.index(), probe: probe.kind)
        #expect(!rows.contains { $0.id.hasPrefix("path.") },
                "a relative folder name was taken for a typed path — it would resolve against the process working directory")
        #expect(probe.asked.isEmpty, "the disk was asked about a query that is not a path")
    }

    // MARK: Resolving the string

    /// Surrounding whitespace is not part of a pasted path. Trimmed once, by `rows`, so the query
    /// the path rule sees is the query every other builder sees.
    @Test func surroundingWhitespaceIsIgnored() throws {
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let row = try #require(Self.row("  ~/Documents/Legal  ", probe: probe))
        #expect(row.route == .folder(path: "\(Self.documents)/Legal"))
    }

    /// A path row outranks the best possible name match, because it is a statement of intent rather
    /// than a guess at one — `exact` is 400 and this is 1,100.
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

    /// **`..` has to collapse before the source is decided.** Without it
    /// `~/Documents/../Dropbox` still has Documents' root as its prefix, so it would be claimed by
    /// that source and revealed inside it as the relative path `../Dropbox`.
    @Test func dotDotIsResolvedBeforeAnythingIsDecided() {
        let resolved = PalettePath.absolute("~/Documents/../Dropbox", home: Self.home)
        #expect(resolved == Self.dropbox, "got \(resolved)")
        #expect(PalettePath.owner(of: resolved, in: Self.providers())?.id == "dropbox",
                "the wrong source claimed a path that climbed out of it")
    }

    // MARK: Which source owns it

    /// **The innermost source wins.** Sources nest — `~/Documents` and `~/Documents/Clients` are
    /// both perfectly ordinary things to configure — and the outer one contains every path the
    /// inner one does, so taking the first match in settings order hands the path to whichever
    /// happened to be added first.
    @Test func theInnermostSourceClaimsAPathUnderBoth() {
        let nested = [PaletteProvider(id: "outer", name: "Documents", isMounted: true,
                                      isCurrent: true, root: Self.documents),
                      PaletteProvider(id: "inner", name: "Clients", isMounted: true,
                                      isCurrent: false, root: "\(Self.documents)/Clients")]
        #expect(PalettePath.owner(of: "\(Self.documents)/Clients/Legal", in: nested)?.id == "inner")
        #expect(PalettePath.owner(of: "\(Self.documents)/Legal", in: nested)?.id == "outer")
    }

    /// A source with no path configured must never claim anything — an empty root prefixes every
    /// absolute path, which is the empty-root hazard `PathBoundary.relativize` guards by name.
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

    /// **A pasted path is usually a file's** — that is what a Finder copy puts on the clipboard.
    /// Decided 2026-08-19: go to the enclosing folder, the way ⇧⌘G accepts a file, and say so on
    /// the row rather than silently landing somewhere the user did not type.
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

    /// **Still a refusal after RD7, and for a reason the cross-source row does not have**: this is
    /// a statement about the *configuration*, not a navigation the palette declined to perform.
    /// There is no source to switch to.
    @Test func aPathOutsideEverySourceNamesThatAsTheReason() throws {
        let row = try #require(Self.row("~/Downloads/Taxes", probe: Probe()))
        #expect(row.unavailable == "Not in any source")
        #expect(PaletteSelection.chosen(at: 0, in: [row]) == nil,
                "↩ runs a row that names no destination the app has")
    }

    /// **RD7: the refusal that named the fix became the fix.** Decided 2026-08-19 to refuse and
    /// name the source ("In Dropbox — switch source first"); shipped 2026-09-06 as a live row that
    /// switches the pane and lands on the folder, once the host learned to suppress the provider
    /// change's own navigation reset and drive the reload itself.
    ///
    /// The three things asserted here are the three ways this can silently stop working: the row
    /// has to be **runnable** (an `unavailable` of any wording puts it back where it was, because
    /// `PaletteSelection.chosen` reads that field and nothing else), it has to carry the
    /// **owning** source's id rather than the pane's, and it has to carry the typed path.
    @Test func aPathInAnotherSourceSwitchesToThatSource() throws {
        let row = try #require(Self.row("~/Dropbox/Legal", probe: Probe()))
        #expect(row.isAvailable, "refused with: \(row.unavailable ?? "")")
        #expect(row.route == .folderInSource(providerId: "dropbox", path: "\(Self.dropbox)/Legal"),
                "got \(row.route)")
        // ↩ really runs it, rather than the row merely looking live. `chosen` is the one gate
        // between an offered row and the host, and it is what refused this row for two releases.
        #expect(PaletteSelection.chosen(at: 0, in: [row])
                == .folderInSource(providerId: "dropbox", path: "\(Self.dropbox)/Legal"),
                "↩ on the row still goes nowhere")
    }

    /// **The row says which source it is about to switch to, and still says which folder.**
    ///
    /// The title changed from the leaf to a verb, so the leaf now lives only in the detail — and
    /// `PaletteResultsList` middle-truncates a detail containing a `/` for exactly that reason.
    /// A detail with anything appended to the path moves the leaf into the truncator's bite.
    @Test func theSwitchRowNamesTheSourceInItsTitleAndKeepsThePathAsItsDetail() throws {
        let row = try #require(Self.row("~/Dropbox/Clients/Acme/2026", probe: Probe()))
        #expect(row.title == "Open in Dropbox",
                "the row does not say the pane is about to change source — got “\(row.title)”")
        #expect(row.detail == "\(Self.dropbox)/Clients/Acme/2026",
                "the detail is no longer the bare path, so the middle-truncation that keeps the leaf readable no longer applies to it")
        #expect(row.detail?.contains("/") == true,
                "the detail lost its slashes — the list would truncate it at the TAIL and eat the folder name")
    }

    /// **The switch names the INNERMOST owner**, the same rule `PalettePath.owner` has always
    /// applied — asserted through the route rather than through `owner` alone, because the route
    /// is what the host acts on and the id is what crosses the wall.
    ///
    /// The fixture is a pane aimed at a source that contains NEITHER: `~/Dropbox` nests
    /// `~/Dropbox/Clients` and the pane is on `~/Documents`, so the path leaves the aimed root and
    /// both nested sources claim it. Handing it to the outer one would switch the pane to Dropbox
    /// and land it at `Clients/Legal` — the right folder by luck, and the wrong source the moment
    /// the two roots stop being ancestor and descendant.
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

    /// **Still a refusal after RD7**, and it is the check that stands in front of the switch: a
    /// source that is not mounted is one the pane cannot be pointed at at all, so "switch to it"
    /// is not an offer this palette can make. Ordered above the switch in `pathRow`, which is what
    /// `theSwitchIsOfferedOnlyForAMountedOwner` drives from the other side.
    @Test func aPathInAnUnmountedSourceSaysTheSourceIsNotThere() throws {
        let row = try #require(Self.row("/Volumes/Backup/2019", probe: Probe()))
        #expect(row.unavailable == "Backup SSD is not mounted")
        #expect(PaletteSelection.chosen(at: 0, in: [row]) == nil,
                "↩ would switch the pane to a source that is not there")
    }

    /// The same fixture with the drive awake — **the positive control for the test above.** Without
    /// it, "unmounted refuses" passes just as well if the switch is never offered for any source.
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

    /// **Deliverable is decided by `providerRoot`, because that is what the reveal relativizes
    /// against** — not by the owning provider's `isCurrent` flag.
    ///
    /// This fixture is the corner where no listed provider names the aimed root at all, which is
    /// reachable when `enabledProviders` goes empty: `canDisable` refuses to switch off the last
    /// source, but a source that disappears *afterwards* can still empty the list, and
    /// `resolvedProviderSelection` then returns nil and leaves the panes on their stale ids. The
    /// everyday case is `aPathInsideANestedSourceIsStillReachableFromTheOuterPane` below.
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

    /// **The case that made this fix worth making, and it is an ordinary configuration.**
    ///
    /// `~/Documents` and `~/Documents/Clients` are both reasonable sources to have, and
    /// `PalettePath.owner` answers with the **innermost** on purpose — it must, or a path deep
    /// inside the inner one would be handed to the outer, which is what
    /// `theInnermostSourceClaimsAPathUnderBoth` holds. So with the pane aimed at the outer source,
    /// the owner of a path inside `Clients` is a provider that is not current, and deciding on
    /// `isCurrent` refused a folder the pane on screen can show perfectly well.
    ///
    /// Two sources pointed at the *same* folder do this too — `SettingsManager` allows it for a
    /// re-pointed account — and the tie would go to whichever root happened to sort last.
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

    /// **A question mark is a claim about existence**, and only one of the refusals makes it.
    /// Badging "Backup SSD is not mounted" with one says the app does not know whether the folder
    /// is there, which is both wrong and a different thing from what the row says in words.
    ///
    /// **`~/Dropbox/Legal` left this list at RD7** — it is a live row now, not a refusal — and it
    /// is asserted separately below rather than dropped, because the same argument applies to it
    /// with more force: the row is offered without the disk having been asked at all.
    @Test func onlyTheRefusalThatIsAboutExistenceWearsAQuestionMark() throws {
        let missing = try #require(Self.row("~/Documents/Nope", probe: Probe()))
        #expect(missing.symbol == "folder.badge.questionmark")
        for query in ["~/Downloads/Taxes", "/Volumes/Backup/2019"] {
            let row = try #require(Self.row(query, probe: Probe()))
            #expect(!row.isAvailable, "\(query) is no longer a refusal — this case moved")
            #expect(row.symbol == "folder",
                    "\(query) is badged as if the app did not know whether the folder exists, when the reason it gives is that it cannot be reached")
        }
        // The switch row: a folder glyph, because nothing here knows whether the folder exists —
        // and a question mark on a row that is about to be RUN would be the app asking the user
        // a question it is not going to wait for the answer to.
        let switching = try #require(Self.row("~/Dropbox/Legal", probe: Probe()))
        #expect(switching.isAvailable, "the switch row went back to being a refusal")
        #expect(switching.symbol == "folder")
    }

    /// The aimed root itself asleep: the same wording every remembered folder already carries, and
    /// **no probe** — a child of a root that did not answer is the stall the ordering exists for.
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

    /// **Every row decided outside the aimed source is reached without touching the disk, and that
    /// ordering is the feature's safety rather than its style.** The probe is a `stat`, it runs on
    /// the keystroke path, and a
    /// `stat` under an unreachable mount blocks — the hazard `FolderJumpStore.reachable` is built
    /// around. So a path is only ever probed once it is known to be inside a source that is mounted
    /// and already showing.
    ///
    /// Mutation: move the `probe(typed)` switch above any of the three guards and this fails naming
    /// the path that was asked about.
    ///
    /// **RD7 made the third of these a live row and did NOT move it out of this list**, which is
    /// the more interesting half now: `~/Dropbox/Legal` is offered as a switch *without* the disk
    /// being asked whether the folder is there, because probing a source the pane is not showing
    /// has no `foldersUnavailable` standing in front of it the way the aimed root does. The
    /// existence question moves to ↩ — `ContentView.sourceSwitchOutcome`, off the keystroke path —
    /// and this is what stops it creeping back onto the keystroke.
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

    /// No probe means no path row — **not a path row taken on faith.** A default answering "yes, it
    /// is there" would be a fixture whose expected value is its own fallback.
    @Test func withoutAProbeThereIsNoPathRowAtAll() {
        let rows = PaletteRouter.rows(query: "~/Documents/Legal", index: Self.index())
        #expect(!rows.contains { $0.id.hasPrefix("path.") },
                "a path row was offered by a caller that cannot say whether the folder is there")
    }

    // MARK: Where it sits

    /// A typed path is the most specific claim a query can make — nothing was inferred from it — so
    /// it leads, and ↩ lands on it without an arrow key.
    @Test func aTypedPathLeadsTheListAndIsWhatReturnRuns() throws {
        let probe = Probe(directories: ["\(Self.documents)/Legal"])
        let rows = PaletteRouter.rows(query: "~/Documents/Legal", index: Self.index(), probe: probe.kind)
        #expect(rows.first?.id.hasPrefix("path.") == true, "the typed path is not the first row")
        let opening = try #require(PaletteSelection.initialIndex(in: rows))
        #expect(rows[opening].route == .folder(path: "\(Self.documents)/Legal"),
                "↩ on a freshly typed path runs something else")
    }

    /// A refusal and the row it becomes once the path is finished are the **same** row, so the
    /// highlight does not jump around as the user types.
    @Test func aRefusalAndItsFixedFormShareOneRow() throws {
        let missing = try #require(Self.row("~/Documents/Legal", probe: Probe()))
        let found = try #require(Self.row("~/Documents/Legal",
                                          probe: Probe(directories: ["\(Self.documents)/Legal"])))
        #expect(missing.id == found.id)
    }
}
