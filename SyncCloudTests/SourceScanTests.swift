import Testing
import Foundation

/// **The source-scan helpers in `TestSupport.swift`, pinned on fixtures** — the lexer, the brace
/// matcher, the argument reader and the whitespace normaliser that every wiring scan in this
/// target now reads `MacApp/` through.
///
/// Each case is one of the ways the readers they replaced went wrong: a first `"\n    }"` that was
/// not the body's end, a first `)` inside a string, a trailing `//` comment that answered a
/// `contains`, and an argument checked by its trailing `,` or `)` — so a reformat turned a scan red
/// with nothing wrong. A helper that silently stopped doing one of these would leave every scan
/// built on it green and wrong; these are what go red instead.
@Suite struct SourceScanTests {

    static let fixture = #"""
    struct Outer {
        var one: Int { 1 }
        func tricky() {
            log("}\(a ? "}" : ")")")
            let raw = #"a "quoted" } brace"#
            let block = """
            }
                }
            """
            /* a } in a block comment */
            done() // trailing } comment
        }
        struct Inner {
            func nested() {
                inner()
            }
        }
        func after() { neighbour() }
    }
    """#

    @Test func aBodyEndsAtItsOwnBraceWhateverTheStringsAndCommentsSay() throws {
        let tricky = try declarationBody(of: "func tricky() {", in: Self.fixture)
        #expect(tricky.contains("done()"), "the body stopped at a brace inside a string or comment")
        #expect(!tricky.contains("struct Inner"), "the body ran past its own closing brace")
        #expect(!tricky.contains("trailing"), "a trailing comment survived the strip")
    }

    /// The three shapes the first-`"\n    }"` reader got wrong: a one-line member ran into the
    /// next member, a nested one ran to the enclosing type's end, a type stopped at its first member.
    @Test func oneLineNestedAndTypeBodiesAreTheirOwn() throws {
        #expect(try declarationBody(of: "var one: Int {", in: Self.fixture) == " 1")
        let nested = try declarationBody(of: "func nested() {", in: Self.fixture)
        #expect(nested.contains("inner()") && !nested.contains("neighbour()"))
        let inner = try declarationBody(of: "struct Inner {", in: Self.fixture)
        #expect(inner.contains("inner()") && !inner.contains("neighbour()"))
        let outer = try declarationBody(of: "struct Outer {", in: Self.fixture)
        #expect(outer.contains("neighbour()"), "a type's body stopped at its first member")
    }

    /// Everything after the declaration up to — not including — the closing brace's line: the
    /// slice the old reader returned wherever it was right, so no caller's text moved.
    @Test func theSliceStopsBeforeTheClosingBracesLine() throws {
        #expect(try declarationBody(of: "func nested() {", in: Self.fixture) == "\n            inner()")
    }

    @Test func commentsGoAndStringsStay() {
        let code = sourceCodeOnly("""
            let url = "https://example.com" // the site
            // a whole comment line
            f(/* inline */ x)
            let s = \"""
            // not a comment
            \"""
            """)
        #expect(code == """
            let url = "https://example.com"
            f( x)
            let s = \"""
            // not a comment
            \"""
            """)
    }

    @Test func layoutDoesNotDecideAMatch() {
        let flat = CodeText("run(path, pane: pane, log: { Logger.shared.info($0) })")
        let spread = CodeText("""
            run(
                path,
                pane:   pane,
                log: {
                    Logger.shared.info($0)
                }
            )
            """)
        #expect(flat.normalized == spread.normalized)
        #expect(spread.contains("pane: pane, log: { Logger.shared.info($0) }"))
        // …but words stay words, and a string's spacing is behaviour.
        #expect(!CodeText("return x").contains("returnx"))
        #expect(!CodeText(#"info("a  b")"#).contains(#"info("a b")"#))
    }

    @Test func argumentsAreReadByLabelNotByPositionOrPunctuation() throws {
        let source = """
            func open(_ path: String) {}
            let decoy = "open(path, pane: .wrong)"
            reopen(path, pane: .alsoWrong)
            open(
                path,
                log: { note($0, level: .info) },
                pane: flag ? .a : .b,
                title: "a, b)"
            )
            """
        let call = try CallArguments(of: "open(", in: source)
        #expect(call.unlabeled == ["path"])
        #expect(call.passes("pane", "flag ? .a : .b"), "a ternary's colon was read as a label")
        #expect(call.passes("log", "{ note($0, level: .info) }"), "a nested comma split the closure")
        #expect(call.passes("title", #""a, b)""#), "a comma or paren inside a string split the list")
        #expect(call.count("pane") == 1 && call.value("missing") == nil)
        #expect(argumentLists(of: "open", in: source).count == 1,
                "a declaration, a string, or a call to another name that ends the same way was read as the call")
    }
}
