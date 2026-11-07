import Testing
import SwiftUI
@testable import FileExplorer
@testable import Sync

/// The Restructure card rules (the kind tag, the subtitle, the blast radius, the scaffold line and
/// the crowding strip's words), asserted as values the way `cleanTitle`/`revealTitle` are.
@Suite struct RestructureLensKindTests {

    /// Every kind has a label and a verb, and no two share a label: a mixed list is sorted by eye,
    /// and two kinds wearing one word would read as one.
    @Test func everyKindHasADistinctLabelAndAVerb() {
        var labels = Set<String>()
        for kind in FindingKind.allCases {
            let label = RestructureLens.kindLabel(kind)
            #expect(!label.isEmpty)
            #expect(labels.insert(label).inserted, "\(kind.rawValue) shares a label")
            #expect(!RestructureLens.kindVerb(kind).isEmpty)
        }
    }

    /// Every kind has a real symbol too, and no two share one: the glyph lets a mixed list sort by
    /// eye before it is read.
    @Test func everyKindHasADistinctSymbol() {
        var symbols = Set<String>()
        for kind in FindingKind.allCases {
            let symbol = RestructureLens.kindSymbol(kind)
            #expect(!symbol.isEmpty)
            #expect(symbols.insert(symbol).inserted, "\(kind.rawValue) shares a symbol")
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "\(symbol) is not a real SF Symbol — it would render as a blank square")
        }
    }

    /// The tint answers the same question the Plan button does. `carriesPlan` is the rail badge's
    /// wider rule and counts `duplicatedTaxonomy`, which has no plan surface, so tinting on it
    /// would promise a plan the card doesn't offer.
    @Test func theGlyphTakesTheAccentExactlyWhenTheCardOffersSomething() {
        for kind in FindingKind.allCases {
            let tinted = RestructureLens.glyphTakesAccent(kind)
            if kind == .backlog {
                #expect(tinted, "its card ends in the scaffold landing")
                continue
            }
            #expect(tinted == RestructurePlanRouting.carriesPlanSurface(
                StructureFinding(kind: kind, family: "F", subject: "F/x",
                                 detail: Self.detail(for: kind))),
                    "\(kind.rawValue) tints differently from how it acts")
        }
        #expect(!RestructureLens.glyphTakesAccent(.duplicatedTaxonomy),
                "carriesPlan says true; there is no plan surface until §5.9 is measured")
        #expect(FindingKind.duplicatedTaxonomy.carriesPlan,
                "and this is the difference the rule exists to hold apart")
    }

    /// The tooltip answers the same question the tint does. `kindVerb` is the glyph's `.help`, so
    /// a kind with no plan surface must not open on an operation, which a reader takes as an
    /// offer; it says it reports. A rule over the whole table, not a pin on one kind. `backlog` is
    /// exempt: its card ends in the scaffold landing, so "Creates folders" is a promise it keeps.
    @Test func aKindWithNoPlanSurfaceDoesNotNameAnOperationInItsTooltip() {
        // The words that read as an offer, in the third-person present every acting verb in the
        // table takes ("Renames or merges folders").
        let operations = ["Renames", "Merges", "Creates", "Moves", "Removes", "Deletes"]
        for kind in FindingKind.allCases where kind != .backlog {
            let finding = StructureFinding(kind: kind, family: "F", subject: "F/x",
                                           detail: Self.detail(for: kind))
            guard !RestructurePlanRouting.carriesPlanSurface(finding) else { continue }
            let verb = RestructureLens.kindVerb(kind)
            for operation in operations {
                #expect(!verb.hasPrefix(operation),
                        "\(kind.rawValue) has no plan surface, and its tooltip opens \"\(verb)\" — a reader takes that as an offer the card cannot honour")
            }
        }
        // The kind most at risk, pinned by value so a reword can't quietly re-promise a plan.
        #expect(RestructureLens.kindVerb(.duplicatedTaxonomy) == "Reports the pair — no plan yet")
        // Positive control: a kind that does act still names its operation, so the loop skips on
        // the plan surface rather than finding nothing to test.
        #expect(RestructureLens.kindVerb(.shape).hasPrefix("Renames"))
        #expect(RestructurePlanRouting.carriesPlanSurface(
            StructureFinding(kind: .shape, family: "F", subject: "F")))
    }

    /// A detail that makes each kind's route resolvable, so the comparison above is real.
    private static func detail(for kind: FindingKind) -> StructureFinding.Detail? {
        switch kind {
        case .shape, .deadWeight, .ask: return nil
        case .backlog: return .backlog(scaffold: ["a"], looseFiles: 1)
        case .shadowAxis: return .shadowAxis(target: "2024", targetExists: false)
        case .echoName: return .echoName(counterpart: "F/y", relation: .sibling)
        case .mirroredInbox: return .mirroredInbox(destination: "G/x")
        case .looseAboveSeries: return .looseAboveSeries(looseFiles: 2, seriesFolders: 3)
        case .looseBesideContainer: return .looseBesideContainer(container: "F/c")
        case .duplicatedTaxonomy: return .duplicatedTaxonomy(counterpart: "G/x",
                                                             matchedDocuments: 5)
        }
    }

    /// Distinct is not the same as right: swapping two symbols passes a distinctness check, so
    /// the ones the eye uses most are pinned.
    @Test func theGlyphsMeanWhatTheyName() {
        #expect(RestructureLens.kindSymbol(.shape) == "square.on.square.dashed")
        #expect(RestructureLens.kindSymbol(.backlog) == "calendar.badge.plus")
        #expect(RestructureLens.kindSymbol(.echoName) == "doc.on.doc")
        #expect(RestructureLens.kindSymbol(.deadWeight) == "wind")
    }

    /// The glyph is tinted; the label is not. Accent on 9.5pt text is the contrast trap the
    /// repo's amber-on-body-text rule exists for, so this pins the call site.
    @Test func theTagTintsItsGlyphAndNeverItsText() throws {
        let text = try SourceText.fileExplorer("RestructureLens.swift")
        // To the end of the function, not a byte count, so a comment added inside `kindTag` can't
        // push the accent line out of the window.
        let body = try SourceText.body(of: "private func kindTag(_ kind: FindingKind)", in: text)
        let glyph = try #require(body.range(of: "Image(systemName: Self.kindSymbol(kind))"))
        let label = try #require(body.range(of: "Text(Self.kindLabel(kind))"))
        let accent = try #require(body.range(of: "AnyShapeStyle(accent)"))
        #expect(accent.lowerBound > glyph.lowerBound && accent.lowerBound < label.lowerBound,
                "the accent belongs to the glyph, above the label")
        #expect(body[label.lowerBound...].prefix(200).contains("foregroundStyle(.secondary)"),
                "the label keeps the quiet treatment")
    }

    /// The blast radius states the honest cost: renames only for a one-to-one family, merges for
    /// unequal shapes.
    @Test func theShapeBlastRadiusTellsRenamesFromMerges() {
        let oneToOne = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["application"], members: ["2016", "2019"]),
                      .init(vocabulary: ["petition"], members: ["2021", "2024"])])
        #expect(RestructureLens.blastRadius(for: oneToOne)
            == "A plan here is folder renames — no file would move.")

        let unequal = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["federal", "state"], members: ["2013", "2014"]),
                      .init(vocabulary: ["forms", "reference", "refund"], members: ["2016", "2017"])])
        #expect(RestructureLens.blastRadius(for: unequal)
            == "Converging these shapes needs merges — files would move.")

        // A scheme with no shared vocabulary can't promise a bijection, whatever the sizes say.
        let hollow = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: [], members: ["2016", "2017"]),
                      .init(vocabulary: [], members: ["2013", "2014"])])
        #expect(RestructureLens.blastRadius(for: hollow)
            == "Converging these shapes needs merges — files would move.")
    }

    @Test func theShadowAxisSentencesFollowWhetherTheYearExists() {
        let merge = StructureFinding(kind: .shadowAxis, family: "Tax", subject: "Tax/IRS Docs - 2023",
                                     detail: .shadowAxis(target: "2023", targetExists: true))
        #expect(RestructureLens.subtitle(for: merge)
            == "hides the year 2023, which exists beside it")
        #expect(RestructureLens.blastRadius(for: merge)?.contains("merge") == true)

        let rename = StructureFinding(kind: .shadowAxis, family: "T", subject: "T/2023 (Family)",
                                      detail: .shadowAxis(target: "2023", targetExists: false))
        #expect(RestructureLens.blastRadius(for: rename)?.contains("rename") == true)
        #expect(RestructureLens.blastRadius(for: rename)?.contains("no file would move") == true)
    }

    /// The scaffold line says what it would create, or that there is nothing to copy; an empty
    /// scaffold never claims "creates folders only".
    @Test func theScaffoldLineSaysWhatItWouldCreateOrThatItCannot() {
        let scaffolded = StructureFinding(kind: .backlog, family: "H", subject: "H/2025",
                                          detail: .backlog(scaffold: ["Claims", "Statements"],
                                                           looseFiles: 2))
        let line = RestructureLens.scaffoldLine(for: scaffolded)
        #expect(line?.members == "Claims, Statements")
        #expect(RestructureLens.blastRadius(for: scaffolded)?.contains("Creates folders only") == true)

        let bare = StructureFinding(kind: .backlog, family: "H", subject: "H/2025",
                                    detail: .backlog(scaffold: [], looseFiles: 2))
        #expect(RestructureLens.scaffoldLine(for: bare)?.note.contains("no shared shape") == true)
        #expect(RestructureLens.blastRadius(for: bare) == nil)

        #expect(RestructureLens.scaffoldLine(for: StructureFinding(family: "F", schemes: [])) == nil)
    }

    @Test func theEchoSubtitleNamesTheCounterpartAndItsRelation() {
        let sibling = StructureFinding(kind: .echoName, family: "Forms", subject: "Forms/Form W2",
                                       detail: .echoName(counterpart: "Forms/Form W-2",
                                                         relation: .sibling))
        #expect(RestructureLens.subtitle(for: sibling) == "echoes Form W-2 beside it")

        let parent = StructureFinding(kind: .echoName, family: "Utilities/ACI",
                                      subject: "Utilities/ACI/ACI",
                                      detail: .echoName(counterpart: "Utilities/ACI",
                                                        relation: .parentChild))
        #expect(RestructureLens.subtitle(for: parent) == "echoes its parent, ACI")
    }

    /// The crowding strip's words: counts in the chips, reasons in the help. The empties' help
    /// points at the button under the list, and is pinned against both false wordings: that Apply
    /// removes them, and that removing them is a job for Finder.
    @Test func theCrowdingStripSaysWhyOnlyEmptiesGetAnAction() {
        #expect(RestructureLens.crowdingLabel(.passThrough, count: 86) == "86 pass-through")
        #expect(RestructureLens.crowdingLabel(.singleFileLeaf, count: 503) == "503 single-file")
        #expect(RestructureLens.crowdingLabel(.empty, count: 20) == "20 empty")

        #expect(RestructureLens.crowdingHelp(.passThrough).contains("Report-only"))
        #expect(RestructureLens.crowdingHelp(.singleFileLeaf).contains("Report-only"))
        let empties = RestructureLens.crowdingHelp(.empty)
        #expect(empties.contains("Open the list"),
                "the help points at the control that exists")
        #expect(empties.contains("Trash"), "the Trash-only rule is the reassurance")
        #expect(!empties.contains("when Apply lands"),
                "the false promise must not come back — the button exists now")
        #expect(!empties.contains("call to make in Finder"),
                "nor the sentence that outlived the route being built")
    }

    /// The subtitle counts the whole family, drift and shapeless members included.
    @Test func theShapeSubtitleCountsTheWholeFamily() {
        let finding = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["a"], members: ["1", "2"]),
                      .init(vocabulary: ["b"], members: ["3", "4"])],
            drift: ["5"], shapeless: ["6"])
        #expect(RestructureLens.subtitle(for: finding) == "6 folders, 2 internal shapes")
    }
}

/// Restructure's member column shows the whole list on hover. The members sharing a shape are the
/// finding itself, and the narrow two-line column cuts them off past about four names, so both
/// rows that draw a member list carry it whole in `.help`.
@Suite struct RestructureMemberColumnTests {
    @Test func bothMemberRowsCarryTheWholeListAsATooltip() throws {
        let lens = try SourceText.fileExplorer("RestructureLens.swift")
        let scheme = try SourceText.body(
            of: "private func schemeRow(_ scheme: StructureFinding.Scheme) -> some View {", in: lens)
        #expect(scheme.contains("let members = scheme.members.joined(separator: \", \")"))
        #expect(scheme.contains("Text(members)") && scheme.contains(".help(members)"),
                "the shape row's member list has no tooltip")
        let extra = try SourceText.body(
            of: "private func extraRow(members: String, note: String) -> some View {", in: lens)
        #expect(extra.contains(".help(members)"), "the drift row's member list has no tooltip")
    }
}
