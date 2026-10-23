import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// A file row shows its full name as a tooltip **only when the name is cut**, as Finder does.
///
/// Middle-truncated names in a narrow column could not be read by hovering: the row's only tooltip
/// was Edit's refusal. A name tooltip on every row would be worse — tooltips show after 300 ms
/// here, so one would pop up wherever the pointer rested — so the row measures whether its name is
/// actually truncated.
@MainActor
@Suite(.serialized) struct NameTruncationTooltipTests {

    // MARK: The tooltip rule

    @Test func aWholeNameGetsNoTooltip() {
        #expect(FileRowView.rowHelp(name: "Notes.txt", nameIsTruncated: false, editorRefusal: nil) == "")
    }

    @Test func aCutNameGetsItsFullName() {
        #expect(FileRowView.rowHelp(name: "Statement - Account - January.pdf", nameIsTruncated: true,
                                    editorRefusal: nil)
                == "Statement - Account - January.pdf")
    }

    @Test func theRefusalStaysTheTooltipOnAWholeName() {
        #expect(FileRowView.rowHelp(name: "a.zip", nameIsTruncated: false, editorRefusal: "Not a kind Edit opens.")
                == "Not a kind Edit opens.")
    }

    @Test func aCutRefusedNameSaysBoth() {
        #expect(FileRowView.rowHelp(name: "Quarterly report.zip", nameIsTruncated: true,
                                    editorRefusal: "Not a kind Edit opens.")
                == "Quarterly report.zip\nNot a kind Edit opens.")
    }

    /// The tooltip spells the name as the row draws it, so a trailing space stays visible.
    @Test func theFullNameIsTheDrawnForm() {
        let help = FileRowView.rowHelp(name: "Swimming ", nameIsTruncated: true, editorRefusal: nil)
        #expect(help == NameDisplay.visibleName("Swimming "))
        #expect(help != "Swimming ")
    }

    // MARK: The measurement

    private static let longName = "Statement - Account Ending 4417 - January 2026 (final, signed).pdf"

    /// Hosts a one-line, middle-truncated label at `width`, as the row draws its name, and returns
    /// every answer the probe reported.
    private func reports(width: CGFloat, name: String = longName, host existing: NSHostingView<AnyView>? = nil,
                         into answers: Box) -> NSHostingView<AnyView> {
        let label = Text(name)
            .lineLimit(1)
            .truncationMode(.middle)
            .reportsTruncation(of: Text(name)) { answers.values.append($0) }
            .frame(width: width, alignment: .leading)
        let host = existing ?? NSHostingView(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(label)
        if host.window == nil {
            // Borderless, never ordered in: nothing reaches his screen.
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 40),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }
        host.frame = CGRect(x: 0, y: 0, width: width, height: 40)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return host
    }

    final class Box { var values: [Bool] = [] }

    @Test func aNameTooLongForItsWidthReportsCut() {
        let answers = Box()
        _ = reports(width: 90, into: answers)
        #expect(answers.values == [true], "a 90pt label of a 66-character name reported \(answers.values)")
    }

    /// The control: the same name with room to spare reports nothing — no flip from the initial
    /// "not cut", so no re-render — which is what keeps the rule above from passing on a probe
    /// that says "cut" about everything.
    @Test func aNameWithRoomReportsNothing() {
        let answers = Box()
        _ = reports(width: 680, into: answers)
        #expect(answers.values.isEmpty, "a 680pt label of the name reported \(answers.values)")
    }

    /// Widening a cut name to fit flips it back, so the tooltip goes when the name is whole again.
    @Test func wideningACutNameReportsWhole() {
        let answers = Box()
        let host = reports(width: 90, into: answers)
        _ = reports(width: 680, host: host, into: answers)
        #expect(answers.values == [true, false], "narrow then wide reported \(answers.values)")
    }

    @Test func theThresholdIgnoresSubPointRounding() {
        #expect(TruncationProbe<Text>.isTruncated(shown: 100, ideal: 100.4) == false)
        #expect(TruncationProbe<Text>.isTruncated(shown: 100, ideal: 112) == true)
        #expect(TruncationProbe<Text>.isTruncated(shown: 0, ideal: 112) == false)   // not measured yet
    }

    // MARK: The call site

    /// The row uses both halves: the probe on its name, and the rule as its tooltip. A source scan,
    /// because a hosted SwiftUI tree exposes no tooltip under `swift test`
    /// (`EditorRefusalDimTests.theRefusalIsTheRowsTooltip` measured it). Sliced to `FileRowView`.
    @Test func theRowMeasuresItsNameAndUsesTheRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/FileTreeView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "struct FileRowView: View {"), "FileRowView moved")
        let body = source[start.upperBound...]
        let end = try #require(body.range(of: "\nstruct "), "no struct follows FileRowView")
        let row = body[..<end.lowerBound]
        #expect(row.contains(".reportsTruncation(of: PaneSearchName(name: node.name"),
                "FileRowView no longer measures whether its name is cut")
        #expect(row.contains("nameIsTruncated = truncated"),
                "FileRowView's probe no longer feeds the tooltip's flag")
        #expect(row.contains(".help(Self.rowHelp(name: node.name, nameIsTruncated: nameIsTruncated,"),
                "FileRowView's tooltip no longer goes through rowHelp")
    }
}
