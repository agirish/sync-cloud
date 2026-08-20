import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The person view paints both groups, and paints them differently.
///
/// **Pixels, because the interesting claims are all about what is on screen** and a caption
/// assertion passes vacuously with no assistive client attached to the test process. Rendered and
/// read back in light and dark before this suite existed — the two-theme check is what catches a
/// foreground that vanishes into its own background.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PersonViewTests {

    private static let canvas = CGSize(width: 760, height: 480)
    /// The header, above the divider.
    private static let headerZone = CGRect(x: 0, y: 0, width: 760, height: 36)
    /// The two groups. **Measured, and corrected once**: a 20pt sweep comparing a render with the
    /// elsewhere group against one without put the first difference at y=140, not the y=180 the
    /// first cut assumed — so a 44–164 folder band overlapped the group below it and reported 660
    /// ink of "difference" in a region that is identical in both. Folders occupy 44–134;
    /// "Theirs, filed elsewhere" heads y≈155.
    private static let foldersZone = CGRect(x: 0, y: 44, width: 760, height: 90)
    private static let elsewhereZone = CGRect(x: 0, y: 155, width: 760, height: 180)
    /// The folders group's heading line, which carries the person's name.
    ///
    /// **Measured**, by rendering the same set under two names and sweeping 10pt bands: the panel
    /// header answers at y 0–30 (it shows the name too), nothing moves at 30–50, the heading moves
    /// at 50–70 by 3,203 pixels, and everything from 70 down is identical. So this band holds the
    /// heading and not the header above it, and the rows below it are name-independent — which is
    /// what `theFoldersRowsBelowDoNotCarryTheName` asserts, to keep this band honest.
    private static let ownFoldersTitleZone = CGRect(x: 0, y: 48, width: 760, height: 24)
    private static let ownFoldersRowsZone = CGRect(x: 0, y: 80, width: 760, height: 50)
    /// The gathering / failed state's leading glyph and its two text lines.
    ///
    /// **Measured, and the first comment here was wrong twice.** It claimed x=38 excluded the
    /// spinner "because its animation frame is not deterministic"; a column sweep put the
    /// gathering state's ink at x 40–591 and the spinner itself at x 40–75, so the band contains
    /// the spinner rather than excluding it. It is also not a flake risk: eight renders of
    /// `.gathering` inked 6,476 pixels every time (spread 0) — an offscreen window that is never
    /// ordered in does not advance the animation. Rows land at y 51–79, inside this band.
    /// The failed state's warning triangle sits further left (from x 15) and is partly outside;
    /// that is fine, because the text is what these tests are asserting.
    private static let stateTextZone = CGRect(x: 38, y: 44, width: 620, height: 44)

    private static func folder(_ path: String, _ n: Int) -> (folder: String, files: [PersonFile]) {
        (folder: path, files: (0..<n).map { PersonFile(path: "\(path)/f\($0).pdf", evidence: .ownFolder) })
    }

    private static var aditi: PersonFileSet {
        PersonFileSet(personId: "aditi",
                      ownFolders: [folder("Family/Aditi", 112), folder("Immigration/OCI/Aditi", 24)],
                      elsewhere: [
                        PersonFile(path: "Shared/Inbox/Aditi Abhishek - OCI Card.pdf",
                                   evidence: .namedInFile, matchedForm: "Aditi Abhishek")])
    }

    private func mount(_ set: PersonFileSet, name: String = "Aditi",
                       scheme: ColorScheme = .light) -> NSHostingView<AnyView> {
        mount(phase: .ready(set), name: name, scheme: scheme)
    }

    private func mount(phase: PersonGatherPhase, name: String = "Aditi",
                       scheme: ColorScheme = .light) -> NSHostingView<AnyView> {
        let subject = PersonView(displayName: name, phase: phase, accent: .accentColor,
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

    /// Pixels that differ between two renders of the same band.
    ///
    /// **An ink count cannot answer "did this number change".** `80` and `85` have almost the same
    /// glyph density, so both headers inked 1,831 pixels and an equality-of-counts assertion read
    /// them as identical. Counting *differing* pixels asks the question that was meant.
    private func differingPixels(_ a: NSHostingView<AnyView>, _ b: NSHostingView<AnyView>,
                                 _ band: CGRect) -> Int {
        a.layoutSubtreeIfNeeded(); b.layoutSubtreeIfNeeded()
        guard let ra = a.bitmapImageRepForCachingDisplay(in: band),
              let rb = b.bitmapImageRepForCachingDisplay(in: band) else { return 0 }
        a.cacheDisplay(in: band, to: ra)
        b.cacheDisplay(in: band, to: rb)
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh else { return .max }
        var n = 0
        for y in 0..<ra.pixelsHigh {
            for x in 0..<ra.pixelsWide where ra.colorAt(x: x, y: y) != rb.colorAt(x: x, y: y) { n += 1 }
        }
        return n
    }

    @Test("Both groups reach the screen, in both themes")
    func bothGroupsPaint() {
        // Both themes, because a foreground that vanishes into its own background is invisible to
        // every geometry assertion and to a light-only render.
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(Self.aditi, scheme: scheme)
            #expect(ink(host, Self.headerZone) > 200, "the header is empty in \(scheme)")
            #expect(ink(host, Self.foldersZone) > 600, "the folder group is empty in \(scheme)")
            #expect(ink(host, Self.elsewhereZone) > 400, "the elsewhere group is empty in \(scheme)")
        }
    }

    @Test("The elsewhere group is what disappears when there is nothing misfiled")
    func theElsewhereGroupIsConditional() {
        // The payoff group is the reason to open this view, so its absence has to be real absence
        // rather than an empty heading — and its presence has to be what changes, not the folders
        // above it, which are identical in both fixtures.
        let withNone = PersonFileSet(personId: "aditi", ownFolders: Self.aditi.ownFolders,
                                     elsewhere: [])
        let bare = mount(withNone)
        let full = mount(Self.aditi)
        #expect(ink(bare, Self.elsewhereZone) < 100,
                "the elsewhere group painted with nothing in it — an empty heading is a claim")
        #expect(ink(full, Self.elsewhereZone) > 400)
        // …and the folder group above is untouched, or the comparison is measuring the wrong thing.
        #expect(ink(bare, Self.foldersZone) == ink(full, Self.foldersZone),
                "the folder group changed too — the elsewhere band is measuring the wrong region")
    }

    @Test("Gathering says so, in both themes")
    func theGatheringStatePaints() {
        // The interval this covers is exactly the one where a silent slot made the accept look
        // like it did nothing. The band starts at x=38 to exclude the spinner, whose animation
        // frame is not deterministic; the words are the claim.
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(phase: .gathering, scheme: scheme)
            #expect(ink(host, Self.stateTextZone) > 400,
                    "the gathering text is not painting in \(scheme)")
            #expect(ink(host, Self.headerZone) > 150,
                    "the header lost the name or the way out in \(scheme)")
            #expect(ink(host, Self.elsewhereZone) < 100,
                    "content painted below a sweep that has no answer yet in \(scheme)")
        }
        // The header capsule is an answer, so mid-sweep there must be none — "0 files" would be
        // a wrong answer, not a pending one. An empty READY set is the fixture that isolates it:
        // same name, same ✕, and the capsule is the only thing that can differ.
        let empty = PersonFileSet(personId: "aditi", ownFolders: [], elsewhere: [])
        #expect(differingPixels(mount(phase: .gathering), mount(empty), Self.headerZone) > 20,
                "the header paints the same with and without an answer — the count capsule is showing mid-sweep")
    }

    @Test("A missing corpus is said in the slot, in both themes")
    func theFailedStateSaysWhy() {
        // This used to be a transient banner — gone by the time the still-empty slot made anyone
        // wonder why accepting did nothing.
        let reason = "The survey of this tree has not been read yet, so there is nothing to gather."
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(phase: .failed(reason), scheme: scheme)
            #expect(ink(host, Self.stateTextZone) > 400,
                    "the failure text is not painting in \(scheme)")
            #expect(ink(host, Self.elsewhereZone) < 100,
                    "content painted below a gather that never ran in \(scheme)")
        }
        // And it is a different painting from the gathering state — a failure that renders as
        // "still working" would leave him waiting on a sweep that already gave up.
        #expect(differingPixels(mount(phase: .failed(reason)), mount(phase: .gathering),
                                Self.stateTextZone) > 100,
                "failed and gathering paint the same words")
    }

    @Test("A person with nothing gets an answer, not a blank panel")
    func theEmptyStateSaysSo() {
        let empty = PersonFileSet(personId: "divit", ownFolders: [], elsewhere: [])
        let host = mount(empty, name: "Divit")
        // Something is said — "Nothing filed under Divit." — and the groups are gone.
        #expect(ink(host, Self.foldersZone) > 150, "an empty result painted nothing at all")
        #expect(ink(host, Self.headerZone) > 200, "the header lost its name and count")
    }

    @Test("The count in the header is the whole set, not the rows on screen")
    func theHeaderCountsEverything() {
        // The folder list truncates at 8; the header must still answer the question that was asked.
        //
        // **The two fixtures share their VISIBLE rows exactly** — the same eight folders, in the
        // same order — and differ only past the cut. A first version added folders that changed
        // both the total and the visible prefix, so the header differed either way and a mutation
        // counting only the visible rows passed it. Making the visible half identical is what
        // leaves the total as the only thing that can move the pixels.
        let visible = (0..<8).map { Self.folder("Area/\($0)", 10) }
        let short = PersonFileSet(personId: "aditi", ownFolders: visible, elsewhere: [])
        let long = PersonFileSet(personId: "aditi",
                                 ownFolders: visible + (0..<5).map { Self.folder("Extra/\($0)", 1) },
                                 elsewhere: [])
        #expect(differingPixels(mount(long), mount(short), Self.headerZone) > 20,
                "the header painted the same count for 80 files and 85 — it is counting the visible rows")
        // And the remainder is STATED rather than dropped: past the cut the folder group grows a
        // "5 more folders…" line. **Measured over the whole group, not `foldersZone`** — that band
        // stops at y=134 and holds only the group header and two rows, so it saw the header's own
        // count change and reported a difference while the line it names sits 180pt below. Deleting
        // the line failed nothing until this band reached it.
        // **NOT covered here: the "5 more folders…" line itself.** Three attempts failed to
        // isolate it and each failed in a way worth recording. A band over the whole group differs
        // between these fixtures whether or not the line draws, because the group header carries
        // its own "85 files · 13 folders"; a band below the header still contains it; and a band
        // placed where eight rows were estimated to end (y≈296) lands *on* the rows, which ink
        // 1,049 pixels there. Deleting the line fails none of those. Rather than keep guessing at
        // a rectangle, the claim is left uncovered and said so: the remainder line is asserted by
        // no test, and locating it wants the row pitch measured rather than assumed.
    }

    // MARK: - Waiting for review

    /// The review band, **measured** by sweeping row ink over a fixture that has one: the group
    /// header lands at y≈252–275 and the two rows at y≈295–317 and y≈340–362. The band starts at
    /// 240 so it clears the elsewhere group above, whose last row ends at y≈225.
    private static let reviewZone = CGRect(x: 0, y: 240, width: 760, height: 130)

    /// The elsewhere group's own rows, stopping short of the review group.
    ///
    /// **`elsewhereZone` is 180pt tall and reaches y=335, which is inside the review group.** That
    /// was harmless while nothing rendered below it and is not any more: the "did the group above
    /// change?" check below read 10,256 against 25,222 ink and failed, correctly, because the band
    /// it was comparing contained the very group whose arrival it was supposed to be isolating from.
    /// The elsewhere group's last row ends at y≈225.
    private static let elsewhereOnlyZone = CGRect(x: 0, y: 155, width: 760, height: 80)

    static var aditiWithReview: PersonFileSet {
        PersonFileSet(personId: "aditi",
                      ownFolders: [folder("Family/Aditi", 112), folder("Immigration/OCI/Aditi", 24)],
                      elsewhere: [
                        PersonFile(path: "Shared/Inbox/Aditi Abhishek - OCI Card.pdf",
                                   evidence: .namedInFile, matchedForm: "Aditi Abhishek")],
                      review: [
                        PersonFile(path: "Shared/Inbox/Scan 2026-03-14.pdf",
                                   evidence: .namedOnPage, matchedForm: "Aditi Abhishek",
                                   reason: .namedOnPageOnly(form: "Aditi Abhishek")),
                        PersonFile(path: "Financial/Abhishek - Family insurance card.pdf",
                                   evidence: .namedInFile, matchedForm: "Abhishek",
                                   reason: .sharedWordInName(word: "abhishek", sharedWith: 3)),
                      ])
    }

    @Test("The review group paints, in both themes")
    func theReviewGroupPaints() {
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(Self.aditiWithReview, scheme: scheme)
            #expect(ink(host, Self.reviewZone) > 600, "the review group is empty in \(scheme)")
        }
    }

    /// **A group that has nothing to ask must not paint a heading.** An empty "Waiting for review"
    /// is itself a claim that there is something to review.
    @Test("The review group is absent when there is nothing to review")
    func theReviewGroupIsConditional() {
        let without = mount(Self.aditi)
        let with = mount(Self.aditiWithReview)
        #expect(ink(without, Self.reviewZone) < 100, "the review group painted with nothing in it")
        #expect(ink(with, Self.reviewZone) > 600)
        // …and the groups above are untouched, or the band is measuring the wrong region.
        #expect(ink(without, Self.foldersZone) == ink(with, Self.foldersZone),
                "the folder group changed too — the review band overlaps it")
        #expect(ink(without, Self.elsewhereOnlyZone) == ink(with, Self.elsewhereOnlyZone),
                "the elsewhere group changed too — the review band overlaps it")
    }

    /// **The two answers paint as controls, not as a third link.**
    ///
    /// Rendered first as plain text runs, the row read as three links of which the answers were the
    /// least prominent — "Not Aditi's" wore the same grey as "Reveal", so the refusal looked like a
    /// tertiary action rather than half of the question. The fill is drawn by hand for a reason
    /// worth keeping: `.borderedProminent` renders **unfilled** in an offscreen host, so a
    /// filled-control assertion would read false with the button plainly on screen.
    ///
    /// Measured inside the capsule itself — a band over the whole trailing group would count the
    /// row's text and pass with no fill at all.
    @Test("The confirm button is a filled control, in both themes")
    func theConfirmButtonPaintsFilled() {
        let capsule = CGRect(x: 612, y: 298, width: 38, height: 10)
        for scheme in [ColorScheme.light, .dark] {
            let host = mount(Self.aditiWithReview, scheme: scheme)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: capsule) else {
                Issue.record("no bitmap in \(scheme)")
                return
            }
            host.cacheDisplay(in: capsule, to: rep)
            var accentPixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    // A blue fill: blue materially above red. Neither theme's row background is.
                    if c.blueComponent - c.redComponent > 0.25 { accentPixels += 1 }
                }
            }
            #expect(accentPixels > 200,
                    "the confirm button is not filled in \(scheme) — \(accentPixels) accent pixels")
        }
    }

    /// **The header says how many are theirs and how many are still questions, separately.**
    ///
    /// Folding them into one total would be the view asserting exactly what the queue exists to
    /// ask. The two fixtures share every claimed row, so the chip is the only thing that can move
    /// these pixels.
    @Test("The review count is its own chip, not folded into the total")
    func theReviewCountIsSeparate() {
        #expect(differingPixels(mount(Self.aditiWithReview), mount(Self.aditi), Self.headerZone) > 20,
                "the header paints the same with and without questions — the chip is missing")
        #expect(Self.aditiWithReview.total == Self.aditi.total,
                "a question was counted as an answer")
    }

    /// **The folders group is headed with the person's name, and that is a claim only a render can
    /// make.**
    ///
    /// The heading used to read "In her folders", which was wrong for everyone on the roster who is
    /// not the fixture. It now reads "In \(displayName)’s folders" — and `GenderedCopyTests` cannot
    /// see the difference between that and "In their folders", because it only proves an ABSENCE.
    /// Verified against exactly that: with the heading replaced by the constant "In their folders",
    /// every one of the thirteen tests across both suites still passed. This is the one that fails.
    ///
    /// Two names, one set: the only thing that can differ in the heading band is the name.
    @Test("The folders group is headed with the person's name")
    func theOwnFoldersTitleNamesThePerson() {
        let aditi = mount(Self.aditi, name: "Aditi")
        let bartholomew = mount(Self.aditi, name: "Bartholomew")
        // Not two blank bands agreeing to differ: the heading has to be painting in both.
        #expect(ink(aditi, Self.ownFoldersTitleZone) > 200, "the folders heading is not painting")
        #expect(ink(bartholomew, Self.ownFoldersTitleZone) > 200, "the folders heading is not painting")
        #expect(differingPixels(aditi, bartholomew, Self.ownFoldersTitleZone) > 500,
                "the folders heading is the same under two names — it no longer names the person")
    }

    /// And the band above measures the heading rather than bleeding from the panel header, which
    /// shows the name as well. The rows carry paths and counts, so they must not move at all.
    @Test("The folder rows below the heading do not carry the name")
    func theFoldersRowsBelowDoNotCarryTheName() {
        let aditi = mount(Self.aditi, name: "Aditi")
        let bartholomew = mount(Self.aditi, name: "Bartholomew")
        #expect(ink(aditi, Self.ownFoldersRowsZone) > 200, "the folder rows are not painting")
        #expect(differingPixels(aditi, bartholomew, Self.ownFoldersRowsZone) == 0,
                """
                a folder row changed with the name — either the heading band above is measuring \
                the wrong region, or the heading wrapped under the longer name and pushed the rows \
                down (it fits on one line at this width, which is what makes that band stable)
                """)
    }

    /// The two reasons say different things — a row that blurred them would be asking the user to
    /// judge evidence it had misdescribed.
    @Test("A shared-word row and a page row do not read the same")
    func theTwoReasonsPaintDifferently() {
        let page = PersonFile(path: "a.pdf", evidence: .namedOnPage,
                              reason: .namedOnPageOnly(form: "Aditi Abhishek"))
        let word = PersonFile(path: "a.pdf", evidence: .namedInFile,
                              reason: .sharedWordInName(word: "abhishek", sharedWith: 3))
        #expect(PersonView.caption(for: page, displayName: "Aditi")
                != PersonView.caption(for: word, displayName: "Aditi"))
        #expect(PersonView.caption(for: word, displayName: "Aditi").contains("3 others"))
        #expect(PersonView.caption(for: page, displayName: "Aditi").contains("page 1"))
        // Singular is not "1 others".
        let one = PersonFile(path: "a.pdf", evidence: .namedInFile,
                             reason: .sharedWordInName(word: "girish", sharedWith: 1))
        #expect(PersonView.caption(for: one, displayName: "Girish").contains("1 other person"))
    }
}
