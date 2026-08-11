import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
@testable import Sync

/// Every lens's before-scan card, **rendered and read back**, to check the one thing they are
/// supposed to share: they all start at the same height.
///
/// ## Why pixels
///
/// The claim is "these five screens open identically", and the failure it exists to catch is a
/// lens quietly opening lower than the others — which is exactly what To File did once the cloud
/// spend row landed above its card. Nothing in the view tree says so: the card's own geometry was
/// always right, and it was a sibling row *outside* it that pushed it down. A test that measured
/// the card would have passed while the screen was wrong.
///
/// So this measures the composed screen the way a person sees it: render the pane, find the
/// topmost row of ink, and require the five to agree. `firstInkRow` is a paint measurement, not a
/// frame one — a header laid out at y=30 and drawn nowhere reads as no ink at all.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels out of a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct LensSetupCardAlignmentTests {

    static let canvas = CGSize(width: 900, height: 620)
    /// The pane backdrop, deliberately a flat colour rather than a material: what is being
    /// measured is where ink starts, and a material's own gradient is ink everywhere.
    static let backdrop = Color(red: 0.96, green: 0.965, blue: 0.97)

    // MARK: The five cards, each as its lens actually composes it

    /// A card in the dress every lens's pane gives it. `footnote` is the To File case.
    static func card<Samples: View>(intro: LensIntro, footnote: AnyView? = nil,
                                    @ViewBuilder samples: @escaping () -> Samples) -> some View {
        LensSetupCard(intro: intro, accent: .blue,
                      triggerTitle: "Trigger", triggerSymbol: "wand.and.stars",
                      triggerHelp: "help", samplesTitle: "What a finding looks like",
                      samplesAccessibility: "samples", onStart: {}, footnote: footnote,
                      samples: samples)
    }

    static func sample(_ text: String) -> some View {
        LensSetupSampleRow { Text(text).scaledFont(.caption) }
    }

    /// To File **as `filingContent` composes it** — the spend row and the card in one column, in
    /// the order the lens puts them. This is the subject that regressed; rendering
    /// `FilingSetupCard` alone would measure the half that was never wrong.
    /// **Driven by the real placement rule**, not by a bool this file chose: `filingContent` and
    /// `filingIntroState` both branch on `TidyView.spendRowPlacement`, so a change that put the
    /// row back above the card changes what this renders and the alignment test goes red. Passing
    /// the placement in directly is the only reconstruction left, and
    /// `theSetupCardStatePutsTheSpendRowUnderneath` below pins that to the rule too.
    static func toFilePane(_ placement: TidyView.SpendRowPlacement) -> some View {
        VStack(spacing: 0) {
            if placement == .aboveTheList {
                spendRow.padding(.horizontal, 12).padding(.top, 10)
            }
            FilingSetupCard(
                intro: LensIntros.organize(scanTargetName: "Naming Ceremony"),
                accent: .blue,
                footnote: placement == .underTheSetupCard
                    ? AnyView(spendRow.padding(.top, 2))
                    : nil,
                onStart: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Stands in for `TidyView.filingSpendRow` — same fonts, same shape, same two trailing
    /// controls. It cannot be reached from here (it is a private member of a view that needs a
    /// live manager), so it is rebuilt at the size that matters: its height.
    static var spendRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud").scaledFont(.system(size: 10))
            Text("Last cloud scan: Opus · 1 file · 4.7k tok · ~$0.04").lineLimit(1)
            Spacer(minLength: 8)
            Text("Total ~$0.24")
            Button("History") {}.controlSize(.mini)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    static func duplicatesPane() -> some View {
        card(intro: LensIntros.duplicates(targetName: "Documents")) {
            sample("Identical · Wedding Gifts.pdf · 2 copies")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func renamesPane() -> some View {
        card(intro: LensIntros.renames(providerName: "iCloud")) {
            sample("to fix · Tax: 2024?.pdf → Tax - 2024.pdf")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Restructure with no survey — the one card in the set with **no trigger at all**, because
    /// nothing in the app can build a folder profile (see `RestructureLens.noProfileState`). It
    /// is therefore excluded from `everyLensTriggerLandsAtTheSameHeight`, which measures triggers;
    /// `restructureDrawsItsCardWithoutATrigger` is what covers it instead.
    static func restructurePane() -> some View {
        RestructureLens(findings: [], hasProfile: false, folderCount: nil,
                        providerName: "iCloud", accent: .blue, onReveal: { _ in },
                        hasReviewed: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Restructure with a survey behind it and the launch gate still shut — the reveal card,
    /// which is the state that carries a secondary button and a footnote. Its trigger row has to
    /// land on the same line as every other lens's despite both.
    static func restructureReadyPane(findings: [StructureFinding] = [Self.finding()],
                                     refresh: Bool = true) -> some View {
        RestructureLens(findings: findings, hasProfile: true, folderCount: 3_013,
                        providerName: "iCloud", accent: .blue, onReveal: { _ in },
                        hasReviewed: false, onReview: {},
                        onUpdateSurvey: refresh ? {} : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func finding(family: String = "Family/Aditi/Events") -> StructureFinding {
        StructureFinding(family: family, schemes: [
            .init(vocabulary: ["Photos", "Invitations"], members: ["Naming Ceremony", "Birthday"]),
            .init(vocabulary: [], members: ["Graduation"]),
        ])
    }

    /// Rules **as `AutomationsLens` composes it** — the real lens with no rules written, so the
    /// wording and the trigger under test are the ones the app draws.
    static func rulesPane() -> some View {
        AutomationsLens(syncManager: FileSyncManager(), state: AutomationsLensState(), rules: [],
                        providerName: "iCloud", destinationRoot: nil,
                        onReveal: { _ in }, onPreview: { _ in })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func storagePane() -> some View {
        card(intro: LensIntros.storage(providerName: "iCloud")) {
            sample("Photos · 12.4 GB")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Rendering

    static func render<V: View>(_ subject: V, scheme: ColorScheme = .light) -> NSBitmapImageRep {
        let wrapped = subject
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            .background(backdrop)
            .environment(\.colorScheme, scheme)
            // Materials desaturate when the window is not key and a borderless test window never
            // is — the same pin `CommandPaletteRenderTests` documents and the real window sets.
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(wrapped))
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The topmost row holding ink, in points from the top of the pane.
    ///
    /// Returns nil for a blank render — which is a broken harness, never a passing result, and
    /// the callers say so rather than treating "no ink" as "aligned".
    static func firstInkRow(_ rep: NSBitmapImageRep, threshold: Double = 0.06) -> Int? {
        let scale = rep.pixelsHigh / Int(canvas.height)
        guard let base = rep.colorAt(x: 2, y: 2) else { return nil }
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let px = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(px.redComponent - base.redComponent)
                    + abs(px.greenComponent - base.greenComponent)
                    + abs(px.blueComponent - base.blueComponent)
                if delta > threshold { return y / max(scale, 1) }
            }
        }
        return nil
    }

    /// The topmost row carrying the accent fill — in practice the top of the trigger button,
    /// which is the only saturated blue on these cards.
    ///
    /// **This is the measurement the header-height claim needs.** Where a card *starts* is the
    /// top of its icon and title, and that is identical whatever the prose does; what moves is
    /// everything below a message that wrapped to a third line. Two cards can begin at the same
    /// pixel and still look unaligned all the way down, which is exactly what Renames did.
    /// **A wide BAND of accent, not the first accent pixel.** The header icon is drawn in the
    /// accent too, so "topmost blue" finds the icon on every card — a row that never moves,
    /// which would make this pass no matter what the prose did. The trigger is a filled capsule
    /// over a hundred points across; the icon is thirty-four. The width is what tells them apart.
    static func firstAccentRow(_ rep: NSBitmapImageRep, minRun: Int = 70) -> Int? {
        let scale = max(rep.pixelsHigh / Int(canvas.height), 1)
        for y in 0..<rep.pixelsHigh {
            var accent = 0
            for x in 0..<rep.pixelsWide {
                guard let px = rep.colorAt(x: x, y: y) else { continue }
                // Saturated blue: blue clearly dominant and bright enough to be fill rather than
                // the antialiased edge of grey text.
                if px.blueComponent > 0.6, px.blueComponent - px.redComponent > 0.35 { accent += 1 }
            }
            if accent >= minRun * scale { return y / scale }
        }
        return nil
    }

    // MARK: The claims

    /// The header block is the same height on every lens, so the whole card lines up — not just
    /// its first pixel.
    ///
    /// The budget is **two lines of message and one of safety**, and it is a real constraint
    /// rather than a style note: Renames' three-line message put its trigger a full line below
    /// everyone else's, and Restructure's, Rules' and Storage's two-line safety lines did the
    /// same. Prose is the only thing that can break this, and prose is edited by people who are
    /// not looking at five screens side by side — so the check is here rather than in a comment.
    ///
    /// Rules is included even though it is a lens with no scan: its trigger writes the first
    /// rule, and it sits in the same rail.
    @Test func everyLensTriggerLandsAtTheSameHeight() {
        let panes: [(String, Int?)] = [
            ("To File", Self.firstAccentRow(Self.render(Self.toFilePane(.underTheSetupCard)))),
            ("Duplicates", Self.firstAccentRow(Self.render(Self.duplicatesPane()))),
            ("Renames", Self.firstAccentRow(Self.render(Self.renamesPane()))),
            // Restructure's REVEAL card, not its no-survey one — that state deliberately has no
            // trigger to measure (`restructureDrawsItsCardWithoutATrigger` covers it). This is
            // also the one card with a second button beside the trigger and a footnote under the
            // samples, both places a stray point of padding would take it off the line.
            ("Restructure", Self.firstAccentRow(Self.render(Self.restructureReadyPane()))),
            ("Rules", Self.firstAccentRow(Self.render(Self.rulesPane()))),
            ("Storage", Self.firstAccentRow(Self.render(Self.storagePane()))),
        ]
        for (name, row) in panes {
            #expect(row != nil, """
                    \\(name) drew no trigger band — either the button is missing or this harness \\
                    stopped recognising it, and neither is an aligned card.
                    """)
        }
        let rows = panes.compactMap(\.1)
        guard let first = rows.first else { return }
        for ((name, _), row) in zip(panes, rows) {
            #expect(abs(row - first) <= 2, """
                    \\(name)'s trigger starts at \\(row)pt against To File's \\(first)pt — its \\
                    header is a line taller or shorter than the rest. Keep the message to two \\
                    lines and the safety contract to one.
                    """)
        }
    }

    @Test func everyLensOpensAtTheSameHeight() {
        let panes: [(String, Int?)] = [
            ("To File", Self.firstInkRow(Self.render(Self.toFilePane(.underTheSetupCard)))),
            ("Duplicates", Self.firstInkRow(Self.render(Self.duplicatesPane()))),
            ("Renames", Self.firstInkRow(Self.render(Self.renamesPane()))),
            ("Restructure", Self.firstInkRow(Self.render(Self.restructureReadyPane()))),
            ("Restructure (no survey)", Self.firstInkRow(Self.render(Self.restructurePane()))),
            ("Rules", Self.firstInkRow(Self.render(Self.rulesPane()))),
            ("Storage", Self.firstInkRow(Self.render(Self.storagePane()))),
        ]
        for (name, row) in panes {
            #expect(row != nil, "\(name) rendered blank — the harness is broken, not aligned")
        }
        let rows = panes.compactMap(\.1)
        guard let first = rows.first else { return }
        for ((name, _), row) in zip(panes, rows) {
            // 2pt, not 0: antialiasing on a glyph's top edge can land a hair either way, and the
            // regression this guards against was 28pt.
            #expect(abs(row - first) <= 2,
                    "\(name) opens at \(row)pt, To File at \(first)pt — the cards must line up")
        }
    }

    /// The harness could have failed: the old composition, measured the same way, does not align.
    ///
    /// Without this, `everyLensOpensAtTheSameHeight` is a test whose passing proves nothing —
    /// a `firstInkRow` that always returned the same number for every input would satisfy it.
    /// This renders To File **as it was** (spend row above the card) and requires the gap to be
    /// real and large.
    @Test func theSpendRowAboveTheCardIsWhatMisalignedIt() {
        guard let broken = Self.firstInkRow(Self.render(Self.toFilePane(.aboveTheList))),
              let fixed = Self.firstInkRow(Self.render(Self.toFilePane(.underTheSetupCard))),
              let reference = Self.firstInkRow(Self.render(Self.duplicatesPane())) else {
            Issue.record("blank render — harness broken")
            return
        }
        #expect(broken < reference - 5, """
                The spend row above the card starts ink at \(broken)pt against Duplicates' \
                \(reference)pt — too close for this harness to have seen the 28pt regression \
                the sibling test claims to prevent.
                """)
        #expect(abs(fixed - reference) <= 2)
    }

    /// The footnote did not simply get dropped: moving it under the card has to keep it drawn.
    ///
    /// Ink counts, because "is the spend row still on screen" is a paint question — an
    /// `AnyView?` left nil, or a footnote laid out past the scroll content, both leave a card
    /// that measures correct and tells the user nothing about what their last scan cost.
    @Test func theSpendFootnoteStillDrawsUnderTheCard() {
        let with = Self.render(Self.toFilePane(.underTheSetupCard))
        let without = Self.render(
            FilingSetupCard(intro: LensIntros.organize(scanTargetName: "Naming Ceremony"),
                            accent: .blue, footnote: nil, onStart: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        let differing = Self.differingPixels(with, without)
        #expect(differing > 400, """
                Only \(differing) pixels differ with the spend footnote and without it — the \
                footnote is not being drawn.
                """)
    }

    /// The placement rule itself, so the renders above are rendering what the lens does.
    ///
    /// The pixels prove "under the card lines up and above it doesn't". This is the other half:
    /// that the setup-card state really asks for `.underTheSetupCard`. Without it the render
    /// tests are a statement about two compositions, one of which the app might not use.
    @Test func theSetupCardStatePutsTheSpendRowUnderneath() {
        #expect(TidyView.spendRowPlacement(scansOnRecord: 4, showsSetupCard: true)
                == .underTheSetupCard)
        #expect(TidyView.spendRowPlacement(scansOnRecord: 4, showsSetupCard: false)
                == .aboveTheList)
        // A machine that has never run a cloud pass gets no row in either state — a footnote
        // about nothing, and the case that would otherwise read as "aligned" for the wrong
        // reason.
        #expect(TidyView.spendRowPlacement(scansOnRecord: 0, showsSetupCard: true) == .hidden)
        #expect(TidyView.spendRowPlacement(scansOnRecord: 0, showsSetupCard: false) == .hidden)
    }

    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                if abs(pa.redComponent - pb.redComponent) > 0.01
                    || abs(pa.greenComponent - pb.greenComponent) > 0.01
                    || abs(pa.blueComponent - pb.blueComponent) > 0.01 { differing += 1 }
            }
        }
        return differing
    }

    /// The no-survey card **draws no trigger, and still draws everything else.**
    ///
    /// Both halves matter. It carries no button because nothing in the app can produce a folder
    /// profile, and the button that used to be here pointed at a Settings tab with no survey
    /// control on it. But "no button" must not have quietly become "no card": the pitch, the
    /// samples and the note are what is left, and a state that collapsed to a bare header would
    /// satisfy a test that only checked the button was gone.
    @Test func restructureDrawsItsCardWithoutATrigger() {
        let noSurvey = Self.render(Self.restructurePane())
        #expect(Self.firstInkRow(noSurvey) != nil, "the no-survey card drew nothing at all")
        // No accent band: `firstAccentRow` only reports a run wide enough to be a filled control,
        // so the header icon does not trip it. A hit here is a button that should not exist.
        #expect(Self.firstAccentRow(noSurvey) == nil, """
                The no-survey card drew a trigger. Nothing in the app can build a folder survey, \
                so any button here lands the user somewhere that cannot help.
                """)
        // And it is still a card: compare against the same lens with a survey and a reveal
        // trigger. Equal renders would mean one of the two is drawing nothing.
        let ready = Self.render(Self.restructureReadyPane())
        #expect(Self.differingPixels(noSurvey, ready) > 1_000)
        // The floor as well as the ceiling — the samples and the note carry real ink of their own,
        // well past what a lone header and two sentences would.
        #expect(Self.inkPixels(noSurvey) > 3_000, """
                The no-survey card inked \(Self.inkPixels(noSurvey)) — too little for a card with \
                a sample finding and a note under it; it has collapsed to a header.
                """)
    }

    /// Pixels differing from the flat backdrop — the card's own ink.
    static func inkPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let base = rep.colorAt(x: 2, y: 2) else { return 0 }
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let px = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(px.redComponent - base.redComponent)
                    + abs(px.greenComponent - base.greenComponent)
                    + abs(px.blueComponent - base.blueComponent)
                if delta > 0.06 { ink += 1 }
            }
        }
        return ink
    }
}
