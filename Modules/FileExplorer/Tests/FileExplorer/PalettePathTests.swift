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
    /// feature's design is about what it must NOT ask. See `theDiskIsNeverAskedAboutAPathThatIsRefusedAnyway`.
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

    @Test func aPathOutsideEverySourceNamesThatAsTheReason() throws {
        let row = try #require(Self.row("~/Downloads/Taxes", probe: Probe()))
        #expect(row.unavailable == "Not in any source")
    }

    /// Decided 2026-08-19: refuse and **name the source**, rather than switching to it. Switching
    /// means suppressing the provider change's own navigation reset and driving the reload, or the
    /// pane lands at the root with the folder silently dropped — deferred to v4.3 (ROADMAP_V4 §3).
    @Test func aPathInAnotherSourceNamesTheSourceToSwitchTo() throws {
        let row = try #require(Self.row("~/Dropbox/Legal", probe: Probe()))
        #expect(row.unavailable == "In Dropbox — switch source first")
    }

    @Test func aPathInAnUnmountedSourceSaysTheSourceIsNotThere() throws {
        let row = try #require(Self.row("/Volumes/Backup/2019", probe: Probe()))
        #expect(row.unavailable == "Backup SSD is not mounted")
    }

    // MARK: The stall guard — what must NOT be asked

    /// **Every refusal is reached without touching the disk, and that ordering is the feature's
    /// safety rather than its style.** The probe is a `stat`, it runs on the keystroke path, and a
    /// `stat` under an unreachable mount blocks — the hazard `FolderJumpStore.reachable` is built
    /// around. So a path is only ever probed once it is known to be inside a source that is mounted
    /// and already showing.
    ///
    /// Mutation: move the `probe(typed)` switch above any of the three guards and this fails naming
    /// the path that was asked about.
    @Test func theDiskIsNeverAskedAboutAPathThatIsRefusedAnyway() {
        for query in ["~/Downloads/Taxes", "~/Dropbox/Legal", "/Volumes/Backup/2019"] {
            let probe = Probe()
            _ = Self.row(query, probe: probe)
            #expect(probe.asked.isEmpty,
                    "\(query) was stat'ed before being refused — under a sleeping mount that is a stalled keystroke")
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
