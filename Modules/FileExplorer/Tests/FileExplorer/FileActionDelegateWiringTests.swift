import Testing
import Foundation
@testable import FileExplorer

/// Both directions of the FileActionDelegate ↔ FileTreeView contract, derived from the source rather
/// than a hand list, since the hand-listable half is the half the compiler already checks.
///
/// The bug class (the protocol's own doc states the rule): a member declared only in a protocol
/// extension binds statically, through the existential, to the extension's default, so the
/// conformer's method is never reached. The app builds, the conformer's methods pass their direct
/// tests, and a menu item that is merely absent looks exactly like one correctly withheld.
@Suite struct FileActionDelegateWiringTests {

    // MARK: Source readers

    private static func sourcesDirectory() -> URL {
        SourceText.modules.appendingPathComponent("FileExplorer/Sources/FileExplorer")
    }

    private static func source(_ name: String) throws -> String { try SourceText.fileExplorer(name) }

    /// Whole-line comments stripped, so prose that spells `delegate.someMember` (the protocol file
    /// has some) cannot satisfy either walk.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every file that binds the existential, derived rather than listed, so the next consumer joins
    /// the walk the day it declares one. `PaneColumnsView` consumes several members through its own
    /// `delegate:`, which a walk of `FileTreeView` alone would miss.
    private static func consumerSources() throws -> [String] {
        let fm = FileManager.default
        let files = try #require(try? fm.contentsOfDirectory(at: sourcesDirectory(),
                                                             includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "swift" }
        let consumers = files.compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  codeOnly(text).contains("delegate: FileActionDelegate") else { return nil }
            return text
        }
        try #require(consumers.count >= 2,
                     "only \(consumers.count) files declare the existential — FileTreeView and PaneColumnsView both do today, so the detector is broken")
        return consumers
    }

    /// The member names declared inside the protocol body, the witness table. Extension members are
    /// deliberately excluded: being outside this set is exactly the bug.
    private static func protocolRequirements() throws -> Set<String> {
        let text = try source("FileActionDelegate.swift")
        let start = try #require(text.range(of: "public protocol FileActionDelegate"),
                                 "the protocol moved — update this scan")
        // The body ends at the first closing brace in column 0 after the declaration.
        let afterStart = text[start.upperBound...]
        let end = try #require(afterStart.range(of: "\n}"), "no closing brace for the protocol body")
        let body = afterStart[..<end.lowerBound]

        var names: Set<String> = []
        for match in body.matches(of: /func ([a-zA-Z0-9_]+)\s*\(/) { names.insert(String(match.1)) }
        for match in body.matches(of: /var ([a-zA-Z0-9_]+)\s*:/) { names.insert(String(match.1)) }
        // The floor sits below every release line's protocol size: it exists to catch a broken
        // parser (which yields 0–2), not to pin a line's verb count.
        try #require(names.count > 12, "only \(names.count) requirements parsed — the parser is broken, not the protocol")
        return names
    }

    /// Every `delegate.<member>` consumed in `text`, comments stripped. The boundary check is
    /// hand-rolled rather than `\b`: Swift regexes default to Unicode word boundaries, under which
    /// `lhs.delegate` is one word and `\b` never fires before the member access, so
    /// `lhs.delegate.isEquivalent(...)` would be missed. The check still refuses a
    /// `scrollDelegate.someMember`, which must not count as the file-action existential.
    private static func delegateMemberReferences(inText text: String) -> Set<String> {
        let code = codeOnly(text)
        var names: Set<String> = []
        for match in code.matches(of: /delegate\.([a-zA-Z0-9_]+)/) {
            if match.range.lowerBound > code.startIndex {
                let before = code[code.index(before: match.range.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            names.insert(String(match.1))
        }
        return names
    }

    // MARK: The two directions

    /// Every member the pane consumes through the existential is a protocol requirement: one only in
    /// an extension has no witness, so the call binds to the extension default and the feature dies.
    @Test func everyConsumedDelegateMemberIsARequirementNotAnExtensionDefault() throws {
        let requirements = try Self.protocolRequirements()
        var consumed: Set<String> = []
        for text in try Self.consumerSources() {
            consumed.formUnion(Self.delegateMemberReferences(inText: text))
        }
        try #require(consumed.count > 12, "only \(consumed.count) delegate references found — the scan is broken")

        let extensionOnly = consumed.subtracting(requirements)
        #expect(extensionOnly.isEmpty,
                """
                consumed through the existential but NOT declared in the protocol body — these \
                dispatch to the extension default and the conformer's implementation is \
                unreachable: \(extensionOnly.sorted())
                """)
    }

    /// The reverse walk: every requirement is consumed somewhere in this module. A requirement nothing
    /// calls is a verb no surface can trigger (a forgotten menu item), which the forward walk can't
    /// see. Every source file is scanned: the differences table and the panes use different subsets.
    @Test func everyRequirementIsConsumedBySomeSurface() throws {
        let requirements = try Self.protocolRequirements()
        let fm = FileManager.default
        let files = try #require(try? fm.contentsOfDirectory(at: Self.sourcesDirectory(),
                                                             includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 50, "only \(files.count) source files listed — the reader is broken")
        var consumed: Set<String> = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            consumed.formUnion(Self.delegateMemberReferences(inText: text))
        }

        let unconsumed = requirements.subtracting(consumed)
        #expect(unconsumed.isEmpty,
                """
                declared as requirements but consumed by no surface in this module — either a \
                forgotten menu item/wiring, or dead weight to remove: \(unconsumed.sorted())
                """)
    }
}
