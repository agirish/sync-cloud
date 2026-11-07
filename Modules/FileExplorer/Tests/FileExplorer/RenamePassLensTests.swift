import Foundation
import Sync
import Testing
@testable import FileExplorer

/// The rename backlog row's one-line claim, pure and static so it can be pinned unmounted. A
/// reshuffle is the only change that moves a file already correct; a summary folding it in with
/// the padding would let someone reorder a folder while thinking they approved a widening.
@Suite struct RenamePassLensTests {

    private func plan(placed: Int, renumbered: Int, tidied: Int, skips: Int) -> RenamePlan {
        var steps: [RenameStep] = []
        func step(_ i: Int, _ kind: RenameStep.Kind) -> RenameStep {
            RenameStep(currentPath: "/T/\(kind.rawValue)\(i).pdf", currentName: "\(kind.rawValue)\(i).pdf",
                       proposedName: "0\(i). Jan 2021.pdf", kind: kind,
                       cohort: kind == .renumbered ? 1 : 0, reason: "")
        }
        for i in 0..<placed { steps.append(step(i, .placed)) }
        for i in 0..<renumbered { steps.append(step(i, .renumbered)) }
        for i in 0..<tidied { steps.append(step(i, .tidied)) }
        return RenamePlan(folderPath: "/T", relativePath: "T", scheme: .position, steps: steps,
                          skips: (0..<skips).map { RenameSkip(path: "/T/s\($0)", fileName: "s\($0)", reason: "") })
    }

    @Test("A reshuffle is named separately from a padding fix")
    func reshuffleIsNamedSeparately() {
        #expect(RenamePassLens.summary(plan(placed: 1, renumbered: 3, tidied: 0, skips: 0))
                == "1 to name · 3 to reshuffle")
        // The ordinary shape, padding only, must not mention a reshuffle, or the word stops
        // meaning anything on the folders where nothing moves.
        #expect(RenamePassLens.summary(plan(placed: 0, renumbered: 0, tidied: 7, skips: 0))
                == "7 to pad")
    }

    @Test("Files the pass declined to touch are counted in the same breath")
    func skipsAreReported() {
        #expect(RenamePassLens.summary(plan(placed: 0, renumbered: 0, tidied: 2, skips: 1))
                == "2 to pad · 1 left alone")
        // A plan of nothing but skips still says something rather than reading as a clean folder.
        #expect(RenamePassLens.summary(plan(placed: 0, renumbered: 0, tidied: 0, skips: 2))
                == "nothing to do · 2 left alone")
    }
}
