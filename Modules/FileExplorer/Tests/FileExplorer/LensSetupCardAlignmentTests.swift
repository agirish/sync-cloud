import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
@testable import Sync

/// Every lens's before-scan card, rendered and read back, to check the one thing they share: they
/// all start at the same height.
///
/// ## Why pixels
///
/// The failure to catch is a lens quietly opening lower than the others, and nothing in the view
/// tree need say so: a sibling row outside a card (To File's cloud spend row, placed above it, was one
/// until TE335 retired it) can push it down while the card's own geometry is right. So this measures the composed screen as a
/// person sees it: render the pane, find the topmost row of ink, and require the lenses to agree.
/// `firstInkRow` measures paint, not frames: a header laid out at y=30 and drawn nowhere reads as
/// no ink at all.
///
/// The rendering tests are `.machinePinned(.pixelSampling)`: they read pixels out of a live renderer.
@MainActor
@Suite(.serialized) struct LensSetupCardAlignmentTests {

    static let canvas = CGSize(width: 900, height: 620)
    /// The pane backdrop, a flat colour rather than a material: what is measured is where ink
    /// starts, and a material's own gradient is ink everywhere.
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

    /// To File's setup card as the lens draws it.
    static func toFilePane() -> some View {
        FilingSetupCard(
            intro: LensIntros.organize(scanTargetName: "Naming Ceremony"),
            accent: .blue,
            onStart: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Restructure with no survey: the one card with no trigger at all, because nothing in the app
    /// can build a folder profile (see `RestructureLens.noProfileState`). So it is left out of
    /// `everyLensTriggerLandsAtTheSameHeight`, which measures triggers;
    /// `restructureDrawsItsCardWithoutATrigger` covers it instead.
    static func restructurePane() -> some View {
        RestructureLens(findings: [], hasProfile: false, folderCount: nil,
                        providerName: "iCloud", accent: .blue, onReveal: { _ in },
                        hasReviewed: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Restructure with a survey and the launch gate still shut: the reveal card, the state with a
    /// secondary button and a footnote. Its trigger row must still land on every other lens's line.
    static func restructureReadyPane(findings: [StructureFinding] = [Self.finding()],
                                     refresh: Bool = true) -> some View {
        RestructureLens(findings: findings, hasProfile: true, folderCount: 3_013,
                        providerName: "iCloud", accent: .blue, onReveal: { _ in },
                        hasReviewed: false, onReview: {},
                        onUpdateSurvey: refresh ? {} : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func finding(family: String = "Family/Daughter/Events") -> StructureFinding {
        StructureFinding(family: family, schemes: [
            .init(vocabulary: ["Photos", "Invitations"], members: ["Naming Ceremony", "Birthday"]),
            .init(vocabulary: [], members: ["Graduation"]),
        ])
    }

    /// Rules as `AutomationsLens` composes it: the real lens with no rules written, so the wording
    /// and trigger under test are the ones the app draws.
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
            // Materials desaturate when the window isn't key, and a borderless test window never
            // is: the same pin `CommandPaletteRenderTests` documents and the real window sets.
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
    /// Returns nil for a blank render, which is a broken harness, never a pass; the callers say so
    /// rather than treating "no ink" as "aligned".
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

    /// The topmost row carrying the accent fill: in practice the top of the trigger button, the
    /// only saturated blue on these cards.
    ///
    /// This is what the header-height claim needs. Where a card starts (its icon and title) is the
    /// same whatever the prose does; a message wrapping to a third line moves everything below it.
    /// It looks for a wide band of accent, not the first accent pixel: the header icon is accent
    /// too, so "topmost blue" would find the icon on every card and pass whatever the prose did.
    /// The trigger is a filled capsule over a hundred points across; the icon is thirty-four.
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

    /// The header block is the same height on every lens, so the whole card lines up, not just its
    /// first pixel.
    ///
    /// The budget is two lines of message and one of safety. A longer message or safety line puts
    /// that lens's trigger a full line below the rest, and prose is edited by people not looking at
    /// five screens side by side, so the check lives here. Rules is included though it has no scan:
    /// its trigger writes the first rule, and it sits in the same rail.
    @Test(.machinePinned(.pixelSampling)) func everyLensTriggerLandsAtTheSameHeight() {
        let panes: [(String, Int?)] = [
            ("To File", Self.firstAccentRow(Self.render(Self.toFilePane()))),
            ("Duplicates", Self.firstAccentRow(Self.render(Self.duplicatesPane()))),
            ("Renames", Self.firstAccentRow(Self.render(Self.renamesPane()))),
            // Restructure's reveal card, not its no-survey one, which has no trigger to measure.
            // This card also has a second button beside the trigger and a footnote under the
            // samples, both places a stray point of padding would take it off the line.
            ("Restructure", Self.firstAccentRow(Self.render(Self.restructureReadyPane()))),
            ("Rules", Self.firstAccentRow(Self.render(Self.rulesPane()))),
            ("Storage", Self.firstAccentRow(Self.render(Self.storagePane()))),
        ]
        for (name, row) in panes {
            #expect(row != nil, """
                    \(name) drew no trigger band — either the button is missing or this harness \
                    stopped recognising it, and neither is an aligned card.
                    """)
        }
        let rows = panes.compactMap(\.1)
        guard let first = rows.first else { return }
        for ((name, _), row) in zip(panes, rows) {
            #expect(abs(row - first) <= 2, """
                    \(name)'s trigger starts at \(row)pt against To File's \(first)pt — its \
                    header is a line taller or shorter than the rest. Keep the message to two \
                    lines and the safety contract to one.
                    """)
        }
    }

    @Test(.machinePinned(.pixelSampling)) func everyLensOpensAtTheSameHeight() {
        let panes: [(String, Int?)] = [
            ("To File", Self.firstInkRow(Self.render(Self.toFilePane()))),
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
            // 2pt, not 0: antialiasing on a glyph's top edge can land a hair either way, and a
            // misplaced row is far more.
            #expect(abs(row - first) <= 2,
                    "\(name) opens at \(row)pt, To File at \(first)pt — the cards must line up")
        }
    }

    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        return PixelDiff.differingPixels(a, b, tolerance: 0.01)
    }

    /// The no-survey card draws no trigger, and still draws everything else.
    ///
    /// It has no button because nothing in the app can produce a folder profile, so any button
    /// would land the user somewhere that can't help. But "no button" must not become "no card":
    /// the pitch, samples and note remain, and a state collapsed to a bare header would satisfy a
    /// test that only checked the button was gone.
    @Test(.machinePinned(.pixelSampling)) func restructureDrawsItsCardWithoutATrigger() {
        let noSurvey = Self.render(Self.restructurePane())
        #expect(Self.firstInkRow(noSurvey) != nil, "the no-survey card drew nothing at all")
        // No accent band: `firstAccentRow` only reports a run wide enough to be a filled control,
        // so the header icon doesn't trip it. A hit here is a button that shouldn't exist.
        #expect(Self.firstAccentRow(noSurvey) == nil, """
                The no-survey card drew a trigger. Nothing in the app can build a folder survey, \
                so any button here lands the user somewhere that cannot help.
                """)
        // And it is still a card: compared with the same lens with a survey and a reveal trigger.
        // Equal renders would mean one of the two draws nothing.
        let ready = Self.render(Self.restructureReadyPane())
        #expect(Self.differingPixels(noSurvey, ready) > 1_000)
        // The floor as well as the ceiling: the samples and note carry real ink of their own, well
        // past what a lone header and two sentences would.
        #expect(Self.inkPixels(noSurvey) > 3_000, """
                The no-survey card inked \(Self.inkPixels(noSurvey)) — too little for a card with \
                a sample finding and a note under it; it has collapsed to a header.
                """)
    }

    /// Pixels differing from the flat backdrop: the card's own ink.
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
