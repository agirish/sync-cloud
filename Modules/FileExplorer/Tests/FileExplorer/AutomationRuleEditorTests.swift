import Foundation
import Testing
@testable import FileExplorer

/// Pins the Browse… destination helper: a picked folder becomes a path relative to the preview
/// root, the same root the folder was previewed against — inside → relative subpath, the root
/// itself → empty, anything outside → nil (which the editor turns into a "pick inside" alert).
@Suite struct AutomationRuleEditorTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func insideBaseGivesRelativeSubpath() {
        #expect(AutomationRuleEditor.relativePath(of: url("/base/Documents/Invoices"),
                                                  under: url("/base")) == "Documents/Invoices")
        #expect(AutomationRuleEditor.relativePath(of: url("/base/Docs"), under: url("/base")) == "Docs")
    }

    @Test func sameFolderGivesEmptyString() {
        #expect(AutomationRuleEditor.relativePath(of: url("/base"), under: url("/base")) == "")
        #expect(AutomationRuleEditor.relativePath(of: url("/base/"), under: url("/base")) == "")
    }

    @Test func outsideBaseIsNil() {
        #expect(AutomationRuleEditor.relativePath(of: url("/other/x"), under: url("/base")) == nil)
        // A shared string prefix that isn't a path-component boundary must not count as "inside".
        #expect(AutomationRuleEditor.relativePath(of: url("/basement/x"), under: url("/base")) == nil)
        // A parent of the base is not inside it.
        #expect(AutomationRuleEditor.relativePath(of: url("/"), under: url("/base")) == nil)
    }
}
