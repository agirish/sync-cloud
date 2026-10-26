import Foundation
import Testing

/// **No test builds a `SetupModel` on the real setup draft.**
///
/// `SetupModel`'s `draftURL` defaults to `SetupDraftStore.defaultURL()` — the owner's own
/// `setup-draft.json`. A model built on it reads his draft at init, and a commit on You or People
/// writes it; since closing the sheet commits too (ST4), a hosted test tearing a sheet down on one of
/// those screens would overwrite his answers. The test host IS SyncCloud.app, so nothing sandboxes
/// the path. Every construction here therefore says where its draft goes: `nil`, or a temp folder.
@Suite struct SetupTestDraftScanTests {

    @Test func everyTestModelNamesItsDraft() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SetupTestDraftScanTests.swift" }
        var constructions = 0
        var unnamed: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            var rest = source[...]
            while let open = rest.range(of: "SetupModel(") {
                // Only the type itself: `XSetupModel(` or `.SetupModel(` are other names.
                let before = rest[..<open.lowerBound].last
                var depth = 1
                var end = open.upperBound
                while depth > 0, end < rest.endIndex {
                    switch rest[end] {
                    case "(": depth += 1
                    case ")": depth -= 1
                    default: break
                    }
                    end = rest.index(after: end)
                }
                let arguments = rest[open.upperBound..<end]
                if before.map({ !$0.isLetter && !$0.isNumber && $0 != "." }) ?? true,
                   arguments.contains("settings:") {
                    constructions += 1
                    if !arguments.contains("draftURL:") {
                        unnamed.append("\(file.lastPathComponent): SetupModel(\(arguments.prefix(60))…")
                    }
                }
                rest = rest[end...]
            }
        }
        try #require(constructions >= 10, "found \(constructions) SetupModel constructions — the scan is reading the wrong folder")
        #expect(unnamed.isEmpty, "built on the owner's real setup draft: \(unnamed)")
    }
}
