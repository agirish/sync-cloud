import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The person view paints both groups, and paints them differently. Pixels, because the claims are
/// about what is on screen, and a caption assertion passes vacuously with no assistive client
/// attached to the test process. Light and dark both, to catch a foreground that vanishes into its
/// own background.
@MainActor
// Pinned per test rather than per suite, so the tests that read no pixels aren't held to this
// machine (see `OrganizeRailTests`).
@Suite(.serialized) struct PersonViewTests {

    private static let canvas = CGSize(width: 760, height: 480)
    /// The header, above the divider.
    private static let headerZone = CGRect(x: 0, y: 0, width: 760, height: 36)
    /// The two groups, measured by sweeping a render with the elsewhere group against one without:
    /// folders occupy y 44–134, and "Theirs, filed elsewhere" heads y≈155.
    private static let foldersZone = CGRect(x: 0, y: 44, width: 760, height: 90)
    private static let elsewhereZone = CGRect(x: 0, y: 155, width: 760, height: 180)
    /// The folders group's heading line, which carries the person's name. Measured by rendering one
    /// set under two names: the panel header (which shows the name too) moves at y 0–30, the
    /// heading at 50–70, and nothing from 70 down. So this band holds the heading and not the
    /// header, and `theFoldersRowsBelowDoNotCarryTheName` keeps it honest.
    private static let ownFoldersTitleZone = CGRect(x: 0, y: 48, width: 760, height: 24)
    private static let ownFoldersRowsZone = CGRect(x: 0, y: 80, width: 760, height: 50)
    /// The gathering or failed state's leading glyph and its two text lines. The band contains the
    /// spinner (x 40–75), which is stable: an offscreen window never ordered in doesn't advance the
    /// animation, so repeated renders ink the same. The failed state's warning triangle starts
    /// further left (x 15) and is partly outside, which is fine: the text is what is asserted.
    private static let stateTextZone = CGRect(x: 38, y: 44, width: 620, height: 44)

    private static func folder(_ path: String, _ n: Int) -> (folder: String, files: [PersonFile]) {
        (folder: path, files: (0..<n).map { PersonFile(path: "\(path)/f\($0).pdf", evidence: .ownFolder) })
    }

    private static var daughter: PersonFileSet {
        PersonFileSet(personId: "daughter",
                      ownFolders: [folder("Family/Daughter", 112), folder("Immigration/OCI/Daughter", 24)],
                      elsewhere: [
                        PersonFile(path: "Shared/Inbox/Daughter Father - OCI Card.pdf",
                                   evidence: .namedInFile, matchedForm: "Daughter Father")])
    }

    private func mount(_ set: PersonFileSet, name: String = "Daughter",
                       scheme: ColorScheme = .light, accent: Color = .accentColor) -> NSHostingView<AnyView> {
        mount(phase: .ready(set), name: name, scheme: scheme, accent: accent)
    }

    private func mount(phase: PersonGatherPhase, name: String = "Daughter",
                       scheme: ColorScheme = .light, accent: Color = .accentColor) -> NSHostingView<AnyView> {
        let subject = PersonView(displayName: name, phase: phase, accent: accent,
                                 onOpenFolder: { _ in }, onReveal: { _ in }, onClear: {})
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func ink(_ host: NSHostingView<AnyView>, _ band: CGRect) -> Int {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return 0 }
        host.cacheDisplay(in: band, to: rep)
        guard let bg = rep.colorAt(x: 2, y: 2) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let d = max(abs(c.redComponent - bg.redComponent),
                            max(abs(c.greenComponent - bg.greenComponent),
                                abs(c.blueComponent - bg.blueComponent)))
                if d > 0.35 { n += 1 }
            }
        }
        return n
    }

    /// Pixels that differ between two renders of the same band. An ink count can't answer "did this
    /// number change": `80` and `85` have almost the same glyph density and ink alike.
    private func differingPixels(_ a: NSHostingView<AnyView>, _ b: NSHostingView<AnyView>,
                                 _ band: CGRect) -> Int {
        a.layoutSubtreeIfNeeded(); b.layoutSubtreeIfNeeded()
        guard let ra = a.bitmapImageRepForCachingDisplay(in: band),
              let rb = b.bitmapImageRepForCachingDisplay(in: band) else {
            // Recorded rather than answered: callers check both `> 20` and `== 0`, so any count
            // returned here would pass one of them without measuring.
            Issue.record("no bitmap for the band \(band)")
            return 0
        }
        a.cacheDisplay(in: band, to: ra)
        b.cacheDisplay(in: band, to: rb)
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh else { return .max }
        return PixelDiff.differingPixels(ra, rb, tolerance: 0)
    }

    @Test("Both groups reach the screen, in both themes", .machinePinned(.pixelSampling))
    func bothGroupsPaint() {
        // Both themes: a foreground that vanishes into its own background is invisible to every
        // geometry assertion and to a light-only render.
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(Self.daughter, scheme: scheme)
            #expect(ink(host, Self.headerZone) > 200, "the header is empty in \(scheme)")
            #expect(ink(host, Self.foldersZone) > 600, "the folder group is empty in \(scheme)")
            #expect(ink(host, Self.elsewhereZone) > 400, "the elsewhere group is empty in \(scheme)")
        }
    }

    @Test("The elsewhere group is what disappears when there is nothing misfiled", .machinePinned(.pixelSampling))
    func theElsewhereGroupIsConditional() {
        // The payoff group is the reason to open this view, so its absence must be real absence,
        // not an empty heading, and its presence must be what changes, not the folders above it,
        // which are identical in both fixtures.
        let withNone = PersonFileSet(personId: "daughter", ownFolders: Self.daughter.ownFolders,
                                     elsewhere: [])
        let bare = mount(withNone)
        let full = mount(Self.daughter)
        #expect(ink(bare, Self.elsewhereZone) < 100,
                "the elsewhere group painted with nothing in it — an empty heading is a claim")
        #expect(ink(full, Self.elsewhereZone) > 400)
        // …and the folder group above is untouched, or the comparison is measuring the wrong thing.
        #expect(ink(bare, Self.foldersZone) == ink(full, Self.foldersZone),
                "the folder group changed too — the elsewhere band is measuring the wrong region")
    }

    @Test("Gathering says so, in both themes", .machinePinned(.pixelSampling))
    func theGatheringStatePaints() {
        // While gathering, a silent slot would make the accept look like it did nothing. The words
        // are the claim; the band also holds the spinner, which renders the same every time.
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(phase: .gathering, scheme: scheme)
            #expect(ink(host, Self.stateTextZone) > 400,
                    "the gathering text is not painting in \(scheme)")
            #expect(ink(host, Self.headerZone) > 150,
                    "the header lost the name or the way out in \(scheme)")
            #expect(ink(host, Self.elsewhereZone) < 100,
                    "content painted below a sweep that has no answer yet in \(scheme)")
        }
        // The header capsule is an answer, so mid-sweep there must be none: "0 files" would be a
        // wrong answer, not a pending one. An empty ready set isolates it: same name, same ✕, and
        // the capsule is the only thing that can differ.
        let empty = PersonFileSet(personId: "daughter", ownFolders: [], elsewhere: [])
        #expect(differingPixels(mount(phase: .gathering), mount(empty), Self.headerZone) > 20,
                "the header paints the same with and without an answer — the count capsule is showing mid-sweep")
    }

    @Test("A missing corpus is said in the slot, in both themes", .machinePinned(.pixelSampling))
    func theFailedStateSaysWhy() {
        // In the slot, not a transient banner, which would be gone by the time the still-empty slot
        // made anyone wonder why accepting did nothing.
        let reason = "The survey of this tree has not been read yet, so there is nothing to gather."
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(phase: .failed(reason), scheme: scheme)
            #expect(ink(host, Self.stateTextZone) > 400,
                    "the failure text is not painting in \(scheme)")
            #expect(ink(host, Self.elsewhereZone) < 100,
                    "content painted below a gather that never ran in \(scheme)")
        }
        // And it paints differently from the gathering state: a failure that renders as "still
        // working" would leave him waiting on a sweep that already gave up.
        #expect(differingPixels(mount(phase: .failed(reason)), mount(phase: .gathering),
                                Self.stateTextZone) > 100,
                "failed and gathering paint the same words")
    }

    @Test("A person with nothing gets an answer, not a blank panel", .machinePinned(.pixelSampling))
    func theEmptyStateSaysSo() {
        let empty = PersonFileSet(personId: "son", ownFolders: [], elsewhere: [])
        let host = mount(empty, name: "Son")
        // Something is said ("Nothing filed under Son.") and the groups are gone.
        #expect(ink(host, Self.foldersZone) > 150, "an empty result painted nothing at all")
        #expect(ink(host, Self.headerZone) > 200, "the header lost its name and count")
    }

    @Test("The count in the header is the whole set, not the rows on screen", .machinePinned(.pixelSampling))
    func theHeaderCountsEverything() {
        // The folder list truncates at 8; the header must still count the whole set. The two
        // fixtures share their visible rows exactly (the same eight folders, in order) and differ
        // only past the cut, so the total is the only thing that can move the header's pixels.
        let visible = (0..<8).map { Self.folder("Area/\($0)", 10) }
        let short = PersonFileSet(personId: "daughter", ownFolders: visible, elsewhere: [])
        let long = PersonFileSet(personId: "daughter",
                                 ownFolders: visible + (0..<5).map { Self.folder("Extra/\($0)", 1) },
                                 elsewhere: [])
        #expect(differingPixels(mount(long), mount(short), Self.headerZone) > 20,
                "the header painted the same count for 80 files and 85 — it is counting the visible rows")
        // Not covered: no test asserts the "5 more folders…" line past the cut. A band over the
        // group differs between these fixtures anyway (the group header carries its own "85 files ·
        // 13 folders"), and a guessed band lands on the rows; it needs the row pitch measured.
    }

    // MARK: - Waiting for review

    /// The review band, measured by sweeping row ink over a fixture that has one: the group header
    /// lands at y≈252–275 and the two rows at y≈295–317 and y≈340–362. It starts at 240 to clear
    /// the elsewhere group above, whose last row ends at y≈225.
    private static let reviewZone = CGRect(x: 0, y: 240, width: 760, height: 130)

    /// The elsewhere group's own rows, stopping short of the review group (its last row ends at
    /// y≈225). `elsewhereZone` reaches y=335, inside the review group, so it can't isolate the
    /// elsewhere group from the review group's arrival.
    private static let elsewhereOnlyZone = CGRect(x: 0, y: 155, width: 760, height: 80)

    static var daughterWithReview: PersonFileSet {
        PersonFileSet(personId: "daughter",
                      ownFolders: [folder("Family/Daughter", 112), folder("Immigration/OCI/Daughter", 24)],
                      elsewhere: [
                        PersonFile(path: "Shared/Inbox/Daughter Father - OCI Card.pdf",
                                   evidence: .namedInFile, matchedForm: "Daughter Father")],
                      review: [
                        PersonFile(path: "Shared/Inbox/Scan 2026-03-14.pdf",
                                   evidence: .namedOnPage, matchedForm: "Daughter Father",
                                   reason: .namedOnPageOnly(form: "Daughter Father")),
                        PersonFile(path: "Financial/Father - Family insurance card.pdf",
                                   evidence: .namedInFile, matchedForm: "Father",
                                   reason: .sharedWordInName(word: "father", sharedWith: 3)),
                      ])
    }

    @Test("The review group paints, in both themes", .machinePinned(.pixelSampling))
    func theReviewGroupPaints() {
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(Self.daughterWithReview, scheme: scheme)
            #expect(ink(host, Self.reviewZone) > 600, "the review group is empty in \(scheme)")
        }
    }

    /// A group with nothing to ask must not paint a heading: an empty "Waiting for review" is
    /// itself a claim that there is something to review.
    @Test("The review group is absent when there is nothing to review", .machinePinned(.pixelSampling))
    func theReviewGroupIsConditional() {
        let without = mount(Self.daughter)
        let with = mount(Self.daughterWithReview)
        #expect(ink(without, Self.reviewZone) < 100, "the review group painted with nothing in it")
        #expect(ink(with, Self.reviewZone) > 600)
        // …and the groups above are untouched, or the band is measuring the wrong region.
        #expect(ink(without, Self.foldersZone) == ink(with, Self.foldersZone),
                "the folder group changed too — the review band overlaps it")
        #expect(ink(without, Self.elsewhereOnlyZone) == ink(with, Self.elsewhereOnlyZone),
                "the elsewhere group changed too — the review band overlaps it")
    }

    /// The two answers paint as controls, not as more links: as plain text the row reads as three
    /// links, with the refusal looking like a tertiary action beside "Reveal" rather than half of
    /// the question. The fill is drawn by hand because `.borderedProminent` renders unfilled in an
    /// offscreen host.
    ///
    /// It fills with the deepened accent under a white label, like every other filled control; a
    /// raw-accent fill with `Color.onFillLabel` would put dark ink on Green. Green is the hue where
    /// the two fills differ most, so the fill read back can only be one; Blue's deepened fill is
    /// far from Green's, so a fill that ignored the accent fails one of the two.
    @Test("The confirm button is the deepened accent with a white label", .machinePinned(.pixelSampling),
          arguments: [ColorScheme.light, ColorScheme.dark], [LiquidGlassHue.green, .blue])
    func theConfirmButtonTakesTheDeepenedFill(scheme: ColorScheme, hue: LiquidGlassHue) throws {
        func deepenedFill(_ hue: LiquidGlassHue) throws -> (raw: NSColor, deepened: NSColor) {
            let raw = try #require(NSColor(hue.accentColor).usingColorSpace(.sRGB))
            return (raw, AccentFill.deepened(raw))
        }
        let (raw, deepened) = try deepenedFill(hue)
        if hue == .green {
            #expect(PixelProbe.distance(raw, deepened) > 0.1, "Green's fill and raw accent are too close to tell apart")
        } else {
            #expect(PixelProbe.distance(deepened, try deepenedFill(.green).deepened) > 0.1,
                    "\(hue)'s fill is too close to Green's to catch a fill that ignores the accent")
        }

        // The capsule, centred in a band wide enough to hold all of it; the fill is the commonest
        // colour that is not the ground.
        let band = CGRect(x: 596, y: 288, width: 70, height: 30)
        let host = mount(Self.daughterWithReview, scheme: scheme, accent: hue.accentColor)
        let rep = try #require(PixelProbe.render(host, band))
        let ground = try #require(rep.colorAt(x: 0, y: 0))
        let fill = try #require(PixelProbe.dominant(in: rep) { PixelProbe.distance($0, ground) > 0.1 })
        #expect(PixelProbe.distance(fill, deepened) < 0.01,
                "the confirm button fills with \(PixelProbe.describe(fill)) in \(scheme), not the deepened \(hue) \(PixelProbe.describe(deepened))")
        #expect(PixelProbe.count(in: rep) { PixelProbe.distance($0, deepened) < 0.01 } > 200,
                "the confirm button is not filled in \(scheme)")
        // The label, inside the capsule: white there, and no dark ink.
        let box = try #require(PixelProbe.bounds(in: rep) { PixelProbe.distance($0, fill) < 0.01 })
        let scale = CGFloat(rep.pixelsWide) / band.width
        let inner = box.insetBy(dx: 4 * scale, dy: 2 * scale)
        #expect(PixelProbe.count(in: rep, inner) { $0.isNearWhite } > 20, "no white label on the confirm button in \(scheme)")
        #expect(PixelProbe.count(in: rep, inner) { $0.isDark } == 0, "the confirm button's label is dark ink in \(scheme)")
    }

    /// The header says how many are theirs and how many are still questions, separately: one total
    /// would assert exactly what the queue exists to ask. The two fixtures share every claimed row,
    /// so the chip is the only thing that can move these pixels.
    @Test("The review count is its own chip, not folded into the total", .machinePinned(.pixelSampling))
    func theReviewCountIsSeparate() {
        #expect(differingPixels(mount(Self.daughterWithReview), mount(Self.daughter), Self.headerZone) > 20,
                "the header paints the same with and without questions — the chip is missing")
    }

    /// The model half of the separate count, unpinned: it reads no pixels.
    @Test func aQuestionIsNotCountedAsAnAnswer() {
        #expect(Self.daughterWithReview.total == Self.daughter.total,
                "a question was counted as an answer")
    }

    /// The folders group is headed with the person's name ("In \(displayName)’s folders"), a claim
    /// only a render can make. `GenderedCopyTests` proves only an absence, so a constant "In their
    /// folders" would pass it; this test fails it. Two names, one set: the only thing that can
    /// differ in the heading band is the name.
    @Test("The folders group is headed with the person's name", .machinePinned(.pixelSampling))
    func theOwnFoldersTitleNamesThePerson() {
        let daughter = mount(Self.daughter, name: "Daughter")
        let bartholomew = mount(Self.daughter, name: "Bartholomew")
        // Not two blank bands agreeing to differ: the heading must paint in both.
        #expect(ink(daughter, Self.ownFoldersTitleZone) > 200, "the folders heading is not painting")
        #expect(ink(bartholomew, Self.ownFoldersTitleZone) > 200, "the folders heading is not painting")
        #expect(differingPixels(daughter, bartholomew, Self.ownFoldersTitleZone) > 500,
                "the folders heading is the same under two names — it no longer names the person")
    }

    /// And the band above measures the heading rather than bleeding from the panel header, which
    /// shows the name as well. The rows carry paths and counts, so they must not move at all.
    @Test("The folder rows below the heading do not carry the name", .machinePinned(.pixelSampling))
    func theFoldersRowsBelowDoNotCarryTheName() {
        let daughter = mount(Self.daughter, name: "Daughter")
        let bartholomew = mount(Self.daughter, name: "Bartholomew")
        #expect(ink(daughter, Self.ownFoldersRowsZone) > 200, "the folder rows are not painting")
        #expect(differingPixels(daughter, bartholomew, Self.ownFoldersRowsZone) == 0,
                """
                a folder row changed with the name — either the heading band above is measuring \
                the wrong region, or the heading wrapped under the longer name and pushed the rows \
                down (it fits on one line at this width, which is what makes that band stable)
                """)
    }

    /// The two reasons say different things: a row that blurred them would ask the user to judge
    /// evidence it had misdescribed.
    @Test("A shared-word row and a page row do not read the same")
    func theTwoReasonsPaintDifferently() {
        let page = PersonFile(path: "a.pdf", evidence: .namedOnPage,
                              reason: .namedOnPageOnly(form: "Daughter Father"))
        let word = PersonFile(path: "a.pdf", evidence: .namedInFile,
                              reason: .sharedWordInName(word: "father", sharedWith: 3))
        #expect(PersonView.caption(for: page, displayName: "Daughter")
                != PersonView.caption(for: word, displayName: "Daughter"))
        #expect(PersonView.caption(for: word, displayName: "Daughter").contains("3 others"))
        #expect(PersonView.caption(for: page, displayName: "Daughter").contains("page 1"))
        // Singular is not "1 others".
        let one = PersonFile(path: "a.pdf", evidence: .namedInFile,
                             reason: .sharedWordInName(word: "elder", sharedWith: 1))
        #expect(PersonView.caption(for: one, displayName: "Elder").contains("1 other person"))
    }
}
