import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The differences header's ladder, now that the rung is **computed** rather than searched.
///
/// `standardHeader` used to hand six candidate toolbars to `ViewThatFits` and let it build every one
/// to measure it. `HeaderLadder` replaces that search with arithmetic, so the load-bearing claim is
/// no longer "the layout engine will work it out" but "these numbers describe the row that is
/// actually drawn". This suite checks that claim two ways, and neither of them compares a constant
/// against another constant:
///
/// - **Per rung**: the width `HeaderLadder` computes is the width the row laid out at that rung
///   actually occupies (`NSHostingView.fittingSize`).
/// - **End to end**: at every width across a sweep, the row the computed rung produces is
///   *pixel-identical* to the row the old six-child `ViewThatFits` chose. The old ladder is rebuilt
///   here rather than kept in production, which is what makes this a genuine before/after oracle in
///   one process — the same trick `PaneBarLadderTests` uses, where the searched ladder survives in
///   the app for the no-provider header.
///
/// Controls are located by `_FocusRingView`, the handle `PaneBarLadderTests` reaches for: a SwiftUI
/// `Button` with a custom style draws into a layer and puts no `NSControl` in the AppKit tree, and an
/// offscreen `NSHostingView` has an empty accessibility tree.
///
/// **Every hosting view here gets a real window.** Measured while calibrating `LabelMetrics`: a
/// detached `NSHostingView` mis-measures SF Symbols in both directions (19.0 against 17.5 for
/// `checklist`), so a suite without one would fail against correct numbers.
/// `.oneMountedDifferencesTable`, though nothing here mounts a whole `DifferencesView`: this suite
/// hosts more views than any other in the target, and that trait's job is to stop the priciest
/// main-actor work stacking up and starving the runloop deadlines the mounting suites wait on. It is
/// the "fourth mounting suite only has to add it to its declaration" case that trait was written for.
/// `.machinePinned(.pixelSampling)` for the same reason `PaneBarLadderTests` is: every assertion
/// here reads laid-out geometry back out of a live renderer, so a different Mac fails it for machine
/// reasons rather than code reasons.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable, .machinePinned(.pixelSampling))
struct HeaderLadderTests {

    // MARK: - Fixtures

    /// A comparison whose header has something in every slot: both directions non-empty, verifiable
    /// items for Verify, and enough folders to offer the fold-all toggle.
    private func differences(toRight: Int = 12, toLeft: Int = 5, verifiable: Int = 4,
                             folders: [String] = ["Documents", "Photos", "Projects"]) -> [FileDifference] {
        var rows: [FileDifference] = []
        for index in 0..<toRight {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/right-\(index).txt",
                leftItemPath: "/left/right-\(index).txt", rightItemPath: "/right/right-\(index).txt",
                type: .missingOnRight, action: .copyToRight,
                description: "Only on the left", leftFileSize: 1024))
        }
        for index in 0..<toLeft {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/left-\(index).txt",
                leftItemPath: "/left/left-\(index).txt", rightItemPath: "/right/left-\(index).txt",
                type: .missingOnLeft, action: .copyToLeft,
                description: "Only on the right", rightFileSize: 2048))
        }
        for index in 0..<verifiable {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/dates-\(index).txt",
                leftItemPath: "/left/dates-\(index).txt", rightItemPath: "/right/dates-\(index).txt",
                type: .differentDates, action: .copyToRight,
                description: "Different dates", leftFileSize: 4096, rightFileSize: 4096))
        }
        return rows
    }

    /// The dressings the count pill can wear. Each changes the pill's width, so the ladder has to
    /// price all three: no scan yet, a fresh age run, and a stale one — which wears an inset capsule
    /// worth `2 × 6pt` more than the bare run.
    private static func dressings() -> [(name: String, value: DifferencesView.CountPillDressing)] {
        let accent = SemanticCapsuleStyle.onAccent(fill: .blue, label: .white)
        return [
            ("pre-scan", .init(semantic: accent, detailStyle: nil, detail: nil,
                               spokenDetail: nil, help: nil)),
            ("fresh", .init(semantic: accent, detailStyle: nil, detail: "29m ago",
                            spokenDetail: "29m ago", help: "Last scanned 10:15:00")),
            ("stale", .init(semantic: accent, detailStyle: .of(.attention, .light), detail: "3h ago",
                            spokenDetail: "3h ago", help: "This comparison may be out of date")),
            ("scanning", .init(semantic: accent, detailStyle: .of(.neutral, .light),
                               detail: "scanning…", spokenDetail: "scanning for changes",
                               help: "Scanning for changes…")),
        ]
    }

    /// Pane names of very different lengths — the transfer buttons' destinations, and therefore the
    /// single biggest lever on where the rungs sit.
    private static let paneNamePairs: [(String, String)] = [
        ("Left", "Right"),
        ("iCloud Drive", "Dropbox"),
        ("OneDrive — Personal", "Google Drive — abhishek@example.com"),
    ]

    /// A view whose state is the header's defaults. `@State` reads its initial value when the row is
    /// hosted without its owning view, which is exactly the snapshot `facts(...)` below describes.
    private func view(rows: [FileDifference],
                      names: PaneProviderNames,
                      hasScanned: Bool = true) -> DifferencesView {
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = hasScanned
        manager.leftItemCount = 1_284
        manager.rightItemCount = 976
        return DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                               paneNames: names, isCollapsed: .constant(false))
    }

    /// The facts the row about to be rendered really has. Built from the same values the row draws
    /// with rather than by hand, so a fixture cannot describe a header the test is not rendering.
    private func facts(rows: [FileDifference], names: PaneProviderNames,
                       dressing: DifferencesView.CountPillDressing,
                       targets: DifferenceActionTargets,
                       sections: [DifferenceGrouping.Section],
                       itemCounts: String? = nil,
                       hasScanned: Bool = true) -> HeaderLadder.Facts {
        HeaderLadder.Facts(
            differencesCount: rows.count,
            detail: dressing.detail,
            detailIsCapsuled: dressing.detailStyle != nil,
            chevronSymbol: CountPillChevron.symbol(hasScanned: hasScanned, expanded: false),
            itemCountsText: itemCounts,
            sectionCount: sections.count,
            filterName: DifferenceFilter.all.displayName(leftName: names.left, rightName: names.right),
            isSelectionScoped: targets.isSelectionScoped,
            targetCount: targets.targets.count,
            verifiableCount: targets.verifiableCount,
            copyToLeftCount: targets.copyToLeftCount,
            copyToRightCount: targets.copyToRightCount,
            reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
            leftName: names.left, rightName: names.right,
            isMove: false,
            showsCollapseToggle: true)
    }

    // MARK: - Rendering

    /// Hosts `view` under the header card's own chrome, in a real window, at `width` if given.
    private func host<V: View>(_ view: V, width: CGFloat? = nil) -> NSHostingView<AnyView> {
        var root = AnyView(view.modifier(HeaderCardChrome(tint: .blue)))
        if let width { root = AnyView(root.frame(width: width)) }
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: width ?? 4_000, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Every `_FocusRingView` in the laid-out row, as a stable string. This is the "what got drawn"
    /// signal: two rows with the same fingerprint drew the same controls in the same places.
    private func fingerprint(_ host: NSView) -> String {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") {
                found.append(v.convert(v.bounds, to: host))
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        return found
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded()))/"
                 + "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            .joined(separator: " ")
    }

    // MARK: - The arithmetic against the drawn row

    /// The claim the whole change rests on: the width `HeaderLadder` computes for a rung is the width
    /// the row drawn at that rung actually occupies.
    ///
    /// Swept over every rung, every count-pill dressing and every pane-name pair, because the widths
    /// that move the rungs are exactly the ones those fixtures vary.
    @Test func everyRungMeasuresWhatItDraws() {
        var failures: [String] = []
        var checked = 0
        for (leftName, rightName) in Self.paneNamePairs {
            let names = PaneProviderNames(leftName: leftName, rightName: rightName)
            let rows = differences()
            let view = view(rows: rows, names: names)
            let targets = DifferenceActionTargets(filtered: rows, selection: [])
            let sections = DifferenceGrouping.sections(rows)
            for (dressingName, dressing) in Self.dressings() {
                let ladder = HeaderLadder(
                    facts: facts(rows: rows, names: names, dressing: dressing,
                                 targets: targets, sections: sections),
                    scale: 1)
                for rung in DifferencesView.renderedCompactionLadder {
                    let drawn = host(view.standardHeaderRow(rung, facts: ladder.facts,
                                                            dressing: dressing,
                                                            targets: targets, sorted: rows,
                                                            sections: sections)).fittingSize.width
                    checked += 1
                    if ladder.width(of: rung) != drawn {
                        failures.append("\(leftName)/\(rightName) \(dressingName) \(rung): "
                                        + "computed \(ladder.width(of: rung))pt, drew \(drawn)pt")
                    }

                }
            }
        }
        #expect(checked == Self.paneNamePairs.count * Self.dressings().count
                * DifferencesView.renderedCompactionLadder.count)
        let report = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "\(failures.count) rung(s) mispriced:\n\(report)")
    }

    /// The same claim at the other three font scales. Split from the case above so a failure names
    /// the scale rather than being buried in a 96-case sweep.
    @Test(arguments: [FontSize.small, .large, .extraLarge])
    func everyRungMeasuresWhatItDrawsAtOtherFontScales(size: FontSize) {
        let scale = size.scale
        let names = PaneProviderNames(leftName: "iCloud Drive", rightName: "Dropbox")
        let rows = differences()
        let view = view(rows: rows, names: names)
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        var failures: [String] = []
        for (dressingName, dressing) in Self.dressings() {
            let ladder = HeaderLadder(facts: facts(rows: rows, names: names, dressing: dressing,
                                                   targets: targets, sections: sections),
                                      scale: scale)
            for rung in DifferencesView.renderedCompactionLadder {
                let row = view.standardHeaderRow(rung, facts: ladder.facts, dressing: dressing,
                                                 targets: targets, sorted: rows, sections: sections)
                let drawn = host(row.appFontSize(size)).fittingSize.width
                if ladder.width(of: rung) != drawn {
                    failures.append("\(dressingName) \(rung): computed \(ladder.width(of: rung))pt, "
                                    + "drew \(drawn)pt")
                }
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "at scale \(scale), \(failures.count) rung(s) mispriced:\n\(report)")
    }

    /// Two runs the everyday fixture is too small to exercise, each of which the arithmetic got
    /// wrong before this case existed:
    ///
    /// - **A four-figure count.** The Review button interpolates its count plainly (`Review 1284`)
    ///   while the count pill beside it formats (`1,284`). Pricing Review with `.formatted()` looked
    ///   obviously right and is 4pt too wide — invisible below a thousand targets, which is where
    ///   every other fixture here sits, and routine on a real comparison.
    /// - **The expanded per-side totals.** That readout is the one run whose text comes from view
    ///   state rather than from the data, so it is only measurable at all because the row is handed
    ///   the same `facts` the ladder was priced from.
    @Test func aLargeComparisonWithTheTotalsExpandedIsPricedExactly() {
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        let rows = differences(toRight: 1_284, toLeft: 976, verifiable: 431)
        let view = view(rows: rows, names: names)
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        #expect(targets.targets.count > 999, "the fixture has to cross the thousands separator")

        for (dressingName, dressing) in Self.dressings() {
            for totals in [nil, "1,284 OneDrive — Personal · 976 iCloud Drive"] as [String?] {
                let ladder = HeaderLadder(
                    facts: facts(rows: rows, names: names, dressing: dressing, targets: targets,
                                 sections: sections, itemCounts: totals),
                    scale: 1)
                for rung in DifferencesView.renderedCompactionLadder {
                    let drawn = host(view.standardHeaderRow(rung, facts: ladder.facts,
                                                            dressing: dressing, targets: targets,
                                                            sorted: rows, sections: sections))
                        .fittingSize.width
                    let note = "\(dressingName) \(rung) totals=\(totals != nil): "
                        + "computed \(ladder.width(of: rung))pt, drew \(drawn)pt"
                    #expect(ladder.width(of: rung) == drawn, "\(note)")
                }
            }
        }
    }

    /// The states every other case in this suite leaves at their defaults — and each is a whole
    /// control, or a whole label vocabulary, that nothing else here measures.
    ///
    /// Written after noticing that every fixture above passes `selection: []`, so `isSelectionScoped`
    /// was false in all of them and `widths.selectionChip` was priced by code no test had ever
    /// executed. The same held for the Move labels (`isMove` is only ever true while ⇧/⌘ is held),
    /// for the pre-scan pill (which withholds its chevron), for a comparison with nothing in it, for
    /// an ungrouped table (no fold-all toggle), and for a host that binds no collapse state.
    ///
    /// Swept as a matrix rather than as one case each, because the interesting failures are
    /// interactions — a selection chip present at the same time as a folded overflow, say.
    @Test func everyHeaderStateIsPricedExactly() {
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        var failures: [String] = []
        var checked = 0

        // (label, rows, scope the selection?, ⇧ held?, group into sections?, bind collapse?, scanned?)
        let states: [(String, [FileDifference], Bool, Bool, Bool, Bool, Bool)] = [
            ("selection-scoped",     differences(),                                true,  false, true,  true,  true),
            ("move modifier",        differences(),                                false, true,  true,  true,  true),
            ("scoped + move",        differences(),                                true,  true,  true,  true,  true),
            ("nothing to sync",      [],                                           false, false, false, true,  true),
            ("one-way only",         differences(toRight: 9, toLeft: 0, verifiable: 0), false, false, true,  true,  true),
            ("reverse-only",         differences(toRight: 0, toLeft: 9, verifiable: 0), false, false, true,  true,  true),
            ("reverse is majority",  differences(toRight: 2, toLeft: 40, verifiable: 0), false, false, true,  true,  true),
            ("nothing verifiable",   differences(toRight: 6, toLeft: 3, verifiable: 0), false, false, true,  true,  true),
            ("ungrouped (no folds)", differences(),                                false, false, false, true,  true),
            ("no collapse binding",  differences(),                                false, false, true,  false, true),
            ("pre-scan",             differences(),                                false, false, true,  true,  false),
        ]

        for (label, rows, scoped, isMove, grouped, binds, scanned) in states {
            let manager = FileSyncManager()
            manager.differences = rows
            manager.hasScanned = scanned
            let view = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                                       paneNames: names,
                                       isCollapsed: binds ? .constant(false) : nil)
            // A real selection, resolved against the visible rows the way the header resolves it —
            // `DifferenceActionTargets` falls back to the whole filtered set if the ids miss, which
            // would silently un-scope the fixture.
            let selection = scoped ? Set(rows.prefix(3).map(\.id)) : Set<FileDifference.ID>()
            let targets = DifferenceActionTargets(filtered: rows, selection: selection)
            #expect(targets.isSelectionScoped == scoped,
                    "\(label): fixture failed to scope the selection — the case would be vacuous")
            let sections = grouped ? DifferenceGrouping.sections(rows) : []

            for (dressingName, dressing) in Self.dressings() {
                var f = facts(rows: rows, names: names, dressing: dressing, targets: targets,
                              sections: sections, hasScanned: scanned)
                f.isMove = isMove
                f.showsCollapseToggle = binds
                let ladder = HeaderLadder(facts: f, scale: 1)
                for rung in DifferencesView.renderedCompactionLadder {
                    let drawn = host(view.standardHeaderRow(rung, facts: f, dressing: dressing,
                                                            targets: targets, sorted: rows,
                                                            sections: sections)).fittingSize
                    checked += 1
                    if ladder.width(of: rung) != drawn.width {
                        failures.append("\(label)/\(dressingName)/\(rung): "
                                        + "computed \(ladder.width(of: rung))pt, drew \(drawn.width)pt")
                    }
                    if drawn.height != ActionBarMetrics.height {
                        failures.append("\(label)/\(dressingName)/\(rung): row is \(drawn.height)pt "
                                        + "tall, but the header pins it to \(ActionBarMetrics.height)pt")
                    }
                }
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(checked == states.count * Self.dressings().count
                * DifferencesView.renderedCompactionLadder.count)
        #expect(failures.isEmpty, "\(failures.count) of \(checked) mispriced:\n\(report)")
    }

    /// The height the `GeometryReader` is pinned to. It is not a guess: the filter menu is an
    /// action-bar capsule and is on the row at every rung, so it is the row's height authority
    /// whatever else has been shed — including at the largest font scale, where the capsule keeps its
    /// 28pt frame while its label grows inside it.
    @Test func theRowIsAlwaysTheActionBarHeight() {
        let names = PaneProviderNames(leftName: "iCloud Drive", rightName: "Dropbox")
        let rows = differences()
        let view = view(rows: rows, names: names)
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        for size in FontSize.allCases {
            for (dressingName, dressing) in Self.dressings() {
                for rung in DifferencesView.renderedCompactionLadder {
                    let ladder = HeaderLadder(facts: facts(rows: rows, names: names,
                                                           dressing: dressing, targets: targets,
                                                           sections: sections),
                                              scale: size.scale)
                    let row = view.standardHeaderRow(rung, facts: ladder.facts, dressing: dressing,
                                                     targets: targets, sorted: rows, sections: sections)
                    let drawn = host(row.appFontSize(size)).fittingSize.height
                    let message = "\(dressingName) \(rung) at \(size) drew \(drawn)pt tall, but "
                        + "the header pins the row to \(ActionBarMetrics.height)pt"
                    #expect(drawn == ActionBarMetrics.height, "\(message)")
                }
            }
        }
    }

    // MARK: - The computed rung against the searched one

    /// The end-to-end oracle: across a width sweep, the row the arithmetic picks is the row the old
    /// six-child `ViewThatFits` picked — same controls, same places, to the point.
    ///
    /// The old ladder is rebuilt here (`searchedLadder`) rather than kept in the app, so this really
    /// is a before/after comparison rather than the new code checking itself.
    @Test func theComputedRungDrawsWhatTheSearchedLadderDrew() {
        // `searchedLadder` below spells its six rungs out because `ViewThatFits` cannot take a loop.
        // If a rung is ever added, this fails here rather than quietly comparing against a ladder one
        // rung short of the one the app builds.
        #expect(DifferencesView.renderedCompactionLadder.count == 6,
                "the ladder has changed length — update `searchedLadder` to match before trusting it")
        var disagreements: [String] = []
        var compared = 0
        for (leftName, rightName) in Self.paneNamePairs {
            let names = PaneProviderNames(leftName: leftName, rightName: rightName)
            let rows = differences()
            let view = view(rows: rows, names: names)
            let targets = DifferenceActionTargets(filtered: rows, selection: [])
            let sections = DifferenceGrouping.sections(rows)
            let (_, dressing) = Self.dressings()[1]     // the everyday case: a fresh age run
            let ladder = HeaderLadder(facts: facts(rows: rows, names: names, dressing: dressing,
                                                   targets: targets, sections: sections),
                                      scale: 1)
            for width in Self.oracleWidths(ladder) {
                let searched = fingerprint(host(searchedLadder(view, facts: ladder.facts,
                                                              dressing: dressing, targets: targets,
                                                              sorted: rows, sections: sections),
                                                width: width))
                let computed = fingerprint(host(
                    view.standardHeaderRow(ladder.rung(fitting: width), facts: ladder.facts,
                                           dressing: dressing, targets: targets, sorted: rows,
                                           sections: sections),
                    width: width))
                compared += 1
                if searched != computed {
                    disagreements.append("\(leftName)/\(rightName) at \(width)pt "
                                         + "→ computed \(ladder.rung(fitting: width))\n"
                                         + "  searched: \(searched)\n  computed: \(computed)")
                }
            }
        }
        #expect(compared > 150, "the sweep collapsed to \(compared) widths — it proves nothing")
        let report = disagreements.prefix(5).joined(separator: "\n")
        #expect(disagreements.isEmpty,
                "\(disagreements.count) of \(compared) widths disagree:\n\(report)")
    }

    /// The widths the oracle compares at.
    ///
    /// Concentrated at the RUNG BOUNDARIES rather than spread evenly, because that is the only place
    /// the two methods can disagree: between boundaries both hold the same rung for tens of points and
    /// every comparison is the same comparison. Half-point steps either side of each boundary, which
    /// is SwiftUI's own layout granularity, so an arithmetic error of a single half point is caught —
    /// a uniform 4pt sweep would step straight over it. A coarse pass across the whole range comes
    /// along to catch anything that is not boundary-shaped.
    private static func oracleWidths(_ ladder: HeaderLadder) -> [CGFloat] {
        var widths = Set<CGFloat>()
        for rung in DifferencesView.renderedCompactionLadder {
            let boundary = ladder.width(of: rung)
            for delta in stride(from: CGFloat(-2), through: 2, by: 0.5) { widths.insert(boundary + delta) }
        }
        for width in stride(from: CGFloat(340), through: 1_500, by: 80) { widths.insert(width) }
        // Below the narrowest rung, where NOTHING fits. This is the case the header's `minWidth`
        // restates — the old `ViewThatFits` advertised its last child's width as its own minimum, and
        // the replacement has to reserve the same or the card can be squeezed narrower than the row.
        for width in [CGFloat(120), 200, 260, 300] { widths.insert(width) }
        return widths.sorted()
    }

    /// The header's ladder exactly as it was before this change: six rows, widest first, searched by
    /// `ViewThatFits`. The oracle above compares against this.
    @ViewBuilder
    private func searchedLadder(_ view: DifferencesView,
                                facts: HeaderLadder.Facts,
                                dressing: DifferencesView.CountPillDressing,
                                targets: DifferenceActionTargets,
                                sorted: [FileDifference],
                                sections: [DifferenceGrouping.Section]) -> some View {
        func row(_ rung: HeaderCompaction) -> some View {
            view.standardHeaderRow(rung, facts: facts, dressing: dressing, targets: targets,
                                   sorted: sorted, sections: sections)
        }
        // Six literals, not a `ForEach`: `ViewThatFits` counts a `ForEach` as a SINGLE child, and the
        // ladder this is reproducing would collapse to one rung. That makes this the one hand-written
        // mirror of `renderedCompactionLadder` left anywhere — the view itself now reads that array —
        // so the oracle asserts the count before trusting it.
        return ViewThatFits(in: .horizontal) {
            row(.full)
            row(.foldVerify)
            row(.foldReview)
            row(.shortReverse)
            row(.glyphFilter)
            row(.shortPrimary)
        }
    }

    // MARK: - The mounted view

    /// Mounts the real `DifferencesView` and checks that the header on screen is a rung of this
    /// ladder — and that it sheds as the window narrows.
    ///
    /// Everything above measures `standardHeaderRow` in isolation, which leaves the join untested:
    /// the rung is chosen from a `GeometryReader`'s width inside the header card, and if that width
    /// is not the width the old `ViewThatFits` was offered then every rung boundary moves. Nothing
    /// else in this suite would notice, because both sides of those comparisons bypass the card.
    ///
    /// The assertion deliberately does not hard-code the card's inner width — it asks instead
    /// whether ONE inset can explain every observation through the ladder.
    ///
    /// Two limits worth knowing, both established by mutation rather than assumed:
    ///
    /// - "It got narrower" is NOT enough on its own. With `rung(fitting:)` broken to always answer
    ///   `.full`, the row still sheds, because the hedge's `ViewThatFits` drops it to the terminal
    ///   rung — the endpoint and monotonicity checks both pass over a ladder doing nothing. What
    ///   only a working ladder produces is the MIDDLE rungs, so that is asserted explicitly.
    /// - A UNIFORM error in every rung's width is invisible here by construction: the inset search
    ///   simply absorbs it. `everyRungMeasuresWhatItDraws` is what catches that class — it compares
    ///   absolute widths against the drawn row. Neither case is sufficient alone.
    @Test func theMountedHeaderDrawsARungAndShedsAsThePaneNarrows() async {
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        let rows = differences()
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        // `lastScanDate` is nil on this fixture, so `withScanFreshness` takes its else branch and the
        // pill wears the pre-scan dressing — the same one the isolated rows below are built with.
        let dressing = Self.dressings()[0].value
        let probe = view(rows: rows, names: names)

        /// The ring SIZES of one rung drawn in isolation. Sizes, not positions: the mounted row sits
        /// inside the card's padding, so its absolute coordinates are shifted, but which controls are
        /// on it — and how wide each is — is exactly what tells the rungs apart.
        func sizes(ofRung rung: HeaderCompaction, width: CGFloat) -> [String] {
            ringSizes(host(probe.standardHeaderRow(rung, facts: facts(rows: rows, names: names,
                                                                      dressing: dressing,
                                                                      targets: targets,
                                                                      sections: sections),
                                                   dressing: dressing, targets: targets,
                                                   sorted: rows, sections: sections),
                           width: width))
        }

        var matched: [(CGFloat, Int)] = []
        for paneWidth in [CGFloat(1_500), 1_100, 820, 620, 480] {
            let mount = mountDifferences(rows: rows, names: names, width: paneWidth)
            defer { mount.window.contentView = nil }
            // Grouping is on, so the table draws a header row per section as well as the rows.
            let expectedRows = rows.count + sections.count
            let settled = await settle(mount.host, atRows: expectedRows)
            let settleNote = "table settled at \(settled) row(s), not \(expectedRows) — the header "
                + "would be measured half-built and every assertion below would be vacuous"
            #expect(settled == expectedRows, "\(settleNote)")
            let drawn = headerRingSizes(mount.host)
            #expect(!drawn.isEmpty, "no header controls found at \(paneWidth)pt")

            // Which rung is this? Compare against each rung drawn at the same pane width; only the
            // control widths matter, and those do not depend on the leading offset.
            let rungIndex = DifferencesView.renderedCompactionLadder.firstIndex {
                sizes(ofRung: $0, width: paneWidth) == drawn
            }
            #expect(rungIndex != nil,
                    "the mounted header at \(paneWidth)pt matches no rung of the ladder — drew \(drawn)")
            if let rungIndex { matched.append((paneWidth, rungIndex)) }
        }

        let trace = matched.map { "\(Int($0.0))pt→rung\($0.1)" }.joined(separator: " ")
        #expect(matched.count == 5, "only \(matched.count) pane width(s) matched a rung — \(trace)")
        #expect(matched.first?.1 == 0, "a 1,500pt pane should draw the unshed row — \(trace)")
        for (a, b) in zip(matched, matched.dropFirst()) {
            #expect(b.1 >= a.1, "narrowing \(a.0)pt → \(b.0)pt moved the ladder back UP — \(trace)")
        }

        // The load-bearing one, and the reason the two weaker checks above are not enough. With the
        // arithmetic broken to always answer `.full`, the row STILL sheds — the hedge's
        // `ViewThatFits` drops it to the terminal rung — so "it got narrower" passes over a ladder
        // that is doing nothing. What only a working ladder produces is the MIDDLE rungs.
        let ladder = HeaderLadder(facts: facts(rows: rows, names: names, dressing: dressing,
                                               targets: targets, sections: sections), scale: 1)
        let terminalIndex = DifferencesView.renderedCompactionLadder.count - 1
        let middleNote = "every pane landed on the widest or the narrowest rung, so the intermediate "
            + "rungs were never chosen by the arithmetic — \(trace)"
        #expect(matched.contains { $0.1 > 0 && $0.1 < terminalIndex }, "\(middleNote)")

        // And the plumbing itself: there must be ONE card inset that explains every observation
        // through this ladder. If the `GeometryReader` were offered something other than the width
        // the old `ViewThatFits` got, no single inset would fit all five.
        let insets = stride(from: CGFloat(0), through: 200, by: 0.5).filter { inset in
            matched.allSatisfy { paneWidth, rungIndex in
                ladder.rung(fitting: paneWidth - inset)
                    == DifferencesView.renderedCompactionLadder[rungIndex]
            }
        }
        #expect(!insets.isEmpty,
                "no single card inset explains the rungs the mounted header drew — \(trace)")
    }

    /// Mounts the real view in a real (never ordered-in) window, the way the other mounting suites do.
    private func mountDifferences(rows: [FileDifference], names: PaneProviderNames,
                                  width: CGFloat) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let store = ScratchDefaults("HeaderLadderTests")
        store.set(true, forKey: "differencesGroupByFolder")
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        let root = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                                   paneNames: names, isCollapsed: .constant(false))
            .defaultAppStorage(store)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// Waits for the differences table to settle at exactly `expected` rows. The header's shape
    /// depends on `sections`, which is empty until the rows land, so measuring early would read a
    /// header the user never sees.
    private func settle(_ view: NSView, atRows expected: Int, timeout: TimeInterval = 15) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var last = 0
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            last = tableRowCount(view) ?? 0
            if last == expected { return last }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return last
    }

    private func tableRowCount(_ view: NSView) -> Int? {
        if let table = view as? NSTableView { return table.numberOfRows }
        for child in view.subviews {
            if let rows = tableRowCount(child) { return rows }
        }
        return nil
    }

    /// Every `_FocusRingView` size in reading order, as `WxH` strings.
    private func ringSizes(_ host: NSView) -> [String] {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") {
                found.append(v.convert(v.bounds, to: host))
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        return found.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
    }

    /// The header strip's rings only — the top band of the mounted view, above the table.
    private func headerRingSizes(_ host: NSView) -> [String] {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") {
                found.append(v.convert(v.bounds, to: host))
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        guard let top = found.map(\.minY).min() else { return [] }
        return found.filter { $0.minY < top + 10 }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
    }

    // MARK: - The rule the ladder follows

    /// `rung(fitting:)` mirrors `ViewThatFits`: the FIRST rung that fits, in declaration order, and
    /// the narrowest when none does. Stated directly so the property survives a fixture change.
    @Test func theLadderTakesTheFirstRungThatFitsAndBottomsOut() {
        let names = PaneProviderNames(leftName: "iCloud Drive", rightName: "Dropbox")
        let rows = differences()
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        let ladder = HeaderLadder(facts: facts(rows: rows, names: names,
                                               dressing: Self.dressings()[1].value,
                                               targets: targets, sections: sections),
                                  scale: 1)

        #expect(ladder.rung(fitting: 10_000) == .full, "an unconstrained row should shed nothing")
        #expect(ladder.rung(fitting: 0) == ladder.terminal, "nothing fits at zero — bottom out")
        #expect(ladder.terminal == HeaderCompaction.shortPrimary)

        for width in stride(from: CGFloat(200), through: 1_600, by: 1) {
            let chosen = ladder.rung(fitting: width)
            let need = ladder.width(of: chosen)
            #expect(chosen == ladder.terminal || need <= width,
                    "chose \(chosen) at \(width)pt, which needs \(need)pt")
            // Nothing ABOVE the chosen rung may fit, or the search would have taken it first.
            for earlier in DifferencesView.renderedCompactionLadder where earlier < chosen {
                #expect(ladder.width(of: earlier) > width,
                        "\(earlier) fits at \(width)pt but \(chosen) was chosen")
            }
        }
    }

    /// This ladder is monotonically non-INCREASING — and that is a measured fact about it, not a
    /// property of shedding ladders in general.
    ///
    /// `PaneBarLadder` documents the opposite for the pane bar, where dropping the preview toggle (a
    /// segment wide) to gain a ⋯ pill (a full pill plus its gap) makes the bar four points *wider*.
    /// Nothing here can do that: every rung either sheds a run of text or is a no-op, and the widest
    /// thing any rung adds is the 28pt overflow in place of a Verify button that is never narrower
    /// than ~90pt. Recorded so that a rung added later which *does* widen the row shows up here
    /// rather than silently becoming unreachable.
    ///
    /// Ties are expected and are the reason declaration order still matters even without an
    /// inversion: a rung whose concession does not apply to the current comparison (no reverse
    /// button to shorten, nothing verifiable to fold away) costs exactly nothing, and a tie has to
    /// resolve to the EARLIER rung to match `ViewThatFits`.
    @Test func theLadderNeverWidensAsItSheds() {
        for (leftName, rightName) in Self.paneNamePairs {
            let names = PaneProviderNames(leftName: leftName, rightName: rightName)
            for rows in [differences(),
                         differences(toRight: 1, toLeft: 0, verifiable: 1, folders: ["Documents"]),
                         differences(toRight: 3, toLeft: 400, verifiable: 0),
                         differences(toRight: 0, toLeft: 9, verifiable: 2)] {
                let targets = DifferenceActionTargets(filtered: rows, selection: [])
                let sections = DifferenceGrouping.sections(rows)
                for (dressingName, dressing) in Self.dressings() {
                    let ladder = HeaderLadder(
                        facts: facts(rows: rows, names: names, dressing: dressing,
                                     targets: targets, sections: sections),
                        scale: 1)
                    let widths = DifferencesView.renderedCompactionLadder.map { ladder.width(of: $0) }
                    let report = "\(leftName)/\(rightName) \(dressingName) rows=\(rows.count): \(widths)"
                    #expect(widths == widths.sorted(by: >=), "a rung WIDENS the row — \(report)")
                }
            }
        }
    }
}
