import Testing
import Foundation

/// The source-scan helpers in `TestSupport.swift`, pinned on fixtures: the lexer, brace matcher,
/// argument reader and whitespace normaliser every wiring scan in this target reads `MacApp/`
/// through.
///
/// Each case is a way a naive reader goes wrong: a `"\n    }"` that isn't the body's end, a `)`
/// inside a string, a trailing `//` comment answering a `contains`, an argument found by its
/// trailing `,` or `)`. A helper that stopped handling one would leave every scan built on it green
/// and wrong; these go red instead.
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

    /// Three shapes a first-`"\n    }"` reader gets wrong: a one-line member runs into the next, a
    /// nested one runs to the enclosing type's end, a type stops at its first member.
    @Test func oneLineNestedAndTypeBodiesAreTheirOwn() throws {
        #expect(try declarationBody(of: "var one: Int {", in: Self.fixture) == " 1")
        let nested = try declarationBody(of: "func nested() {", in: Self.fixture)
        #expect(nested.contains("inner()") && !nested.contains("neighbour()"))
        let inner = try declarationBody(of: "struct Inner {", in: Self.fixture)
        #expect(inner.contains("inner()") && !inner.contains("neighbour()"))
        let outer = try declarationBody(of: "struct Outer {", in: Self.fixture)
        #expect(outer.contains("neighbour()"), "a type's body stopped at its first member")
    }

    /// Everything after the declaration up to, not including, the closing brace's line: the slice
    /// every caller expects.
    @Test func theSliceStopsBeforeTheClosingBracesLine() throws {
        #expect(try declarationBody(of: "func nested() {", in: Self.fixture) == "\n            inner()")
    }

    @Test func maskingBlanksLiteralsAndCommentsAndKeepsTheLayout() {
        let text = "f(\"} return\") // } x\n/* { */ g()"
        let masked = maskedCode(text)
        #expect(masked == "f(          )       \n        g()")
        #expect(masked.utf8.count == text.utf8.count)
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
        let tricky = sourceCodeOnly(#"/* outer /* nested */ still comment */ let c = 3; let q = "a \" // kept" + "b""#)
        #expect(!tricky.contains("still comment") && tricky.contains("let c = 3"), "nested block comments: \(tricky)")
        #expect(tricky.contains(#""a \" // kept" + "b""#), "an escaped quote ended the string: \(tricky)")
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

    /// The reader's own control: a decoy in a comment must not become the answer. The first fixture
    /// puts a commented-out copy of the declaration above the real one; a reader that counted over
    /// stripped text but searched the raw text would return the decoy. The second is the other
    /// direction: a doc comment that names the member must not count as a second declaration.
    @Test func testTheReaderIgnoresDeclarationsThatAreOnlyComments() throws {
        let withDecoy = """
            struct S {
            //    func target() -> Int {
            //        return decoy
            //    }
                func target() -> Int {
                    return real
                }
            }
            """
        let body = try declarationBody(of: "func target() -> Int {", in: withDecoy)
        #expect(body.contains("return real"), "the reader took a commented-out declaration as the member")
        #expect(!body.contains("decoy"))

        let mentioned = """
            struct S {
                /// Companion to `func target() -> Int {`, which it must not be counted as.
                func target() -> Int {
                    return real
                }
            }
            """
        // Not wrapped: the failure worth seeing here is the reader's own `#require`, which reports
        // itself.
        #expect(try declarationBody(of: "func target() -> Int {", in: mentioned)
                    .contains("return real"))

        // A genuine second declaration still stops the run. `withKnownIssue`, not
        // `#expect(throws:)`: the refusal is a `#require`, which records an issue as well as
        // throwing, and that issue would still fail the test. This form also fails if none is
        // recorded.
        let twice = """
            struct S {
                func target() -> Int {
                    return first
                }
                func target() -> Int {
                    return second
                }
            }
            """
        withKnownIssue("two real declarations were not refused — range(of:) would read the first") {
            _ = try declarationBody(of: "func target() -> Int {", in: twice)
        }
    }
}
