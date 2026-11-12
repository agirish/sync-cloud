import AppKit
import Events
import Design
import SwiftUI
import Sync

/// TE341's line above To File's cards: how often the first pick was kept in the last 30 days.
///
/// One line in every state, so a filing that changes the numbers never moves the cards below it.
struct FilingScorecardLine: View {
    @ObservedObject var store: FilingScorecardStore
    let accent: Color
    let onDetails: () -> Void
    let onHide: () -> Void

    var body: some View {
        let summary = store.summary(.days30)
        HStack(spacing: 12) {
            Self.text(summary, hasAny: store.hasAny)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("filingScorecardLine")
            Spacer(minLength: 8)
            Button("Details", action: onDetails)
                .buttonStyle(.link)
            Button("Hide", action: onHide)
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
        .scaledFont(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(accent.opacity(0.10)))
    }

    /// "First pick kept **15 of 28** · last 30 days", or the empty wording.
    static func text(_ s: FilingScorecard.Summary, hasAny: Bool) -> Text {
        guard s.all.total > 0 else { return Text(FilingScorecard.line(s, hasAny: hasAny)) }
        return Text("First pick kept ") + Text("\(s.all.kept) of \(s.all.total)").bold() + Text(" · last 30 days")
    }
}

/// The line, or after Hide the notice in its place, above To File's cards. The notice goes when
/// To File does (`onDisappear`), not when the line is swapped for it.
struct FilingScorecardSlot: View {
    @ObservedObject var store: FilingScorecardStore
    let accent: Color
    let inset: CGFloat
    @Binding var shown: Bool
    /// Hide was clicked here: the notice holds the line's place until To File is left.
    @Binding var justHidden: Bool
    let onDetails: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if shown {
                FilingScorecardLine(store: store, accent: accent, onDetails: onDetails, onHide: {
                    shown = false
                    justHidden = true
                    Logger.shared.info("Filing scorecard: hidden from To File")
                })
                .padding(.horizontal, inset)
                .padding(.top, 8)
            } else if justHidden {
                FilingScorecardHiddenNotice {
                    shown = true
                    justHidden = false
                }
                .padding(.horizontal, inset)
                .padding(.top, 8)
            }
        }
        .onDisappear { justHidden = false }
    }
}

/// What Hide leaves in the line's place until To File is left, so the cards don't jump under the
/// pointer as it goes, and the way back is said once.
struct FilingScorecardHiddenNotice: View {
    let onUndo: () -> Void

    static let message = "Scorecard hidden. Show it from View ▸ Filing Scorecard."

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.message).lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo).buttonStyle(.link)
        }
        .scaledFont(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.secondary.opacity(0.10)))
    }
}

// MARK: - Details

/// The Details sheet (decision NL): totals, then the bars that say where first picks go wrong,
/// then the files that went elsewhere.
struct FilingScorecardSheet: View {
    @ObservedObject var store: FilingScorecardStore
    @ObservedObject var session: LensWorkspaceSession
    let syncManager: FileSyncManager
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var range: FilingScorecard.Range = .days30
    @State private var showsAll = false
    @State private var ruleFor: String?
    /// Changes saved as a rule from here: their row goes.
    @State private var ruled: Set<String> = []
    @State private var rulesBefore = 0
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    static let shownChanges = 4
    static let kept = SemanticColor.success
    static let changed = SemanticColor.error.opacity(0.75)

    var body: some View {
        let s = store.summary(range)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(FilingScorecard.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accentedSegments(hue)
                Spacer()
                Button("Done") { dismiss() }
            }
            if s.all.total + s.refine.total + s.rules == 0 {
                Text("No filings in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if s.all.total > 0 {
                            tiles(s)
                            panels(s)
                            if !s.changes.isEmpty { changes(s) }
                        }
                        footer(s)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 620)
            }
        }
        .scaledFont(.system(size: 13))
        .monospacedDigit()
        .padding(18)
        .frame(width: 680)
    }

    private var deeper: Color { accent.opacity(0.55) }

    // MARK: Tiles

    private func tiles(_ s: FilingScorecard.Summary) -> some View {
        let pct = Int((Double(s.all.kept) / Double(s.all.total) * 100).rounded())
        return HStack(alignment: .top, spacing: 12) {
            tile("Kept", color: Self.kept) {
                (Text("\(s.all.kept)").font(.system(size: 24, weight: .semibold))
                 + Text("  of \(s.all.total) · \(pct)%").foregroundColor(.secondary))
            }
            tile("Deeper", color: deeper) { Text("\(s.all.deeper)").font(.system(size: 24, weight: .semibold)) }
            tile("Changed", color: Self.changed, sub: Self.changedSplit(s)) {
                Text("\(s.all.changed)").font(.system(size: 24, weight: .semibold))
            }
        }
    }

    /// Where the changed files went, naming only what happened: "runner-up 4 · other 3".
    static func changedSplit(_ s: FilingScorecard.Summary) -> String? {
        let parts = [("runner-up", s.runnerUp), ("your new folder", s.newFolder), ("other", s.other)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func tile(_ label: String, color: Color, sub: String? = nil,
                      @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                Text(label).foregroundStyle(.secondary).scaledFont(.system(size: 12))
            }
            value()
            if let sub { Text(sub).foregroundStyle(.secondary).scaledFont(.system(size: 12)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Panels

    @ViewBuilder
    private func panels(_ s: FilingScorecard.Summary) -> some View {
        let list: [(title: String, replay: Bool, rows: [FilingScorecard.Tally])] = [
            ("By update", false, s.byUpdate),
            ("By confidence", true, s.byConfidence),
            ("Picked by", false, s.byEvidence),
            ("By area", false, s.byArea),
        ].filter { !$0.rows.isEmpty }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 32, alignment: .top), GridItem(.flexible(), alignment: .top)],
                  alignment: .leading, spacing: 22) {
            ForEach(list, id: \.title) { panel in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        heading(panel.title)
                        if panel.replay {
                            HStack(spacing: 4) {
                                Rectangle().fill(.primary).frame(width: 2, height: 11)
                                Text("replay")
                            }
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(panel.rows) { row(_: $0) }
                }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }

    private func row(_ t: FilingScorecard.Tally) -> some View {
        HStack(spacing: 10) {
            Text(t.label).lineLimit(1).truncationMode(.tail).frame(width: 118, alignment: .leading)
            FilingScorecardBar(tally: t, deeper: deeper)
            Text("\(t.kept)/\(t.total)").foregroundStyle(.secondary).scaledFont(.system(size: 12))
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(t.label): kept \(t.kept) of \(t.total), deeper \(t.deeper), changed \(t.changed)")
    }

    // MARK: Changes

    private func changes(_ s: FilingScorecard.Summary) -> some View {
        let shown = showsAll ? s.changes : Array(s.changes.prefix(Self.shownChanges))
        let rows = VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider() }
                changeRow(r)
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                heading("Changed")
                Text("\(s.changes.count)").foregroundStyle(.secondary).scaledFont(.system(size: 11))
            }
            if showsAll {
                ScrollView { rows.padding(.horizontal, 10) }
                    .frame(maxHeight: 300)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color.secondary.opacity(0.3)))
            } else {
                rows
            }
            if s.changes.count > Self.shownChanges {
                Button(showsAll ? "Show Fewer" : "Show All") { showsAll.toggle() }
                    .buttonStyle(.link)
            }
            if let pair = s.repeats.first(where: { !ruled.contains(key($0)) }) { repeatRow(pair) }
        }
    }

    private func changeRow(_ r: FilingScorecard.Record) -> some View {
        HStack(spacing: 12) {
            Text(r.fileName).lineLimit(1).truncationMode(.middle)
                .frame(width: 210, alignment: .leading)
            (Text(FilingScorecard.display(r.offered ?? "", root: r.root)).strikethrough(color: SemanticColor.error)
             + Text(" → ")
             + Text(FilingScorecard.display(r.landed, root: r.root)).foregroundColor(.primary))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.at.formatted(.dateTime.day().month(.abbreviated)))
                .foregroundStyle(.secondary).scaledFont(.system(size: 12))
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { reveal(r) }
        .contextMenu { Button("Show in Finder") { reveal(r) } }
        .help(r.file)
    }

    private func reveal(_ r: FilingScorecard.Record) {
        let url = URL(fileURLWithPath: r.file)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.landed)])
        }
    }

    private func key(_ pair: FilingScorecard.Repeat) -> String { pair.offered + "\u{0}" + pair.landed }

    private func repeatRow(_ pair: FilingScorecard.Repeat) -> some View {
        HStack(spacing: 10) {
            Text("\(FilingScorecard.display(pair.offered, root: pair.latest.root)) → \(FilingScorecard.display(pair.landed, root: pair.latest.root)) · \(pair.count)×")
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Make a Rule…") { offerRule(pair) }
                .controlSize(.small)
                .popover(isPresented: Binding(get: { ruleFor == key(pair) }, set: { if !$0 { ruleFor = nil } }),
                         arrowEdge: .bottom) {
                    FilingRuleOfferPanel(session: session, syncManager: syncManager, accent: accent) {
                        if syncManager.automationRules.count > rulesBefore { ruled.insert(key(pair)) }
                        ruleFor = nil
                    }
                    .presentedNativeControlAccent()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(accent.opacity(0.10)))
    }

    /// The same offer a filing's "Save as rule…" makes, for the newest file of the pair.
    private func offerRule(_ pair: FilingScorecard.Repeat) {
        let r = pair.latest
        let rel = RuleOfferLogic.relativeToProviderRoot(r.landed, providerRoot: r.root)
        let date = (try? FileManager.default.attributesOfItem(atPath: r.file))?[.modificationDate] as? Date
        guard let proposal = syncManager.proposeAutomationRule(fileName: r.fileName, filePath: r.file,
                                                               destinationRelativePath: rel, modificationDate: date)
        else {
            syncManager.banner = .refusal("“\(r.fileName)” has nothing in its name a rule could match", log: .info)
            return
        }
        session.pendingRememberPrompt = nil
        session.ruleVariantChoice = proposal.defaultVariant
        session.pendingRuleOffer = RuleOffer(fileName: r.fileName, proposal: proposal, ridesOn: nil)
        rulesBefore = syncManager.automationRules.count
        ruleFor = key(pair)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ s: FilingScorecard.Summary) -> some View {
        let parts = [s.refine.total > 0 ? "Refine: \(s.refine.kept) of \(s.refine.total) kept" : nil,
                     s.rules > 0 ? "Filed from Rules: \(s.rules)" : nil].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).foregroundStyle(.secondary).scaledFont(.system(size: 12))
        }
    }
}

/// One group's split: kept, deeper, changed, with the replay's rate as a tick when it has one.
struct FilingScorecardBar: View {
    let tally: FilingScorecard.Tally
    let deeper: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, n = max(Double(tally.total), 1)
            HStack(spacing: 0) {
                Rectangle().fill(FilingScorecardSheet.kept).frame(width: w * Double(tally.kept) / n)
                Rectangle().fill(deeper).frame(width: w * Double(tally.deeper) / n)
                Rectangle().fill(FilingScorecardSheet.changed).frame(width: w * Double(tally.changed) / n)
            }
            .frame(width: w, height: geo.size.height, alignment: .leading)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 2))
            // An overlay, so the taller tick never makes the bar itself taller.
            .overlay(alignment: .leading) {
                if let replay = tally.replay {
                    Rectangle().fill(.primary).frame(width: 2, height: 15).offset(x: w * replay - 1)
                }
            }
        }
        .frame(height: 9)
    }
}
