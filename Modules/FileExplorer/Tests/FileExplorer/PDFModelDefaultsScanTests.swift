import Testing
import Foundation

/// Edit's PDF models remember the reader's layout and the saved signatures in `defaults`, and
/// observe it. The parameter defaults to `.standard`, so a model a test builds bare reads and
/// watches the shared domain instead of a scratch one, and nothing at the call site says so. The
/// app target's `LiveSettingsScanTests.everyPDFModelNamesItsDefaults` holds its tests to this;
/// this holds the package's.
@Suite struct PDFModelDefaultsScanTests {
    static let models = ["EditorPDFDocument", "EditorPDFViewState", "EditorPDFSignatureStore"]

    @Test func everyPDFModelNamesItsDefaults() throws {
        let folder = SourceText.modules.appendingPathComponent("FileExplorer/Tests")
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var found: [String: Int] = [:]
        var bare: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for model in Self.models {
                for labels in SourceText.callLabels(of: model, in: source) {
                    found[model, default: 0] += 1
                    if !labels.contains("defaults") {
                        bare.append("\(file.lastPathComponent): \(model)(\(labels.map { "\($0):" }.joined()))")
                    }
                }
            }
        }
        let calls = found.values.reduce(0, +)
        try #require(calls >= 60, "found \(calls) PDF model constructions in \(files.count) files — the scan is reading the wrong folder or missing calls")
        try #require(Self.models.allSatisfy { found[$0, default: 0] > 0 }, "a model was never found: \(found)")
        #expect(bare.isEmpty, "built on the shared defaults domain — pass a ScratchDefaults as defaults: \(bare)")
    }
}
