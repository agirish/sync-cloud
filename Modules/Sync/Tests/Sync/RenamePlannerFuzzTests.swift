import Foundation
import Testing
@testable import Sync

/// Adversarial inputs across the whole pass, holding the invariants no individual fixture states.
///
/// The hand-written suites each pin one behaviour on one shape. These pin the properties that must
/// hold for *every* shape — and they are the properties whose violation is silent: two steps
/// wanting one name, a step landing on a file that stays, a rename to itself. A folder-scoped
/// planner can get any of those wrong on a combination nobody thought to write down.
///
/// Cheap enough to keep (~0.6 s for ~2,200 planner configurations) and fully deterministic — the
/// inputs are enumerated, not random, so a failure here reproduces exactly.
@Suite struct RenamePlannerFuzzTests {

    @Test("No name traps the grammar, and nothing it accepts is nonsense")
    func fuzzParsersForCrashesAndNonsense() {
        let fragments = ["", ".", "0", "00", "1", "13", "99", "0.", "1.", "00.", "-1",
                         "Jan", "January", "Sept", "sep", "2021", "0000", "9999", "19999",
                         " ", "  ", "..", ". .", "pdf", ".pdf", "..pdf", "a.b.c",
                         "20201301", "20200001", "00000000", "99999999", "12002020",
                         "\u{200B}", "café", "Ⅻ", "١٢", "🙂", "Mar\u{00A0}2021"]
        var parsed = 0, mined = 0
        for a in fragments {
            for b in fragments {
                for sep in ["", " ", ".", "-", "_"] {
                    let name = a + sep + b
                    if let p = OrdinalMonthName.parse(name) {
                        parsed += 1
                        // Anything the grammar accepts must be re-renderable without trapping.
                        _ = p.canonicalName
                        _ = p.canonicalName(ordinal: 0)
                        _ = p.canonicalName(ordinal: 99)
                        _ = p.isCanonical
                        if let m = p.month { #expect((1...12).contains(m), "\(name) -> month \(m)") }
                        #expect((0...99).contains(p.ordinal), "\(name) -> ordinal \(p.ordinal)")
                    }
                    if let m = FileNameDate.mine(name) {
                        mined += 1
                        #expect((1...12).contains(m.month), "\(name) -> month \(m.month)")
                        #expect((1900...2199).contains(m.year), "\(name) -> year \(m.year)")
                    }
                }
            }
        }
        #expect(parsed > 100 && mined > 100, "the corpus stopped exercising the parsers")
    }

    @Test("A malformed year key refuses, rather than accepting everything")
    func fuzzYearFits() {
        for owned in ["", "-", "2014-", "-2015", "2014-2015-2016", "abc", "2014 - 2015",
                      "20140", "2014", "0", "99999", "2014--2015"] {
            for y in [1899, 1900, 2014, 2015, 2199, 2200] {
                for m in [1, 4, 12] {
                    _ = RenamePlanner.yearFits(y, month: m, ownedBy: owned)
                }
            }
        }
        // A malformed key must not accidentally ACCEPT everything — that is the direction that
        // would let a bill be renamed into a year its folder does not own.
        #expect(!RenamePlanner.yearFits(2014, month: 6, ownedBy: "abc"))
        #expect(!RenamePlanner.yearFits(2014, month: 6, ownedBy: ""))
        #expect(!RenamePlanner.yearFits(2014, month: 6, ownedBy: "2014-2015-2016"))
    }

    @Test("Across every shape, no two steps want one name and none lands on a file that stays")
    func fuzzPlanner() {
        let names = ["1. Jan 2021.pdf", "01. Jan 2021.pdf", "0. Summary.pdf", "00. x.pdf",
                     "custbill01152021.pdf", "junk.pdf", "13. Xxx 2021.pdf", "99. Dec 2021.pdf",
                     "1.pdf", ".pdf", "1. Jan 2021", "1. Jan 2021.PDF", "1. jan 2021.pdf"]
        for i in 0..<names.count {
            for j in 0..<names.count {
                for k in 0..<names.count {
                    let files = [names[i], names[j], names[k]].enumerated()
                        .map { FolderFile(path: "/T/\($0.offset)-\($0.element)", name: $0.element) }
                    for naming in ["ordinal-month", "descriptive", nil] {
                        for year in ["2021", "2014-2015", nil] {
                            var axes: [String: String] = [:]
                            if let year { axes["year"] = year }
                            let e = FolderProfileEntry(path: "T", role: .yearBucket, naming: naming,
                                                       anchors: [], acceptsNewFiles: true,
                                                       fileCount: 3, subfolderCount: 0, axes: axes)
                            let p = RenamePlanner.plan(folderPath: "/T", relativePath: "T",
                                                       files: files, entry: e)
                            // No step may target a name another step targets, or one that stays.
                            let targets = p.steps.map { $0.proposedName.lowercased() }
                            #expect(Set(targets).count == targets.count,
                                    "two steps want one name: \(targets)")
                            let staying = Set(files.map { $0.name.lowercased() })
                                .subtracting(p.steps.map { $0.currentName.lowercased() })
                            #expect(staying.isDisjoint(with: Set(targets)),
                                    "a step lands on a file that stays: \(targets)")
                            // Nothing may be renamed to itself.
                            #expect(!p.steps.contains { $0.currentName == $0.proposedName })
                        }
                    }
                }
            }
        }
    }
}
