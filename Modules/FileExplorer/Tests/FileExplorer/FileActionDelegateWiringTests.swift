import Testing
import Foundation
@testable import FileExplorer

/// The two directions of the FileActionDelegate ↔ FileTreeView contract, both derived from the
/// source rather than from a hand list, because the hand-listable half is the half the compiler
/// already checks.
///
/// The bug class is recorded in the protocol's own doc: `riskyName(for:)` and `handleFixName(_:)`
/// were introduced as protocol-EXTENSION members, so every call through the existential bound
/// statically to the extension's nil default and "Fix name…" was unreachable from the moment it
/// was written — the app built, the conformer's methods were tested directly, and a menu item
/// that is merely absent looks exactly like one that is correctly withheld.
@Suite struct FileActionDelegateWiringTests {

    // MARK: Source readers

    private static func sourcesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/FileExplorer/FileActionDelegateWiringTests.swift
            .deletingLastPathComponent()         // …/Tests/FileExplorer
            .deletingLastPathComponent()         // …/Tests
            .deletingLastPathComponent()         // package root
            .appendingPathComponent("Sources/FileExplorer")
    }

    private static func source(_ name: String) throws -> String {
        let text = try #require(
            try? String(contentsOf: sourcesDirectory().appendingPathComponent(name), encoding: .utf8),
            "cannot read Sources/FileExplorer/\(name) — every scan here would be vacuous")
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text
    }

    /// Whole-line comments stripped, so prose that happens to spell `delegate.someMember` — the
    /// protocol's own doc does, for the recorded bug — cannot satisfy either walk.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every file that binds the existential — derived rather than listed, so the next consumer
    /// joins the walk the day it declares one. `PaneColumnsView` consumes seven members through
    /// the same `delegate:` it declares at its top; a forward walk that read `FileTreeView` alone
    /// was structurally silent about all of them, which is the recorded bug with a different file
    /// name on it.
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

    /// The member names declared inside the protocol BODY — the witness table. Extension members
    /// deliberately excluded: being outside this set is exactly what made the recorded bug.
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
        // The floor is set below EVERY line's protocol size (main >30, v3.x ~25, v2.x 18): it
        // exists to catch a broken parser (which yields 0–2), not to pin a line's verb count.
        try #require(names.count > 12, "only \(names.count) requirements parsed — the parser is broken, not the protocol")
        return names
    }

    /// Every `delegate.<member>` consumed in `text`, comments stripped. The boundary check is
    /// hand-rolled rather than `\b`: Swift regexes default to UNICODE word boundaries, under
    /// which `lhs.delegate` is one word and `\b` never fires before the member access — which
    /// silently dropped `isEquivalent`, whose only consumer is `lhs.delegate.isEquivalent(...)`.
    /// The check still refuses a `scrollDelegate.someMember`, which must not count as the
    /// file-action existential.
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

    /// Every member the pane consumes through the existential is a protocol REQUIREMENT. A member
    /// that exists only in a protocol extension has no witness: the existential call binds to the
    /// extension default at compile time, the conformer's override is never reached, and the
    /// feature dies silently — the `riskyName` bug, re-armed for whatever member is added next.
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

    /// The reverse walk: every requirement is consumed somewhere in this module. A requirement
    /// nothing calls is a verb no surface can trigger — the "menu item forgotten" direction, which
    /// the forward walk is structurally silent about (a call that is never written can never be
    /// wrong). Scanned across every source file, since the differences table and the panes consume
    /// different subsets.
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
